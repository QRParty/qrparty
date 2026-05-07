const { onDocumentCreated, onDocumentDeleted, onDocumentWritten } = require("firebase-functions/v2/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const { initializeApp } = require("firebase-admin/app");
const { getMessaging } = require("firebase-admin/messaging");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");

initializeApp();

const stripeSecretKey = defineSecret("STRIPE_SECRET_KEY");

// Manual fulfillment pipeline (Vistaprint) — replaces the Printful integration.
exports.createMerchOrder       = require("./createMerchOrder").createMerchOrder;
exports.sendOrderStatusEmail   = require("./sendOrderStatusEmail").sendOrderStatusEmail;

// GA4 analytics for the admin dashboard.
exports.getWebsiteAnalytics = require("./getWebsiteAnalytics").getWebsiteAnalytics;

// Headquarters↔Business org link — atomic 3-doc accept transaction.
// See acceptOrgInvite.js for the validation/invariant set.
exports.acceptOrgInvite = require("./acceptOrgInvite").acceptOrgInvite;

// Reverse direction of the HQ→Business invite — a Business owner asks
// to link UP to a Headquarters. See requestHqLink.js for the validation
// pipeline; bypasses firestore.rules via admin SDK.
exports.requestHqLink = require("./requestHqLink").requestHqLink;

// Mass notification fan-out for the Contacts tab — see
// sendMassNotification.js for the rsvp → uid → token pipeline.
exports.sendMassNotification = require("./sendMassNotification").sendMassNotification;

exports.createPaymentIntent = onCall(
  { secrets: [stripeSecretKey] },
  async (request) => {
    const { amount, currency = "usd" } = request.data;

    if (!amount || typeof amount !== "number" || amount <= 0) {
      throw new HttpsError("invalid-argument", "amount must be a positive number in cents");
    }

    const secret = stripeSecretKey.value();
    if (!secret) {
      console.error("[createPaymentIntent] STRIPE_SECRET_KEY secret is empty");
      throw new HttpsError("internal", "Stripe secret key not configured");
    }

    console.log(`[createPaymentIntent] creating PaymentIntent for ${amount} cents`);

    const Stripe = require("stripe");
    const stripe = Stripe(secret);

    const paymentIntent = await stripe.paymentIntents.create({
      amount: Math.round(amount),
      currency,
      automatic_payment_methods: { enabled: true },
    });

    console.log(`[createPaymentIntent] created PaymentIntent ${paymentIntent.id}`);
    return { clientSecret: paymentIntent.client_secret };
  }
);

exports.onEventDeleted = onDocumentDeleted(
  "events/{eventId}",
  async (event) => {
    const db = getFirestore();
    const eventRef = db.collection("events").doc(event.params.eventId);
    console.log(`[onEventDeleted] recursively deleting subcollections for event ${event.params.eventId}`);
    try {
      await db.recursiveDelete(eventRef);
      console.log(`[onEventDeleted] done for event ${event.params.eventId}`);
    } catch (err) {
      console.error(`[onEventDeleted] failed for event ${event.params.eventId}:`, err);
    }
  }
);

exports.sendRunningLateNotification = onCall(async (request) => {
  const { eventId } = request.data;
  if (!eventId) throw new HttpsError("invalid-argument", "eventId is required");

  const db = getFirestore();

  // Get host display name from the event doc
  const eventSnap = await db.collection("events").doc(eventId).get();
  if (!eventSnap.exists) throw new HttpsError("not-found", "Event not found");
  const hostName = eventSnap.data().hostName || "Your host";

  // Query all RSVPs with status == "Yes"
  const rsvpSnap = await db
    .collection("events").doc(eventId).collection("rsvps")
    .where("status", "==", "Yes")
    .get();

  if (rsvpSnap.empty) return { sent: 0 };

  // Look up FCM tokens for each yes RSVP in parallel
  const uids = rsvpSnap.docs.map((d) => d.id);
  const userDocs = await Promise.all(
    uids.map((uid) => db.collection("users").doc(uid).get())
  );
  const tokens = userDocs
    .map((d) => d.data()?.fcmToken)
    .filter((t) => typeof t === "string" && t.length > 0);

  if (tokens.length === 0) return { sent: 0 };

  const messaging = getMessaging();
  const chunkSize = 500;
  let totalSuccess = 0;

  for (let i = 0; i < tokens.length; i += chunkSize) {
    const chunk = tokens.slice(i, i + chunkSize);
    const response = await messaging.sendEachForMulticast({
      tokens: chunk,
      notification: {
        title: "Heads up! 🏃",
        body: `${hostName} is running a little late — hang tight!`,
      },
      data: { eventId },
      android: { notification: { sound: "default", priority: "high" } },
      apns: { payload: { aps: { sound: "default", badge: 1 } } },
    });
    totalSuccess += response.successCount;
  }

  return { sent: totalSuccess };
});

exports.getStripeRevenue = onCall(
  { secrets: [stripeSecretKey] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be signed in");
    }

    const db = getFirestore();
    const userDoc = await db.collection("users").doc(request.auth.uid).get();
    if (!userDoc.exists || userDoc.data()?.isAdmin !== true) {
      throw new HttpsError("permission-denied", "Admin access required");
    }

    const secret = stripeSecretKey.value();
    if (!secret) {
      throw new HttpsError("internal", "Stripe secret key not configured");
    }

    const Stripe = require("stripe");
    const stripe = Stripe(secret);

    // Subscriptions (Business / Business Plus) flow through Google Play Billing,
    // not Stripe, so they do NOT appear here. This sums every Stripe PaymentIntent
    // (wishlist contributions, public-event fees, storage upgrades, etc.). If a
    // PaymentIntent carries `metadata.tier = 'business' | 'businessPlus'`, it's
    // also surfaced in the tier breakdown below.
    let totalCents = 0;
    let chargeCount = 0;
    let businessCents = 0;
    let businessPlusCents = 0;
    let hasMore = true;
    let startingAfter = undefined;

    while (hasMore) {
      const params = { limit: 100 };
      if (startingAfter) params.starting_after = startingAfter;

      const list = await stripe.paymentIntents.list(params);

      for (const pi of list.data) {
        if (pi.status === "succeeded" && pi.amount_received > 0) {
          totalCents += pi.amount_received;
          chargeCount++;
          const tier = pi.metadata && pi.metadata.tier;
          if (tier === "businessPlus") businessPlusCents += pi.amount_received;
          else if (tier === "business") businessCents     += pi.amount_received;
        }
      }

      hasMore = list.has_more;
      if (hasMore && list.data.length > 0) {
        startingAfter = list.data[list.data.length - 1].id;
      }
    }

    console.log(`[getStripeRevenue] total=$${(totalCents / 100).toFixed(2)} charges=${chargeCount} biz=$${(businessCents/100).toFixed(2)} bizPlus=$${(businessPlusCents/100).toFixed(2)}`);
    return {
      totalDollars:        totalCents / 100,
      chargeCount,
      businessDollars:     businessCents / 100,
      businessPlusDollars: businessPlusCents / 100,
    };
  }
);

