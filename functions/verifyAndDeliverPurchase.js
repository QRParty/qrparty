const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { getFirestore, Timestamp } = require("firebase-admin/firestore");
const { google } = require("googleapis");

// Android package name registered in Play Console. Must match
// android/app/build.gradle.kts `applicationId` exactly — Play looks
// up purchase tokens scoped to a (package, productId) pair, so any
// drift here makes every validation fail with 404/400 from the API.
const PACKAGE_NAME = "com.qrparty.app";

// Product taxonomy. Subscription IDs go through subscriptionsv2.get;
// one-time IDs go through products.get. Acknowledgement endpoints
// differ between the two paths (acknowledgePurchase vs
// acknowledgeProduct) so the caller has to know which family the
// productId belongs to up front.
const SUBSCRIPTION_PRODUCT_IDS = new Set([
  "business_monthly",
  "business_yearly",
  "business_plus_monthly",
  "business_plus_yearly",
]);
const ONE_TIME_PRODUCT_IDS = new Set([
  "storage_25_events",
  "storage_50_events",
]);

// Per-product entitlement mapping. Mirrors the switch statement in
// lib/main.dart:_deliverPurchase so client and server agree on what
// fields land on users/{uid}. Keep these in sync — adding a tier on
// the client without updating this map will let purchases through
// validation but write nothing useful.
const SUBSCRIPTION_ENTITLEMENT = {
  business_monthly:      { accountType: "business",     subscriptionTier: "monthly" },
  business_yearly:       { accountType: "business",     subscriptionTier: "yearly" },
  business_plus_monthly: { accountType: "businessPlus", subscriptionTier: "monthly_plus" },
  business_plus_yearly:  { accountType: "businessPlus", subscriptionTier: "yearly_plus" },
};
const STORAGE_ENTITLEMENT = {
  storage_25_events: { archivedEventLimit: 25, storagePurchase: "storage_25_events" },
  storage_50_events: { archivedEventLimit: 50, storagePurchase: "storage_50_events" },
};

// Subscription states from purchases.subscriptionsv2.get that still
// represent a paying / entitled customer. ACTIVE is the steady state;
// IN_GRACE_PERIOD covers the window where Google Play retries a
// failed renewal but the user keeps access. Anything else (CANCELED,
// EXPIRED, ON_HOLD, PAUSED, PENDING) means we should NOT grant
// entitlement — the renewal/cancellation pipeline (RTDN handler,
// future work) will undo it.
const ENTITLED_SUBSCRIPTION_STATES = new Set([
  "SUBSCRIPTION_STATE_ACTIVE",
  "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
]);

// Lazy-initialized singleton Play API client. Cloud Functions reuse
// instances across invocations; building a fresh GoogleAuth client per
// call burns auth-token RTT. Initialized on first use, reused on
// subsequent invocations within the same instance lifecycle.
let _playApi = null;
async function getPlayApi() {
  if (_playApi) return _playApi;
  // Authenticates using the Cloud Function's runtime service
  // account — that account must be granted access in Play Console
  // (Setup → API Access → grant access to the project's GCF service
  // account). The androidpublisher scope is the only one needed.
  const auth = new google.auth.GoogleAuth({
    scopes: ["https://www.googleapis.com/auth/androidpublisher"],
  });
  const authClient = await auth.getClient();
  _playApi = google.androidpublisher({ version: "v3", auth: authClient });
  return _playApi;
}

