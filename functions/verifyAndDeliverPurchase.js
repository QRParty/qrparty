const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const { getFirestore, Timestamp } = require("firebase-admin/firestore");
const { google } = require("googleapis");
const jwt = require("jsonwebtoken");

// Android package name registered in Play Console. Must match
// android/app/build.gradle.kts `applicationId` exactly — Play looks
// up purchase tokens scoped to a (package, productId) pair, so any
// drift here makes every validation fail with 404/400 from the API.
const PACKAGE_NAME = "com.qrparty.app";

// ── Apple App Store Server API constants ────────────────────────
// Bundle ID registered in App Store Connect — must match the iOS
// app's CFBundleIdentifier exactly. Apple scopes JWTs by bundle ID
// in the `bid` claim, so a mismatch makes every request 401/403.
const APPLE_BUNDLE_ID    = "com.qrparty.app";
const APPLE_KEY_ID       = "H763GZ8Z7P";
const APPLE_ISSUER_ID    = "761158e3-7d00-44c7-b92a-6c53d049f7cd";
const APPLE_AUDIENCE     = "appstoreconnect-v1";
const APPLE_API_HOST_PROD    = "https://api.storekit.itunes.apple.com";
const APPLE_API_HOST_SANDBOX = "https://api.storekit-sandbox.itunes.apple.com";

// Secret holding the .p8 private key Apple issued for App Store
// Connect API access. Configure via:
//   firebase functions:secrets:set APPLE_IAP_PRIVATE_KEY
// then paste the contents of AuthKey_H763GZ8Z7P.p8 (including the
// `-----BEGIN PRIVATE KEY-----` / `-----END PRIVATE KEY-----`
// boundary lines). `jsonwebtoken` accepts the PEM string directly.
const appleIapPrivateKey = defineSecret("APPLE_IAP_PRIVATE_KEY");

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

// Heuristic platform detection for clients that don't (yet) pass an
// explicit `platform` field. Apple StoreKit 2 transaction IDs are
// 12-25 digit numeric strings; Google Play purchase tokens are
// ~600+ chars with mixed alphanum + dots + dashes + underscores, so
// the two shapes are unambiguously different. When the client passes
// `platform: 'ios' | 'android'` we honor it directly.
//
// CAVEAT: StoreKit 1 (pre-iOS 15) returns base64-encoded receipts as
// `serverVerificationData` rather than transaction IDs. Those would
// land as "android" under this heuristic. Real protection comes from
// the explicit `platform` param the updated client sends.
function detectPlatform(explicit, purchaseToken) {
  if (explicit === "ios" || explicit === "android") return explicit;
  return /^\d{8,25}$/.test(purchaseToken) ? "ios" : "android";
}

// ── Apple JWT minting ───────────────────────────────────────────
/// Builds the short-lived bearer token the App Store Server API
/// requires for every request. Apple accepts JWTs up to 60 minutes
/// old; we use 20 minutes for safety. Algorithm is ES256 (ECDSA
/// P-256 + SHA-256) — the .p8 file Apple issues is already in the
/// right PEM format for `jsonwebtoken` to consume directly.
function mintAppleJwt(privateKeyPem) {
  const now = Math.floor(Date.now() / 1000);
  return jwt.sign(
    {
      iss: APPLE_ISSUER_ID,
      iat: now,
      exp: now + 1200,     // 20 minutes
      aud: APPLE_AUDIENCE,
      bid: APPLE_BUNDLE_ID,
    },
    privateKeyPem,
    {
      algorithm: "ES256",
      header: {
        alg: "ES256",
        kid: APPLE_KEY_ID,
        typ: "JWT",
      },
    },
  );
}

/// Fetches a transaction from Apple's API. Returns `{response, environment}`
/// where `environment` is "Production" or "Sandbox". Internal helper —
/// callers should use [getAppleTransaction] which handles the prod →
/// sandbox fallback.
async function fetchAppleTransactionRaw(transactionId, bearer, environment) {
  const host = environment === "Production"
    ? APPLE_API_HOST_PROD
    : APPLE_API_HOST_SANDBOX;
  const url = `${host}/inApps/v1/transactions/${encodeURIComponent(transactionId)}`;
  return fetch(url, {
    method: "GET",
    headers: {
      Authorization: `Bearer ${bearer}`,
      Accept: "application/json",
    },
  });
}