exports.processNotificationQueue = onDocumentCreated(
  "notificationQueue/{docId}",
  async (event) => {
    const docId = event.params.docId;
    const log = (msg, extra) =>
      console.log(`[processNotificationQueue ${docId}] ${msg}`, extra || "");

    const snap = event.data;
    if (!snap) {
      log("no snapshot — function fired with empty event");
      return;
    }

    const data = snap.data();
    const tokens = data.tokens;
    const title = data.title;
    const body = data.body;
    const eventId = data.eventId || "";

    log("invoke", {
      tokenCount: Array.isArray(tokens) ? tokens.length : 0,
      title, body, eventId,
    });

    if (!Array.isArray(tokens) || tokens.length === 0 || !title || !body) {
      log("skipped — missing tokens/title/body");
      await snap.ref.update({
        sent: true,
        skipped: true,
        skipReason: !Array.isArray(tokens) ? "tokens-not-array"
          : tokens.length === 0 ? "tokens-empty"
          : !title ? "title-missing"
          : "body-missing",
        processedAt: FieldValue.serverTimestamp(),
      });
      return;
    }

    const messaging = getMessaging();
    const db = getFirestore();

    const chunkSize = 500;
    let totalSuccess = 0;
    let totalFailure = 0;
    // Per-token failure detail collected across all chunks. Stamped
    // back onto the queue doc so a host (or admin) inspecting Firestore
    // can see exactly which tokens failed and why. Also drives the
    // dead-token cleanup pass at the end.
    const failures = []; // [{token, code, message}]

    for (let i = 0; i < tokens.length; i += chunkSize) {
      const chunk = tokens.slice(i, i + chunkSize);
      log(`sending chunk ${i / chunkSize + 1} of ${Math.ceil(tokens.length / chunkSize)} (${chunk.length} tokens)`);
      let response;
      try {
        response = await messaging.sendEachForMulticast({
          tokens: chunk,
          notification: { title, body },
          // FCM `data` payload values must all be strings. eventId is
          // already a string; coerce defensively in case a future
          // caller hands us a non-string.
          data: { eventId: String(eventId) },
          android: {
            // channel_id must match the channel created in
            // lib/main.dart's NotificationBridge AND the manifest
            // meta-data `com.google.firebase.messaging.default_
            // notification_channel_id`. Required on Android 8+ —
            // notifications without a registered channel are silently
            // dropped by the system tray.
            notification: { sound: "default", priority: "high", channel_id: "qrparty_default" },
          },
          apns: {
            payload: { aps: { sound: "default", badge: 1 } },
          },
        });
      } catch (err) {
        // sendEachForMulticast itself rarely throws — per-token
        // failures land in response.responses. A throw here is a
        // top-level FCM auth/config issue (e.g. missing APNs key,
        // wrong project). Log it loudly and bail.
        log("FCM send threw — likely config issue", {
          code: err.code, message: err.message,
        });
        await snap.ref.update({
          sent: true,
          error: true,
          errorCode: err.code || "unknown",
          errorMessage: err.message || String(err),
          processedAt: FieldValue.serverTimestamp(),
        });
        return;
      }

      totalSuccess += response.successCount;
      totalFailure += response.failureCount;
      log(`chunk result`, {
        successCount: response.successCount,
        failureCount: response.failureCount,
      });

      // Walk per-token responses to surface why each one failed.
      // response.responses is parallel to the input tokens array.
      response.responses.forEach((r, idx) => {
        if (!r.success && r.error) {
          failures.push({
            token: chunk[idx],
            code: r.error.code || "unknown",
            message: r.error.message || "",
          });
        }
      });
    }

    log("totals", { totalSuccess, totalFailure, failureCount: failures.length });

    // Surface every distinct failure code so a quick log scan tells
    // us if it's all stale tokens vs. a different class of problem.
    const codeCounts = {};
    for (const f of failures) {
      codeCounts[f.code] = (codeCounts[f.code] || 0) + 1;
    }
    if (Object.keys(codeCounts).length > 0) {
      log("failure breakdown by error code", codeCounts);
    }

    // Dead-token cleanup. FCM returns these codes when a token is no
    // longer valid (user uninstalled, reinstalled with a new token,
    // OS revoked it). Leaving stale tokens on user docs causes every
    // future notification to log an avoidable failure — flush them
    // out when we see the error. Looked up by query because the
    // queue payload stores raw tokens (no uid back-pointer).
    const deadCodes = new Set([
      "messaging/registration-token-not-registered",
      "messaging/invalid-registration-token",
      "messaging/invalid-argument",
    ]);
    const deadTokens = failures
      .filter((f) => deadCodes.has(f.code))
      .map((f) => f.token);
    if (deadTokens.length > 0) {
      log(`scrubbing ${deadTokens.length} dead token(s) from user docs`);
      for (const dt of deadTokens) {
        try {
          const usersWithToken = await db.collection("users")
            .where("fcmToken", "==", dt)
            .get();
          for (const userDoc of usersWithToken.docs) {
            await userDoc.ref.update({ fcmToken: FieldValue.delete() });
            log(`cleared dead token from users/${userDoc.id}`);
          }
        } catch (err) {
          log(`dead-token cleanup failed for token ending …${dt.slice(-8)}`, {
            code: err.code, message: err.message,
          });
        }
      }
    }

    await db.collection("notificationQueue").doc(docId).update({
      sent: true,
      successCount: totalSuccess,
      failureCount: totalFailure,
      // Cap inline failures to avoid blowing up the doc on a giant
      // batch; full detail is in the function logs.
      failures: failures.slice(0, 25),
      failureCodes: codeCounts,
      processedAt: FieldValue.serverTimestamp(),
    });
    log("done");
  }
);

