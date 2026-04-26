const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { defineSecret } = require("firebase-functions/params");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");

// Reused so we can fire the Stripe refund when status flips to cancelled.
const stripeSecretKey = defineSecret("STRIPE_SECRET_KEY");

// ── Email templates ─────────────────────────────────────────────
// Each returns { subject, text, html }. Plain text covers email clients
// that strip HTML; HTML covers everyone else.
function tpl({ subject, lead, body, ctaLabel, ctaUrl }) {
  const text = [lead, "", body].filter(Boolean).join("\n\n");
  const html = `
    <div style="font-family:Arial,sans-serif;background:#F8F7FC;padding:32px 16px;color:#2D3047">
      <div style="max-width:520px;margin:0 auto;background:#fff;border-radius:14px;overflow:hidden;box-shadow:0 6px 24px rgba(0,0,0,.08)">
        <div style="background:#2D3047;padding:24px;text-align:center">
          <div style="color:#fff;font:900 22px Arial,sans-serif;letter-spacing:1px">QR<span style="color:#9C7FD4">Party</span></div>
        </div>
        <div style="padding:28px">
          <h1 style="font:700 22px Arial,sans-serif;margin:0 0 12px">${escape(subject)}</h1>
          <p style="margin:0 0 16px;color:#52796F;font-weight:600">${escape(lead)}</p>
          <p style="margin:0 0 22px;line-height:1.6;color:#5b5e75">${escape(body).replace(/\n/g, "<br>")}</p>
          ${ctaUrl ? `<a href="${ctaUrl}" style="display:inline-block;padding:12px 22px;background:#9C7FD4;color:#fff;text-decoration:none;border-radius:10px;font-weight:800">${escape(ctaLabel || "View order")}</a>` : ""}
        </div>
        <div style="padding:18px;text-align:center;color:#8892A4;font-size:12px">
          QR Party · partywithqr.com
        </div>
      </div>
    </div>
  `;
  return { subject, text, html };
}
function escape(s) {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

function templateFor(status, order, statusNote) {
  const product = `${order.packSize} ${order.productType}${order.packSize === 1 ? "" : "s"}`;
  const event = order.eventName || "your event";
  switch (status) {
    case "pending_fulfillment":
      return tpl({
        subject: `Order received — ${product}`,
        lead: "Thanks! Your order is in.",
        body: `We're preparing your ${product} for ${event}. You'll get another email when it's at the printer.`,
      });
    case "sent_to_printer":
      return tpl({
        subject: `Your ${product} is at the printer`,
        lead: "Now printing!",
        body: `Your order for ${event} just went to the printer. Expect another email when it ships.`,
      });
    case "shipped": {
      const trackingLine = order.trackingNumber
        ? `${order.trackingCarrier || "Tracking"}: ${order.trackingNumber}`
        : "Tracking will appear here once the carrier scans the package.";
      const url = trackingUrl(order);
      return tpl({
        subject: `Your ${product} shipped 📬`,
        lead: "It's on the way!",
        body: `${trackingLine}\nEvent: ${event}`,
        ctaLabel: "Track package",
        ctaUrl: url,
      });
    }
    case "delivered":
      return tpl({
        subject: `Your ${product} arrived!`,
        lead: "Hope they look great.",
        body: `Tag us @PartyWithQR if you share photos — we love seeing them in the wild.`,
      });
    case "cancelled":
      return tpl({
        subject: `Order cancelled — refund issued`,
        lead: "Your order was cancelled.",
        body: `${statusNote || "Your order has been cancelled and refunded."} If you have questions, reply to this email.`,
      });
    default:
      return null;
  }
}

function trackingUrl(order) {
  const n = order.trackingNumber;
  if (!n) return null;
  const c = (order.trackingCarrier || "").toLowerCase();
  if (c.includes("usps"))  return `https://tools.usps.com/go/TrackConfirmAction?tLabels=${n}`;
  if (c.includes("ups"))   return `https://www.ups.com/track?tracknum=${n}`;
  if (c.includes("fedex")) return `https://www.fedex.com/fedextrack/?trknbr=${n}`;
  return `https://www.google.com/search?q=track+package+${encodeURIComponent(n)}`;
}

async function maybeRefund(order, db) {
  if (order.isTestOrder) {
    console.log(`[sendOrderStatusEmail] TEST order ${order._id} — skipping Stripe refund`);
    return;
  }
  if (!order.stripePaymentIntentId) {
    console.warn(`[sendOrderStatusEmail] order ${order._id} cancelled with no PI to refund`);
    return;
  }
  if (order.refundedAt) return; // already refunded
  try {
    const Stripe = require("stripe");
    const stripe = Stripe(stripeSecretKey.value());
    const refund = await stripe.refunds.create({ payment_intent: order.stripePaymentIntentId });
    await db.collection("orders").doc(order._id).update({
      refundedAt: FieldValue.serverTimestamp(),
      stripeRefundId: refund.id,
    });
    console.log(`[sendOrderStatusEmail] refunded ${order.stripePaymentIntentId} → ${refund.id}`);
  } catch (err) {
    console.error(`[sendOrderStatusEmail] refund failed for ${order._id}:`, err.message);
  }
}

// ── Trigger ─────────────────────────────────────────────────────
exports.sendOrderStatusEmail = onDocumentWritten(
  { document: "orders/{orderId}", secrets: [stripeSecretKey] },
  async (event) => {
    const before = event.data?.before?.exists ? event.data.before.data() : null;
    const after  = event.data?.after?.exists  ? event.data.after.data()  : null;
    if (!after) return; // deletion — nothing to email

    const fromStatus = before?.status;
    const toStatus   = after.status;

    // Fire on first creation (no before) AND on actual status transitions.
    const isCreation = before === null;
    const statusChanged = fromStatus !== toStatus;
    if (!isCreation && !statusChanged) return;

    const orderId = event.params.orderId;
    const order = { _id: orderId, ...after };

    const lastNote = (after.statusHistory && after.statusHistory.length > 0)
      ? after.statusHistory[after.statusHistory.length - 1].note
      : null;

    const template = templateFor(toStatus, order, lastNote);
    if (!template) return;

    const db = getFirestore();

    // ── Cancellation: fire refund first so the email accurately says
    //     refund was issued (refund happens fast in test/sandbox).
    if (toStatus === "cancelled" && fromStatus !== "cancelled") {
      await maybeRefund(order, db);
    }

    const to = order.customerEmail;
    if (!to) {
      console.warn(`[sendOrderStatusEmail] order ${orderId} has no customerEmail; skipping`);
    } else {
      await db.collection("mail").add({
        to: [to],
        replyTo: "admin@partywithqr.com",
        message: template,
      });
      console.log(`[sendOrderStatusEmail] queued ${toStatus} email to ${to} for ${orderId}`);
    }

    // Push notification to the customer (best-effort).
    try {
      const userSnap = await db.collection("users").doc(order.userId).get();
      const fcm = userSnap.data()?.fcmToken;
      if (fcm) {
        await getMessaging().send({
          token: fcm,
          notification: {
            title: template.subject,
            body: template.text.split("\n").find((l) => l.trim().length) || "",
          },
          data: { orderId, type: "order_status", status: toStatus },
        });
      }
    } catch (err) {
      console.error("[sendOrderStatusEmail] customer FCM failed:", err.message);
    }
  }
);