/// Resolves an iOS transactionId to its decoded App Store record.
/// Production-first with sandbox fallback so TestFlight / sandbox
/// purchases work without a separate code path. Returns the decoded
/// JWS payload (which carries transactionId, productId, expiresDate,
/// revocationDate, bundleId, environment, etc.).
///
/// We decode but don't verify the JWS signature on the returned
/// transaction — Apple delivers it over TLS in a session
/// authenticated with our App Store Connect JWT, so the transport
/// itself is the trust anchor. Full JWS chain verification is a
/// future hardening item (would require Apple root cert + x5c chain
/// walk).
async function getAppleTransaction(transactionId) {
  const privateKeyPem = appleIapPrivateKey.value();
  if (!privateKeyPem || privateKeyPem.length === 0) {
    console.log("[verifyAndDeliver/apple] APPLE_IAP_PRIVATE_KEY secret is empty");
    throw new HttpsError("internal", "Apple IAP key not configured");
  }
  const bearer = mintAppleJwt(privateKeyPem);

  // Try production first — most real-world traffic.
  let response = await fetchAppleTransactionRaw(transactionId, bearer, "Production");
  let environment = "Production";

  // 404 from production typically means "this transaction was made in
  // sandbox" — Apple's TestFlight / sandbox purchases live on a
  // separate endpoint. Per Apple's docs, the right move is to retry
  // the sandbox host with the same JWT.
  if (response.status === 404) {
    console.log(`[verifyAndDeliver/apple] tx not in production — retrying sandbox tx=${transactionId}`);
    response = await fetchAppleTransactionRaw(transactionId, bearer, "Sandbox");
    environment = "Sandbox";
  }

  if (!response.ok) {
    // Apple's error codes: 401 = bad JWT, 403 = bundle mismatch,
    // 404 = transaction missing in BOTH environments. None of these
    // should grant entitlement.
    let bodyPreview = "";
    try { bodyPreview = (await response.text()).slice(0, 200); } catch (_) {}
    console.log(`[verifyAndDeliver/apple] API returned ${response.status} for tx=${transactionId} body=${bodyPreview}`);
    throw new HttpsError("permission-denied", "Apple transaction could not be validated");
  }

  let body;
  try {
    body = await response.json();
  } catch (_) {
    throw new HttpsError("internal", "Malformed Apple API response (not JSON)");
  }
  const signedTx = body && body.signedTransactionInfo;
  if (typeof signedTx !== "string" || signedTx.length === 0) {
    throw new HttpsError("internal", "Apple response missing signedTransactionInfo");
  }
  const decoded = jwt.decode(signedTx);
  if (!decoded || typeof decoded !== "object") {
    throw new HttpsError("internal", "Could not decode Apple transaction JWS");
  }
  return { decoded, environment };
}

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

exports.verifyAndDeliverPurchase = onCall(
  { secrets: [appleIapPrivateKey] },
  async (request) => {
    // Authn: every IAP fulfillment is per-user. onCall doesn't
    // auto-reject anonymous callers — without this guard a bad actor
    // could spoof a purchase delivery against any uid by passing it
    // in the body.
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be signed in");
    }
    const uid = request.auth.uid;

    const { productId, purchaseToken, platform: explicitPlatform } = request.data || {};
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

    const platform = detectPlatform(explicitPlatform, purchaseToken);
    console.log(`[verifyAndDeliver] uid=${uid} productId=${productId} platform=${platform} explicit=${explicitPlatform || "(none)"}`);

    const db = getFirestore();
    const userRef = db.collection("users").doc(uid);

    if (platform === "ios") {
      return await verifyApplePurchase({
        userRef, productId, purchaseToken, uid, isSubscription,
      });
    }

    // Android — existing path.
    const playApi = await getPlayApi();
    if (isSubscription) {
      return await verifySubscription({ playApi, userRef, productId, purchaseToken, uid });
    }
    return await verifyOneTime({ playApi, userRef, productId, purchaseToken, uid });
  }
);

