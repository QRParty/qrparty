const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { generatePrintFile } = require("./generatePrintFile");

// Reused from index.js — Cloud Functions v2 needs each function to declare
// the secrets it touches.
const stripeSecretKey = defineSecret("STRIPE_SECRET_KEY");

// Pricing must match lib/models/merch_order.dart — keep in sync.
// Standard shipping is included in pack prices (free). Expedited is
// the only surcharge.
const STICKER_CENTS  = { 10: 2499, 25: 4499, 50: 7499 };
const INVITE_CENTS   = { 25: 3999, 50: 6499, 100: 10499 };
const SHIP_STANDARD  = 0;
const SHIP_EXPEDITED = 999;
const STRIPE_PCT     = 0.029;
const STRIPE_FLAT    = 30;

// Must mirror the keys in lib/models/merch_order.dart `merchThemes`.
// Dropping "custom" since the customer-design upload flow was removed.
const ALLOWED_THEMES = [
  "classic", "superhero", "princess", "pirate",
  "dinosaur", "space", "unicorn", "sports",
  "animals", "circus", "mermaids",
];

function priceCents({ productType, packSize }) {
  return (productType === "invitation" ? INVITE_CENTS : STICKER_CENTS)[packSize] ?? null;
}
function shipCents(speed) {
  return speed === "expedited" ? SHIP_EXPEDITED : SHIP_STANDARD;
}
function isTestPaymentIntent(id) {
  return typeof id === "string" && id.startsWith("pi_test_mock_");
}

