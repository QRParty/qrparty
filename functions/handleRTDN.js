const { onMessagePublished } = require("firebase-functions/v2/pubsub");
const { getFirestore, Timestamp, FieldValue } = require("firebase-admin/firestore");
const { google } = require("googleapis");

// Android package name registered in Play Console. Must match
// android/app/build.gradle.kts `applicationId` exactly — Play scopes
// purchaseTokens to a (package, productId) pair, so a mismatch here
// makes every subscriptionsv2.get call fail with 404/400.
const PACKAGE_NAME = "com.qrparty.app";

// Subscriptions we recognise. RTDN payloads carry the subscriptionId
// but a stale / unknown id is still worth logging — it means a Play
// Console product was added without updating this codebase.
const SUBSCRIPTION_PRODUCT_IDS = new Set([
  "business_monthly",
  "business_yearly",
  "business_plus_monthly",
  "business_plus_yearly",
]);

// Same mapping used by verifyAndDeliverPurchase. Kept in lockstep so a
// renewal / recovery RTDN restores the user to exactly the same
// accountType + subscriptionTier the initial purchase delivered.
const SUBSCRIPTION_ENTITLEMENT = {
  business_monthly:      { accountType: "business",     subscriptionTier: "monthly" },
  business_yearly:       { accountType: "business",     subscriptionTier: "yearly" },
  business_plus_monthly: { accountType: "businessPlus", subscriptionTier: "monthly_plus" },
  business_plus_yearly:  { accountType: "businessPlus", subscriptionTier: "yearly_plus" },
};

// Google Play subscription notification types
// (developer.android.com/google/play/billing/rtdn-reference#sub).
// Numeric values are fixed by Google; the labels here are for log
// readability only.
const SUB_NOTIFICATION_TYPES = {
  1:  "SUBSCRIPTION_RECOVERED",
  2:  "SUBSCRIPTION_RENEWED",
  3:  "SUBSCRIPTION_CANCELED",
  4:  "SUBSCRIPTION_PURCHASED",
  5:  "SUBSCRIPTION_ON_HOLD",
  6:  "SUBSCRIPTION_IN_GRACE_PERIOD",
  7:  "SUBSCRIPTION_RESTARTED",
  8:  "SUBSCRIPTION_PRICE_CHANGE_CONFIRMED",
  9:  "SUBSCRIPTION_DEFERRED",
  10: "SUBSCRIPTION_PAUSED",
  11: "SUBSCRIPTION_PAUSE_SCHEDULE_CHANGED",
  12: "SUBSCRIPTION_REVOKED",
  13: "SUBSCRIPTION_EXPIRED",
};

// Types this handler acts on. The remaining types either don't need
// a Firestore update (PRICE_CHANGE_CONFIRMED, DEFERRED, PAUSED, etc.)
// or are handled by the initial-purchase flow (PURCHASED, fulfilled
// via verifyAndDeliverPurchase from the client). Listed in the spec.
const HANDLED_TYPES = new Set([
  1,  // RECOVERED — back from a payment failure; restore entitlement
  2,  // RENEWED   — auto-renewed; refresh expiry
  3,  // CANCELED  — user canceled future renewal but current period still entitled
  5,  // ON_HOLD   — payment failing; revoke entitlement until recovered
  6,  // IN_GRACE_PERIOD — payment failed, still entitled briefly
  12, // REVOKED   — refund / chargeback; revoke immediately
  13, // EXPIRED   — period ended without renewal; revoke
]);

// Lazy-initialized Play API client. Same pattern as
// verifyAndDeliverPurchase — Cloud Functions reuse instances within
// a single container's lifetime, so building one GoogleAuth client
// per cold start (not per invocation) saves an auth round-trip.
let _playApi = null;
async function getPlayApi() {
  if (_playApi) return _playApi;
  const auth = new google.auth.GoogleAuth({
    scopes: ["https://www.googleapis.com/auth/androidpublisher"],
  });
  const authClient = await auth.getClient();
  _playApi = google.androidpublisher({ version: "v3", auth: authClient });
  return _playApi;
}