// ── RECURRING EVENTS ──────────────────────────────────────────
// Scheduled every 30 minutes: for each ended recurring event that hasn't yet
// spawned its next occurrence, compute the next date from the series rule,
// clone the series template into a new event, and push-notify previous Yes RSVPs.

// Mirrors the Dart-side `_shortCodeAlphabet` / `_generateShortCode` /
// `_allocateUniqueShortCode` in lib/screens/create_event_screen.dart.
// 6-char uppercase alphanumeric, deliberately omitting the ambiguous
// 0/O and 1/I pairs so codes can be typed off a printed invitation
// without confusion. 32^6 ≈ 1B keyspace — collision math is negligible
// for any realistic event volume. Each spawned recurring occurrence
// needs its own unique code so partywithqr.com/event/{shortCode} URLs
// resolve to the right doc; sharing one shortCode across an entire
// series would let any guest scan into the wrong week's event.
const SHORT_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

function generateShortCode() {
  let out = "";
  for (let i = 0; i < 6; i++) {
    out += SHORT_CODE_ALPHABET.charAt(Math.floor(Math.random() * SHORT_CODE_ALPHABET.length));
  }
  return out;
}

async function allocateUniqueShortCode(db) {
  for (let i = 0; i < 5; i++) {
    const code = generateShortCode();
    const dup = await db.collection("events")
      .where("shortCode", "==", code)
      .limit(1)
      .get();
    if (dup.empty) return code;
  }
  // Extremely unlikely; fall through with a fresh code rather than throw.
  // Worst case the host gets a duplicate and the secondary lookup returns
  // the first match — still functional.
  return generateShortCode();
}