/// Validates an iOS purchase via the App Store Server API and writes
/// entitlement to users/{uid}. Handles both subscriptions and one-time
/// products through the same /inApps/v1/transactions/{id} endpoint
/// (Apple doesn't split these the way Google does — the same record
/// shape carries product type via the `type` field).
///
/// Field shape matches the Android branch exactly so the client-side
/// listener can ignore platform differences. Adds `subscriptionPlatform`
/// / `storagePlatform: 'ios'` plus `subscriptionEnvironment` /
/// `storageEnvironment` ("Production" | "Sandbox") so the future
/// App Store Server Notifications V2 handler can:
///   • Tell iOS records apart from Android records by platform tag.
///   • Skip iOS records in the existing handleRTDN (Google Play-only).
///   • Route sandbox notifications correctly.
async function verifyApplePurchase({
  userRef, productId, purchaseToken, uid, isSubscription,
}) {
  // The Flutter `in_app_purchase` plugin sends `serverVerificationData`
  // as the iOS transaction ID on StoreKit 2 — that's the value the
  // client just passed as `purchaseToken`. Hit Apple's API for the
  // signed transaction info.
  let txData;
  try {
    txData = await getAppleTransaction(purchaseToken);
  } catch (err) {
    if (err instanceof HttpsError) throw err;
    console.log(`[verifyAndDeliver/apple] tx fetch failed uid=${uid} tx=${purchaseToken}: ${err.message}`);
    throw new HttpsError("permission-denied", "Apple transaction could not be validated");
  }
  const tx = txData.decoded;
  const environment = txData.environment;

  // Bundle ID guard — Apple does scope JWTs by bundle, but a missing
  // / spoofed transaction could in theory carry a different bundleId.
  // Reject outright rather than deliver under the wrong app.
  if (tx.bundleId && tx.bundleId !== APPLE_BUNDLE_ID) {
    console.log(`[verifyAndDeliver/apple] bundleId mismatch uid=${uid} claimed=${APPLE_BUNDLE_ID} actual=${tx.bundleId}`);
    throw new HttpsError("permission-denied", "Bundle ID mismatch");
  }

  // ProductId guard — defense against a real transaction passed under
  // a different productId to wangle the wrong tier.
  if (tx.productId !== productId) {
    console.log(`[verifyAndDeliver/apple] productId mismatch uid=${uid} claimed=${productId} actual=${tx.productId}`);
    throw new HttpsError("permission-denied", "productId does not match transaction");
  }

  // Refund / revocation guard. Apple stamps `revocationDate` (ms
  // epoch) on transactions that were refunded or charged back. We
  // never grant entitlement on a revoked transaction — handleRTDN's
  // Apple equivalent (App Store Server Notifications V2, not yet
  // implemented) will downgrade the user separately if the refund
  // happens after the initial delivery.
  if (typeof tx.revocationDate === "number" && tx.revocationDate > 0) {
    console.log(`[verifyAndDeliver/apple] tx revoked uid=${uid} tx=${purchaseToken} revokedAt=${new Date(tx.revocationDate).toISOString()}`);
    throw new HttpsError("failed-precondition", "Transaction has been revoked");
  }

  if (isSubscription) {
    // Subscriptions carry `expiresDate` (ms epoch). Anything in the
    // past means the period ended without renewal.
    const expiresMs = tx.expiresDate;
    if (typeof expiresMs !== "number" || expiresMs <= 0) {
      console.log(`[verifyAndDeliver/apple] missing/invalid expiresDate uid=${uid} tx=${purchaseToken}`);
      throw new HttpsError("internal", "Could not read subscription expiry");
    }
    const expiryDate = new Date(expiresMs);
    if (expiryDate.getTime() <= Date.now()) {
      console.log(`[verifyAndDeliver/apple] subscription expired uid=${uid} expired=${expiryDate.toISOString()}`);
      throw new HttpsError("failed-precondition", "Subscription is expired");
    }

    const map = SUBSCRIPTION_ENTITLEMENT[productId];
    await userRef.update({
      accountType:               map.accountType,
      isTrialing:                false,
      subscriptionTier:          map.subscriptionTier,
      subscriptionExpiry:        Timestamp.fromDate(expiryDate),
      subscriptionPurchaseToken: purchaseToken,
      subscriptionProductId:     productId,
      subscriptionState:         "ACTIVE",
      subscriptionPlatform:      "ios",
      subscriptionEnvironment:   environment,
      subscriptionVerifiedAt:    Timestamp.now(),
    });
    console.log(`[verifyAndDeliver/apple] delivered subscription uid=${uid} productId=${productId} expires=${expiryDate.toISOString()} env=${environment}`);
    return {
      ok:        true,
      productId,
      state:     "ACTIVE",
      platform:  "ios",
      environment,
      expiryTime: expiryDate.toISOString(),
    };
  }

  // One-time product (storage upgrade). No expiry check — these are
  // non-consumable so a valid transaction means lifetime entitlement.
  const map = STORAGE_ENTITLEMENT[productId];
  await userRef.update({
    archivedEventLimit:   map.archivedEventLimit,
    storagePurchase:      map.storagePurchase,
    purchaseToken,
    storageProductId:     productId,
    storagePlatform:      "ios",
    storageEnvironment:   environment,
    storageVerifiedAt:    Timestamp.now(),
  });
  console.log(`[verifyAndDeliver/apple] delivered one-time uid=${uid} productId=${productId} env=${environment}`);
  return {
    ok:        true,
    productId,
    state:     "purchased",
    platform:  "ios",
    environment,
  };
}

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