exports.verifyAndDeliverPurchase = onCall(async (request) => {
  // Authn: every IAP fulfillment is per-user. onCall doesn't
  // auto-reject anonymous callers — without this guard a bad actor
  // could spoof a purchase delivery against any uid by passing it
  // in the body.
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Must be signed in");
  }
  const uid = request.auth.uid;

  const { productId, purchaseToken } = request.data || {};
  if (typeof productId !== "string" || productId.length === 0) {
    throw new HttpsError("invalid-argument", "productId is required");
  }
  if (typeof purchaseToken !== "string" || purchaseToken.length === 0) {
    throw new HttpsError("invalid-argument", "purchaseToken is required");
  }

  const isSubscription = SUBSCRIPTION_PRODUCT_IDS.has(productId);
  const isOneTime      = ONE_TIME_PRODUCT_IDS.has(productId);
  if (!isSubscription && !isOneTime) {
    throw new HttpsError("invalid-argument", `Unknown productId: ${productId}`);
  }

  const db = getFirestore();
  const userRef = db.collection("users").doc(uid);
  const playApi = await getPlayApi();

  if (isSubscription) {
    return await verifySubscription({ playApi, userRef, productId, purchaseToken, uid });
  }
  return await verifyOneTime({ playApi, userRef, productId, purchaseToken, uid });
});

async function verifySubscription({ playApi, userRef, productId, purchaseToken, uid }) {
  // purchases.subscriptionsv2.get is the canonical source for
  // entitlement state. Returns paymentState/subscriptionState/expiryTime
  // for the underlying base plan plus the acknowledgement state that
  // tells us whether we still owe Google an acknowledge call.
  let response;
  try {
    response = await playApi.purchases.subscriptionsv2.get({
      packageName: PACKAGE_NAME,
      token: purchaseToken,
    });
  } catch (err) {
    console.log(`[verifyAndDeliver] subscriptionsv2.get failed for uid=${uid} productId=${productId}: ${err.code} ${err.message}`);
    // 404 → token doesn't match a real purchase; 400 → malformed
    // request. Either way we can't trust the client's claim — refuse
    // entitlement rather than silently granting it.
    throw new HttpsError("permission-denied", "Purchase token could not be validated");
  }

  const purchase = response.data;
  const state = purchase.subscriptionState;
  if (!ENTITLED_SUBSCRIPTION_STATES.has(state)) {
    console.log(`[verifyAndDeliver] subscription not entitled uid=${uid} productId=${productId} state=${state}`);
    throw new HttpsError(
      "failed-precondition",
      `Subscription is not active (state=${state})`,
    );
  }

  // Defensive: confirm the productId the client claimed matches the
  // base plan on the actual purchase. Without this check, a user
  // could pass a real subscription token under a different productId
  // and get the wrong tier delivered.
  const lineItems = Array.isArray(purchase.lineItems) ? purchase.lineItems : [];
  const purchaseProductIds = lineItems.map((li) => li.productId).filter(Boolean);
  if (!purchaseProductIds.includes(productId)) {
    console.log(`[verifyAndDeliver] productId mismatch uid=${uid} claimed=${productId} actual=${purchaseProductIds.join(",")}`);
    throw new HttpsError("permission-denied", "productId does not match purchase token");
  }

  // expiryTime sits per-line-item on subscriptionsv2 responses.
  // Format is RFC 3339 (e.g. "2026-06-15T03:14:15.123Z"). We pick
  // the matching line item's expiry; fall back to the first one
  // if the productId match is ambiguous (shouldn't happen — the
  // mismatch check above guards it).
  const matchedLine = lineItems.find((li) => li.productId === productId) || lineItems[0];
  const expiryIso   = matchedLine && matchedLine.expiryTime;
  const expiryDate  = expiryIso ? new Date(expiryIso) : null;
  if (!expiryDate || isNaN(expiryDate.getTime())) {
    console.log(`[verifyAndDeliver] missing/unparseable expiryTime uid=${uid} productId=${productId} expiryIso=${expiryIso}`);
    throw new HttpsError("internal", "Could not read subscription expiry");
  }

  // Acknowledge within 3 days of purchase or Google auto-refunds
  // the user. The flag on the response tells us whether we still
  // owe an acknowledge call — re-acking an already-acked purchase
  // is a no-op but a wasted API call, so gate on the state.
  if (purchase.acknowledgementState === "ACKNOWLEDGEMENT_STATE_PENDING") {
    try {
      await playApi.purchases.subscriptions.acknowledge({
        packageName: PACKAGE_NAME,
        subscriptionId: productId,
        token: purchaseToken,
      });
      console.log(`[verifyAndDeliver] acknowledged subscription uid=${uid} productId=${productId}`);
    } catch (err) {
      // Acknowledgement is critical for keeping the purchase from
      // auto-refunding, but we've already validated entitlement; log
      // loudly and continue rather than refusing delivery (the user
      // shouldn't pay the price for a transient Play API hiccup).
      console.log(`[verifyAndDeliver] acknowledge failed uid=${uid} productId=${productId}: ${err.code} ${err.message}`);
    }
  }

  // Map productId → entitlement fields. Layered with the validated
  // expiryTime + the raw purchase token so downstream code (renewal
  // sync, refund revocation) has a back-pointer to call the Play
  // API again. Mirrors the field shape in lib/main.dart:_deliverPurchase
  // so the client-side _watchActivation listener picks up the change.
  const map = SUBSCRIPTION_ENTITLEMENT[productId];
  await userRef.update({
    accountType:               map.accountType,
    isTrialing:                false,
    subscriptionTier:          map.subscriptionTier,
    subscriptionExpiry:        Timestamp.fromDate(expiryDate),
    subscriptionPurchaseToken: purchaseToken,
    subscriptionProductId:     productId,
    subscriptionState:         state,
    subscriptionVerifiedAt:    Timestamp.now(),
  });

  console.log(`[verifyAndDeliver] delivered subscription uid=${uid} productId=${productId} expires=${expiryDate.toISOString()}`);
  return {
    ok:        true,
    productId,
    state,
    expiryTime: expiryDate.toISOString(),
  };
}