function computeNextRecurringDate(prevDate, rule) {
  const d = new Date(prevDate.getTime());
  switch (rule.frequency) {
    case "daily":    d.setUTCDate(d.getUTCDate() + 1);  break;
    case "weekly":   d.setUTCDate(d.getUTCDate() + 7);  break;
    case "biweekly": d.setUTCDate(d.getUTCDate() + 14); break;
    case "monthly":  d.setUTCMonth(d.getUTCMonth() + 1); break;
    default:         d.setUTCDate(d.getUTCDate() + 7);
  }
  return d;
}

exports.createNextRecurringEvent = onSchedule(
  { schedule: "every 30 minutes", timeZone: "UTC" },
  async () => {
    const db = getFirestore();
    const now = new Date();

    const snap = await db.collection("events")
      .where("isRecurring", "==", true)
      .where("date", "<", Timestamp.fromDate(now))
      .get();

    console.log(`[createNextRecurringEvent] scanning ${snap.size} ended recurring event(s)`);

    for (const doc of snap.docs) {
      const data = doc.data();
      if (data.nextCreated === true) continue;

      const seriesId = data.recurringSeriesId;
      if (!seriesId) {
        await doc.ref.update({ nextCreated: true });
        continue;
      }

      const seriesRef  = db.collection("recurringEvents").doc(seriesId);
      const seriesSnap = await seriesRef.get();
      if (!seriesSnap.exists) {
        await doc.ref.update({ nextCreated: true });
        continue;
      }
      const series = seriesSnap.data();
      if (series.active === false) {
        await doc.ref.update({ nextCreated: true });
        continue;
      }

      const rule = series.rule || data.recurrenceRule;
      if (!rule) {
        await doc.ref.update({ nextCreated: true });
        continue;
      }

      const prevDate = data.date.toDate();
      const nextDate = computeNextRecurringDate(prevDate, rule);

      // Respect series end date
      if (rule.endDate && rule.endDate.toDate && nextDate > rule.endDate.toDate()) {
        await seriesRef.update({ active: false });
        await doc.ref.update({ nextCreated: true });
        console.log(`[createNextRecurringEvent] series ${seriesId} ended — past endDate`);
        continue;
      }

      const template = series.eventTemplate || {};
      // Mint a fresh shortCode for this occurrence. The template
      // shouldn't carry one (the Dart-side recurring-series writer
      // intentionally omits it) but the explicit assignment after
      // the spread guarantees uniqueness even if a stale template
      // somehow has the prior occurrence's code.
      const shortCode = await allocateUniqueShortCode(db);
      const newEventData = {
        ...template,
        hostId:   data.hostId,
        hostName: data.hostName,
        date:     Timestamp.fromDate(nextDate),
        shortCode,
        recurringSeriesId: seriesId,
        recurrenceRule:    rule,
        isRecurring: true,
        nextCreated: false,
        yes: 0, maybe: 0, no: 0,
        isArchived: false,
        isDraft: false,
        createdAt: FieldValue.serverTimestamp(),
      };

      const newRef = await db.collection("events").add(newEventData);
      await doc.ref.update({ nextCreated: true });
      await seriesRef.update({
        latestEventId:   newRef.id,
        latestEventDate: Timestamp.fromDate(nextDate),
      });
      console.log(`[createNextRecurringEvent] series ${seriesId}: ${doc.id} → ${newRef.id} (shortCode=${shortCode}) @ ${nextDate.toISOString()}`);

      // Notify previous Yes RSVPs
      try {
        const rsvpSnap = await doc.ref.collection("rsvps").where("status", "==", "Yes").get();
        const uids = rsvpSnap.docs.map((d) => d.id);
        if (uids.length === 0) continue;

        const userDocs = await Promise.all(uids.map((uid) => db.collection("users").doc(uid).get()));
        const tokens = userDocs
          .map((d) => d.data() && d.data().fcmToken)
          .filter((t) => typeof t === "string" && t.length > 0);
        if (tokens.length === 0) continue;

        const title = template.title || data.title || "Your event";
        const when  = nextDate.toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" });
        const messaging = getMessaging();
        for (let i = 0; i < tokens.length; i += 500) {
          await messaging.sendEachForMulticast({
            tokens: tokens.slice(i, i + 500),
            notification: {
              title: `🔄 Next ${title}`,
              body:  `It's back on ${when}. Tap to RSVP.`,
            },
            data: { eventId: newRef.id },
            android: { notification: { sound: "default", priority: "high", channel_id: "qrparty_default" } },
            apns:    { payload: { aps: { sound: "default", badge: 1 } } },
          });
        }
      } catch (err) {
        console.error(`[createNextRecurringEvent] notify failed for ${doc.id}:`, err);
      }
    }
  }
);