exports.createMerchOrder = onCall(
  { secrets: [stripeSecretKey] },
  async (request) => {
    // Capture invocation context up front so every log line is correlatable.
    const callId = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
    const log = (msg, extra) => console.log(`[createMerchOrder ${callId}] ${msg}`, extra || "");
    const uid = request.auth?.uid;
    log("invoke", { uid, hasData: !!request.data });

    try {
      if (!uid) throw new HttpsError("unauthenticated", "Sign in required");

      const {
        eventId, productType, packSize,
        theme = "classic", themeVariant = 0, customDesignUrl,
        shippingAddress, shippingSpeed, paymentIntentId,
      } = request.data || {};

      // ── Validate input ────────────────────────────────────────
      if (!eventId || !productType || !packSize || !shippingAddress || !shippingSpeed || !paymentIntentId) {
        throw new HttpsError("invalid-argument", "Missing required fields");
      }
      if (!["sticker", "invitation"].includes(productType)) {
        throw new HttpsError("invalid-argument", "productType must be sticker or invitation");
      }
      if (!["standard", "expedited"].includes(shippingSpeed)) {
        throw new HttpsError("invalid-argument", "Invalid shippingSpeed");
      }
      if (!ALLOWED_THEMES.includes(theme)) {
        throw new HttpsError("invalid-argument", `Invalid theme: ${theme}`);
      }

      const subtotal = priceCents({ productType, packSize });
      if (subtotal == null) throw new HttpsError("invalid-argument", `No price for ${productType} ${packSize}`);
      const shipping = shipCents(shippingSpeed);
      const total = subtotal + shipping;
      const stripeFee = Math.round(total * STRIPE_PCT) + STRIPE_FLAT;
      const isTest = isTestPaymentIntent(paymentIntentId);
      log("validated", { eventId, productType, packSize, theme, total, isTest });

      const db = getFirestore();

      // ── Verify event + ownership ─────────────────────────────
      const eventSnap = await db.collection("events").doc(eventId).get();
      if (!eventSnap.exists) throw new HttpsError("not-found", "Event not found");
      const event = eventSnap.data();
      if (event.hostId !== uid) {
        throw new HttpsError("permission-denied", "Only the event host can order merchandise");
      }
      log("event ok", { hostId: event.hostId });

      // ── Verify Stripe (skipped in test mode) ─────────────────
      if (!isTest) {
        const Stripe = require("stripe");
        const stripe = Stripe(stripeSecretKey.value());
        const pi = await stripe.paymentIntents.retrieve(paymentIntentId);
        if (pi.status !== "succeeded") {
          throw new HttpsError("failed-precondition", `PaymentIntent not succeeded: ${pi.status}`);
        }
        if (pi.amount !== total) {
          throw new HttpsError("failed-precondition", `Amount mismatch: expected ${total} got ${pi.amount}`);
        }
        log("stripe verified");
      } else {
        log("test mode — skipping stripe verify");
      }

      // ── Pull customer profile for name/email ─────────────────
      const userSnap = await db.collection("users").doc(uid).get();
      const userData = userSnap.exists ? userSnap.data() : {};
      const customerName  = userData.displayName || userData.name || event.hostName || "QR Party customer";
      const customerEmail = userData.email || request.auth.token.email || "";
      const accountTier   = (userData.accountType === "business" || userData.accountType === "businessPlus")
        ? userData.accountType : "personal";

      // 3 days processing + shipping window
      const shipDays = shippingSpeed === "expedited" ? 3 : 7;
      const estDeliveryMs = Date.now() + (3 + shipDays) * 24 * 60 * 60 * 1000;

      // ── Write the order doc ──────────────────────────────────
      // Defensive normalisation: Firestore set() rejects undefined values,
      // and rejects nested objects with undefined fields (which can happen
      // if shippingAddress.line2 wasn't filled in client-side). Coerce to
      // null so the doc shape stays consistent.
      const safeAddress = {
        name:    shippingAddress.name    ?? "",
        line1:   shippingAddress.line1   ?? "",
        line2:   shippingAddress.line2   ?? "",
        city:    shippingAddress.city    ?? "",
        state:   shippingAddress.state   ?? "",
        zip:     shippingAddress.zip     ?? "",
        country: shippingAddress.country ?? "US",
        formatted: shippingAddress.formatted ?? "",
      };

      // Prefer the path-based shortCode URL form (`/event/{XXXXXX}`)
      // — both the in-app scanner and the public web resolver handle
      // it natively. Fall back to the legacy query-param form for
      // events that haven't been migrated to a shortCode yet so this
      // function never blocks an order.
      const shortCode = (typeof event.shortCode === "string" && event.shortCode.length > 0)
        ? event.shortCode
        : null;
      const eventQrCodeUrl = shortCode
        ? `https://partywithqr.com/event/${shortCode}`
        : `https://partywithqr.com/event?id=${eventId}`;

      const orderRef = db.collection("orders").doc();
      const baseOrder = {
        userId: uid,
        eventId,
        eventName: event.title || "Event",
        eventDate: event.date || null,
        eventQrCode: eventQrCodeUrl,
        // Persist the shortCode separately so the admin / print flows
        // can re-derive the URL without re-fetching the event doc.
        // Null on legacy events.
        eventShortCode: shortCode,
        productType,
        packSize,
        theme: customDesignUrl ? "custom" : theme,
        themeVariant: customDesignUrl ? 0 : themeVariant,
        customDesignUrl: customDesignUrl || null,
        printFileUrl: null, // populated below
        shippingAddress: safeAddress,
        shippingSpeed,
        retailTotalCents: total,
        subtotalCents: subtotal,
        shippingCents: shipping,
        stripeFeeCents: stripeFee,
        yourCostCents: null,
        stripePaymentIntentId: paymentIntentId,
        isTestOrder: isTest,
        status: "pending_fulfillment",
        statusHistory: [{
          status: "pending_fulfillment",
          at: Timestamp.now(),
          byUid: uid,
        }],
        adminNotes: "",
        customerName,
        customerEmail,
        accountTier,
        estimatedDelivery: Timestamp.fromMillis(estDeliveryMs),
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      };
      await orderRef.set(baseOrder);
      log("order doc written", { orderId: orderRef.id });

      // ── Generate placeholder print file (Phase 1) ────────────
      let printFileUrl = null;
      try {
        const result = await generatePrintFile({
          orderId: orderRef.id,
          theme: baseOrder.theme,
          themeVariant: baseOrder.themeVariant,
          productType, packSize,
          eventQrCode: baseOrder.eventQrCode,
          // Pass through the raw shortCode + eventId so the print
          // renderer can rebuild the URL itself if the SVG→PNG swap
          // ever needs to (e.g. for a different deeplink scheme).
          eventShortCode: shortCode,
          eventId,
          eventName: baseOrder.eventName,
          eventDate: baseOrder.eventDate,
          hostName: event.hostName,
          accountTier,
          customDesignUrl,
        });
        printFileUrl = result.url;
        await orderRef.update({
          printFileUrl,
          printFilePlaceholder: result.isPlaceholder === true,
        });
        log("print file generated");
      } catch (err) {
        console.error(`[createMerchOrder ${callId}] generatePrintFile failed:`, err.message, err.stack);
        // Don't fail the order — admin can re-render manually later.
      }

      // ── Notify Chris (admin) via FCM ─────────────────────────
      try {
        const adminQuery = await db.collection("users").where("isAdmin", "==", true).get();
        const tokens = adminQuery.docs
          .map((d) => d.data().fcmToken)
          .filter((t) => typeof t === "string" && t.length > 0);
        if (tokens.length > 0) {
          await getMessaging().sendEachForMulticast({
            tokens,
            notification: {
              title: isTest ? "Test order placed" : "New merch order 📦",
              body: `${packSize} ${productType}${packSize === 1 ? "" : "s"} for ${baseOrder.eventName} · $${(total / 100).toFixed(2)}`,
            },
            data: {
              orderId: orderRef.id,
              type: "admin_new_order",
            },
            // Same channel as the rest of the app's notifications —
            // see lib/main.dart NotificationBridge for registration.
            // Required on Android 8+ or the system tray drops it.
            android: {
              notification: { sound: "default", priority: "high", channel_id: "qrparty_default" },
            },
            apns: { payload: { aps: { sound: "default", badge: 1 } } },
          });
          log("admin FCM sent", { tokenCount: tokens.length });
        }
      } catch (err) {
        console.error(`[createMerchOrder ${callId}] admin FCM failed:`, err.message);
      }

      // ── Notify Chris via email (Trigger Email extension) ─────
      try {
        await db.collection("mail").add({
          to: ["admin@partywithqr.com"],
          message: {
            subject: `${isTest ? "[TEST] " : ""}New merch order: ${baseOrder.eventName} — $${(total / 100).toFixed(2)}`,
            text: [
              `Order ${orderRef.id}`,
              `${packSize} ${productType}${packSize === 1 ? "" : "s"} · theme=${baseOrder.theme}`,
              `Customer: ${customerName} <${customerEmail}>`,
              `Event: ${baseOrder.eventName}`,
              `Total: $${(total / 100).toFixed(2)}`,
              "",
              "Ship to:",
              safeAddress.formatted || JSON.stringify(safeAddress),
              "",
              "Open admin dashboard to fulfill.",
            ].join("\n"),
          },
        });
        log("admin mail queued");
      } catch (err) {
        console.error(`[createMerchOrder ${callId}] admin mail failed:`, err.message);
      }

      log("complete", { orderId: orderRef.id });
      return {
        orderId: orderRef.id,
        status: "pending_fulfillment",
        totalCents: total,
        printFileUrl,
        estimatedDelivery: estDeliveryMs,
        isTest,
      };
    } catch (err) {
      // Re-throw HttpsError untouched so the client sees its proper code.
      // Anything else (Firestore read/write errors, type errors, missing
      // permissions, etc.) becomes opaque "internal" by default — wrap it
      // so the client at least sees the real message instead of "INTERNAL".
      if (err instanceof HttpsError) throw err;
      console.error(`[createMerchOrder ${callId}] UNCAUGHT:`, err.message, err.stack);
      throw new HttpsError(
        "internal",
        `Order failed: ${err && err.message ? err.message : String(err)}`,
        { callId },
      );
    }
  }
);