exports.handleRTDN = onMessagePublished("play-rtdn", async (event) => {
  // Pub/Sub delivers the RTDN payload base64-encoded in
  // `event.data.message.data`. Decoded body is JSON matching the
  // DeveloperNotification shape from the Play Billing docs.
  const raw = event.data && event.data.message && event.data.message.data;
  if (!raw) {
    console.log("[handleRTDN] empty message body — dropping");
    return;
  }

  let payload;
  try {
    const decoded = Buffer.from(raw, "base64").toString("utf8");
    payload = JSON.parse(decoded);
  } catch (err) {
    console.log(`[handleRTDN] failed to decode/parse RTDN body: ${err.message}`);
    return;
  }

  // Test notifications fire when the Pub/Sub topic is verified in
  // Play Console. They have no purchase data — just acknowledge by
  // returning so the message doesn't redeliver forever.
  if (payload.testNotification) {
    console.log(`[handleRTDN] test notification version=${payload.testNotification.version}`);
    return;
  }

  // Sanity-check that the notification is for our package. RTDN
  // shouldn't fire for other apps, but a Pub/Sub topic shared with
  // multiple projects (or a misconfigured forwarder) could in
  // theory deliver foreign messages.
  if (payload.packageName && payload.packageName !== PACKAGE_NAME) {
    console.log(`[handleRTDN] foreign package name=${payload.packageName} — dropping`);
    return;
  }

  // We currently only act on subscription notifications. One-time
  // product notifications (oneTimeProductNotification) and voided-
  // purchase notifications (voidedPurchaseNotification) are
  // recognised below and logged, but their handlers are TODO — the
  // storage upgrade flow doesn't need cancellation handling today
  // because storage is non-consumable.
  if (payload.oneTimeProductNotification) {
    console.log(`[handleRTDN] oneTimeProductNotification type=${payload.oneTimeProductNotification.notificationType} sku=${payload.oneTimeProductNotification.sku} — not yet handled`);
    return;
  }
  if (payload.voidedPurchaseNotification) {
    console.log(`[handleRTDN] voidedPurchaseNotification refundType=${payload.voidedPurchaseNotification.refundType} — not yet handled`);
    return;
  }
  if (!payload.subscriptionNotification) {
    console.log(`[handleRTDN] no subscriptionNotification in payload — dropping`, payload);
    return;
  }

  const sub = payload.subscriptionNotification;
  const notificationType = sub.notificationType;
  const purchaseToken    = sub.purchaseToken;
  const subscriptionId   = sub.subscriptionId;
  const typeLabel = SUB_NOTIFICATION_TYPES[notificationType] || `UNKNOWN(${notificationType})`;

  if (!purchaseToken) {
    console.log(`[handleRTDN] ${typeLabel} missing purchaseToken — dropping`);
    return;
  }
  if (!subscriptionId) {
    console.log(`[handleRTDN] ${typeLabel} missing subscriptionId — dropping`);
    return;
  }
  if (!SUBSCRIPTION_PRODUCT_IDS.has(subscriptionId)) {
    console.log(`[handleRTDN] ${typeLabel} unknown subscriptionId=${subscriptionId} — dropping`);
    return;
  }
  if (!HANDLED_TYPES.has(notificationType)) {
    console.log(`[handleRTDN] ${typeLabel} not in handled set — acknowledging without action`);
    return;
  }

  console.log(`[handleRTDN] ${typeLabel} subscriptionId=${subscriptionId} tokenSuffix=…${purchaseToken.slice(-8)}`);

  // Find the user this purchase belongs to. We stamp
  // `subscriptionPurchaseToken` on users/{uid} during the initial
  // verifyAndDeliverPurchase delivery, so a where() on that field
  // returns the right row. .limit(1) because the token is globally
  // unique to one subscriber.
  const db = getFirestore();
  const usersSnap = await db.collection("users")
    .where("subscriptionPurchaseToken", "==", purchaseToken)
    .limit(1)
    .get();

  if (usersSnap.empty) {
    console.log(`[handleRTDN] ${typeLabel} no user matches token suffix=…${purchaseToken.slice(-8)} — likely RTDN arrived before client validation; will retry on Pub/Sub redelivery`);
    // Throw so Pub/Sub retries — the client may not have called
    // verifyAndDeliverPurchase yet, in which case the token isn't on
    // any user doc. Pub/Sub redelivers with backoff, giving the
    // client time to register. After the redelivery window expires
    // the message goes to the dead-letter topic (configurable per
    // subscription) without entitlement drift, since RENEWED/EXPIRED
    // events on a token that was never claimed are no-ops anyway.
    throw new Error("user-not-found");
  }
  const userDoc = usersSnap.docs[0];
  const uid = userDoc.id;

  // Fetch the authoritative state from Google. We do NOT trust the
  // RTDN notificationType alone — by the time we read this, the
  // subscription may have already moved on (e.g. CANCELED then
  // immediately RECOVERED). subscriptionsv2.get returns the current
  // truth.
  let purchase;
  try {
    const playApi = await getPlayApi();
    const response = await playApi.purchases.subscriptionsv2.get({
      packageName: PACKAGE_NAME,
      token: purchaseToken,
    });
    purchase = response.data;
  } catch (err) {
    console.log(`[handleRTDN] subscriptionsv2.get failed uid=${uid} ${typeLabel}: ${err.code} ${err.message}`);
    // Rethrow so Pub/Sub retries on transient API errors. A 404
    // here is unusual (the token came from Google in the first
    // place) but possible if the user revoked the purchase
    // simultaneously — log and continue would be wrong because we
    // wouldn't know the final state.
    throw err;
  }

  const state = purchase.subscriptionState;
  const lineItems = Array.isArray(purchase.lineItems) ? purchase.lineItems : [];
  const matchedLine = lineItems.find((li) => li.productId === subscriptionId) || lineItems[0];
  const expiryIso = matchedLine && matchedLine.expiryTime;
  const expiryDate = expiryIso ? new Date(expiryIso) : null;

  const entitlement = SUBSCRIPTION_ENTITLEMENT[subscriptionId];

  // Subscription upgrade / replacement: Google emits a new token
  // and links the prior one. The notification's purchaseToken is
  // the OLD one; if linkedPurchaseToken is set, that's the NEW one
  // the client should be using. Worth logging but doesn't change
  // our action — the OLD token is what we matched on, and the
  // user's accountType is updated based on the OLD subscription's
  // current state (which Google flips to CANCELED at the moment of
  // the upgrade). The NEW token will arrive via its own
  // verifyAndDeliverPurchase call from the client.
  if (purchase.linkedPurchaseToken) {
    console.log(`[handleRTDN] linkedPurchaseToken present — subscription was upgraded/replaced uid=${uid}`);
  }

  // Decide what to write to users/{uid} based on (notificationType,
  // authoritative state). The state machine:
  //
  //   RENEWED / RECOVERED → state is ACTIVE; refresh expiry, keep
  //     entitlement, ensure accountType matches the tier.
  //   IN_GRACE_PERIOD → user is briefly past expiry but Play is
  //     retrying; keep entitlement, update state + expiry.
  //   CANCELED → user clicked "Cancel" in Play; auto-renew is off
  //     but the current period is still paid for. Keep entitlement
  //     until the EXPIRED notification arrives at period end. Just
  //     stamp the new state.
  //   ON_HOLD → Play gave up retrying; user is no longer entitled.
  //     Downgrade accountType immediately.
  //   EXPIRED / REVOKED → entitlement gone for good. Downgrade and
  //     clear the expiry / token fields so a future client doesn't
  //     re-attempt validation against a dead token.
  const updates = {
    subscriptionState:      state,
    subscriptionRtdnUpdatedAt: Timestamp.now(),
  };
  if (expiryDate && !isNaN(expiryDate.getTime())) {
    updates.subscriptionExpiry = Timestamp.fromDate(expiryDate);
  }

  if (notificationType === 2  /* RENEWED   */ ||
      notificationType === 1  /* RECOVERED */ ||
      notificationType === 6  /* IN_GRACE_PERIOD */) {
    // Still entitled. Reinstate accountType from the productId
    // mapping — covers the RECOVERED case where ON_HOLD previously
    // downgraded the user to personal.
    updates.accountType      = entitlement.accountType;
    updates.subscriptionTier = entitlement.subscriptionTier;
    updates.isTrialing       = false;
  } else if (notificationType === 3 /* CANCELED */) {
    // User canceled but current period still valid. Don't touch
    // accountType — they're paid through the existing expiry. Just
    // surface the cancellation so UI can show "renewing → ending
    // on <date>" copy.
    updates.subscriptionCanceledAt = Timestamp.now();
  } else if (notificationType === 5  /* ON_HOLD   */ ||
             notificationType === 12 /* REVOKED   */ ||
             notificationType === 13 /* EXPIRED   */) {
    // Entitlement revoked. Downgrade to personal. ON_HOLD is the
    // recoverable case (RECOVERED notification will restore), so
    // we keep the token field around for that. REVOKED/EXPIRED are
    // terminal — clear the token so any leftover client retry can
    // see there's nothing to validate.
    updates.accountType      = "personal";
    updates.subscriptionTier = null;
    if (notificationType !== 5) {
      updates.subscriptionExpiry        = null;
      updates.subscriptionPurchaseToken = FieldValue.delete();
    }
  }

  await userDoc.ref.update(updates);
  console.log(`[handleRTDN] ${typeLabel} updated uid=${uid} → accountType=${updates.accountType ?? "(unchanged)"} state=${state} expiry=${expiryDate ? expiryDate.toISOString() : "n/a"}`);
});