async function verifyOneTime({ playApi, userRef, productId, purchaseToken, uid }) {
  // purchases.products.get returns the product purchase record. The
  // `purchaseState` enum values: 0=purchased, 1=canceled, 2=pending.
  // We only deliver entitlement for state 0.
  let response;
  try {
    response = await playApi.purchases.products.get({
      packageName: PACKAGE_NAME,
      productId,
      token: purchaseToken,
    });
  } catch (err) {
    console.log(`[verifyAndDeliver] products.get failed for uid=${uid} productId=${productId}: ${err.code} ${err.message}`);
    throw new HttpsError("permission-denied", "Purchase token could not be validated");
  }

  const purchase = response.data;
  if (purchase.purchaseState !== 0) {
    console.log(`[verifyAndDeliver] one-time not purchased uid=${uid} productId=${productId} state=${purchase.purchaseState}`);
    throw new HttpsError(
      "failed-precondition",
      `Purchase is not in 'purchased' state (state=${purchase.purchaseState})`,
    );
  }

  // Acknowledge if Google still expects it. Mirrors the subscription
  // path — 3-day window before auto-refund.
  if (purchase.acknowledgementState === 0) {
    try {
      await playApi.purchases.products.acknowledge({
        packageName: PACKAGE_NAME,
        productId,
        token: purchaseToken,
      });
      console.log(`[verifyAndDeliver] acknowledged product uid=${uid} productId=${productId}`);
    } catch (err) {
      console.log(`[verifyAndDeliver] product acknowledge failed uid=${uid} productId=${productId}: ${err.code} ${err.message}`);
    }
  }

  // Storage upgrades are non-consumables — no consumption call.
  // Field shape mirrors lib/main.dart:_deliverPurchase exactly so a
  // legacy client write and a server-validated write are
  // indistinguishable in Firestore.
  const map = STORAGE_ENTITLEMENT[productId];
  await userRef.update({
    archivedEventLimit:     map.archivedEventLimit,
    storagePurchase:        map.storagePurchase,
    purchaseToken,
    storageProductId:       productId,
    storageVerifiedAt:      Timestamp.now(),
  });

  console.log(`[verifyAndDeliver] delivered one-time uid=${uid} productId=${productId}`);
  return {
    ok:        true,
    productId,
    state:     "purchased",
  };
}