// ── WAITLIST NOTIFY ──────────────────────────────────────────
// Fires whenever an RSVP doc is written. If the change represents a "Yes →
// not-Yes" transition (a guest cancelled / changed their mind / the doc was
// deleted), and the event allows a waitlist, push an FCM notification to the
// first person on the waitlist (ordered by timestamp).

exports.notifyWaitlist = onDocumentWritten(
  "events/{eventId}/rsvps/{uid}",
  async (event) => {
    const before = event.data && event.data.before ? event.data.before.data() : null;
    const after  = event.data && event.data.after  ? event.data.after.data()  : null;
    const wasYes = before && before.status === "Yes";
    const isYes  = after  && after.status  === "Yes";
    if (!wasYes || isYes) return;

    const db = getFirestore();
    const eventRef = db.collection("events").doc(event.params.eventId);
    const eventSnap = await eventRef.get();
    if (!eventSnap.exists) return;

    const eventData = eventSnap.data();
    if (eventData.allowWaitlist !== true) return;

    const waitlistSnap = await eventRef.collection("waitlist")
      .orderBy("timestamp")
      .limit(1)
      .get();
    if (waitlistSnap.empty) return;

    const firstWait = waitlistSnap.docs[0];
    const fcmToken = firstWait.data().fcmToken;
    if (!fcmToken || typeof fcmToken !== "string" || fcmToken.length === 0) {
      console.log(`[notifyWaitlist] waitlist entry ${firstWait.id} has no FCM token, skipping`);
      return;
    }

    const eventTitle = eventData.title || "your event";
    try {
      await getMessaging().send({
        token: fcmToken,
        notification: {
          title: "A spot opened up! 🎉",
          body:  `A spot opened up at ${eventTitle}! Open QR Party to RSVP now.`,
        },
        data: { eventId: event.params.eventId, type: "waitlist_spot_open" },
        android: { notification: { sound: "default", priority: "high" } },
        apns:    { payload: { aps: { sound: "default", badge: 1 } } },
      });
      console.log(`[notifyWaitlist] notified ${firstWait.id} for event ${event.params.eventId}`);
    } catch (err) {
      console.error(`[notifyWaitlist] FCM send failed for ${firstWait.id}:`, err);
    }
  }
);
