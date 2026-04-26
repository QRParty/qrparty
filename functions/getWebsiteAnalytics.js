const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

// Property ID is just a number string (e.g. "123456789"). Stored as a secret
// for consistency with how other config lives in this project; ADC handles
// the actual GA4 API auth.
const ga4PropertyId = defineSecret("GA4_PROPERTY_ID");

const CACHE_TTL_MS = 15 * 60 * 1000; // 15 minutes
const CACHE_DOC = "adminConfig/analyticsCache";

const ALLOWED_RANGES = ["7d", "30d", "90d", "all"];

const TRACKED_EVENTS = [
  "download_clicked",
  "business_teaser_clicked",
  "business_trial_clicked",
  "rsvp_button_clicked",
  "add_to_calendar_clicked",
  "event_page_loaded",
  "org_page_loaded",
];

function startDateFor(range) {
  switch (range) {
    case "7d":  return "7daysAgo";
    case "90d": return "90daysAgo";
    case "all": return "2025-01-01"; // pragmatic floor — site launched 2026
    case "30d":
    default:    return "30daysAgo";
  }
}

async function isAdminUid(db, uid) {
  if (!uid) return false;
  const snap = await db.collection("users").doc(uid).get();
  return snap.exists && snap.data().isAdmin === true;
}

function rowsToList(report, dimIndex, metricIndex) {
  const rows = report?.rows || [];
  return rows.map((r) => ({
    key:   r.dimensionValues?.[dimIndex]?.value ?? "",
    count: parseInt(r.metricValues?.[metricIndex]?.value ?? "0", 10),
  }));
}

function totalsFromReport(report) {
  const row = report?.rows?.[0];
  if (!row) return { pageViews: 0, sessions: 0, newUsers: 0 };
  return {
    pageViews: parseInt(row.metricValues?.[0]?.value ?? "0", 10),
    sessions:  parseInt(row.metricValues?.[1]?.value ?? "0", 10),
    newUsers:  parseInt(row.metricValues?.[2]?.value ?? "0", 10),
  };
}

function eventCountsFromReport(report) {
  const out = Object.fromEntries(TRACKED_EVENTS.map((n) => [n, 0]));
  for (const row of report?.rows || []) {
    const name = row.dimensionValues?.[0]?.value;
    const count = parseInt(row.metricValues?.[0]?.value ?? "0", 10);
    if (name && Object.prototype.hasOwnProperty.call(out, name)) out[name] = count;
  }
  return out;
}

function timeSeriesFromReport(report) {
  // GA4 returns date as 'YYYYMMDD' strings. Sort ascending and normalise.
  const rows = report?.rows || [];
  return rows
    .map((r) => ({
      date: r.dimensionValues?.[0]?.value ?? "",
      count: parseInt(r.metricValues?.[0]?.value ?? "0", 10),
    }))
    .sort((a, b) => a.date.localeCompare(b.date));
}

async function fetchFromGa4(propertyId, range) {
  const { BetaAnalyticsDataClient } = require("@google-analytics/data");
  const client = new BetaAnalyticsDataClient();
  const property = `properties/${propertyId}`;
  const dateRanges = [{ startDate: startDateFor(range), endDate: "today" }];

  const [batch] = await client.batchRunReports({
    property,
    requests: [
      // 0 — totals
      {
        property,
        dateRanges,
        metrics: [
          { name: "screenPageViews" },
          { name: "sessions" },
          { name: "newUsers" },
        ],
      },
      // 1 — top pages
      {
        property,
        dateRanges,
        dimensions: [{ name: "pagePath" }],
        metrics: [{ name: "screenPageViews" }],
        orderBys: [{ metric: { metricName: "screenPageViews" }, desc: true }],
        limit: 5,
      },
      // 2 — top sources
      {
        property,
        dateRanges,
        dimensions: [{ name: "sessionSource" }],
        metrics: [{ name: "sessions" }],
        orderBys: [{ metric: { metricName: "sessions" }, desc: true }],
        limit: 5,
      },
      // 3 — custom event counts (filtered to tracked names)
      {
        property,
        dateRanges,
        dimensions: [{ name: "eventName" }],
        metrics: [{ name: "eventCount" }],
        dimensionFilter: {
          filter: {
            fieldName: "eventName",
            inListFilter: { values: TRACKED_EVENTS },
          },
        },
      },
      // 4 — time series (page views per day for sparkline)
      {
        property,
        dateRanges,
        dimensions: [{ name: "date" }],
        metrics: [{ name: "screenPageViews" }],
      },
    ],
  });

  const reports = batch.reports || [];
  return {
    totals:       totalsFromReport(reports[0]),
    topPages:     rowsToList(reports[1], 0, 0),
    topSources:   rowsToList(reports[2], 0, 0),
    eventCounts:  eventCountsFromReport(reports[3]),
    timeSeries:   timeSeriesFromReport(reports[4]),
  };
}

exports.getWebsiteAnalytics = onCall(
  { secrets: [ga4PropertyId] },
  async (request) => {
    const db = getFirestore();
    const uid = request.auth?.uid;
    if (!(await isAdminUid(db, uid))) {
      throw new HttpsError("permission-denied", "Admin only");
    }

    const data = request.data || {};
    const range = ALLOWED_RANGES.includes(data.dateRange) ? data.dateRange : "30d";
    const force = data.force === true;

    const cacheRef = db.doc(CACHE_DOC);
    const cacheSnap = await cacheRef.get();
    const cachedAll = cacheSnap.exists ? (cacheSnap.data() || {}) : {};
    const cached = cachedAll[range];
    const cacheAgeMs = cached?.fetchedAt?.toMillis ? Date.now() - cached.fetchedAt.toMillis() : Infinity;

    if (!force && cached && cacheAgeMs < CACHE_TTL_MS) {
      console.log(`[getWebsiteAnalytics] cache hit range=${range} ageMs=${cacheAgeMs}`);
      return {
        ...cached.data,
        fromCache: true,
        cacheAgeSeconds: Math.round(cacheAgeMs / 1000),
        dateRange: range,
      };
    }

    const propertyId = ga4PropertyId.value();
    if (!propertyId) {
      // No property configured yet — surface cached data if any, else empty.
      if (cached) {
        console.warn(`[getWebsiteAnalytics] GA4_PROPERTY_ID empty; returning stale cache for ${range}`);
        return {
          ...cached.data,
          fromCache: true,
          stale: true,
          cacheAgeSeconds: Math.round(cacheAgeMs / 1000),
          dateRange: range,
        };
      }
      throw new HttpsError("failed-precondition", "GA4_PROPERTY_ID not configured");
    }

    let fresh;
    try {
      fresh = await fetchFromGa4(propertyId, range);
    } catch (err) {
      console.error(`[getWebsiteAnalytics] GA4 API failed:`, err.message);
      // Fall back to whatever cache we have, even if expired.
      if (cached) {
        return {
          ...cached.data,
          fromCache: true,
          stale: true,
          cacheAgeSeconds: Math.round(cacheAgeMs / 1000),
          error: err.message,
          dateRange: range,
        };
      }
      throw new HttpsError("internal", `GA4 fetch failed: ${err.message}`);
    }

    await cacheRef.set({
      [range]: { data: fresh, fetchedAt: FieldValue.serverTimestamp() },
    }, { merge: true });

    console.log(`[getWebsiteAnalytics] cache refreshed range=${range} pageViews=${fresh.totals.pageViews}`);
    return { ...fresh, fromCache: false, cacheAgeSeconds: 0, dateRange: range };
  }
);
