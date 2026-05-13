const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

// Server-side host notification helper. Callable by any authenticated
// user (guests included) so that wishlist/checklist/RSVP actions taken
// from a guest session can still notify the host.
//
// firestore.rules requires the notificationQueue writer to be the
// host/co-host of the named event, so a guest's direct client write
// bounces with permission-denied. This CF uses the Admin SDK to bypass
// the rule. We deliberately do NOT validate the caller against the
// event's hostId/coHosts — the whole point is that a non-host can
// trigger it. We DO require auth (no anonymous spam), validate the
// event exists, and resolve the host fcmToken server-side so the
// client never gets to choose the recipient tokens.
exports.notifyHost = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Must be signed in");
  }

  const { eventId, title, body } = request.data || {};
  if (typeof eventId !== "string" || eventId.length === 0) {
    throw new HttpsError("invalid-argument", "eventId is required");
  }
  if (typeof title !== "string" || title.length === 0) {
    throw new HttpsError("invalid-argument", "title is required");
  }
  if (typeof body !== "string" || body.length === 0) {
    throw new HttpsError("invalid-argument", "body is required");
  }

  const db = getFirestore();

  const eventSnap = await db.collection("events").doc(eventId).get();
  if (!eventSnap.exists) {
    throw new HttpsError("not-found", "Event not found");
  }
  const hostId = eventSnap.data()?.hostId;
  if (typeof hostId !== "string" || hostId.length === 0) {
    return { ok: false, reason: "no-host-id" };
  }

  const hostSnap = await db.collection("users").doc(hostId).get();
  const token = hostSnap.data()?.fcmToken;
  if (typeof token !== "string" || token.length === 0) {
    return { ok: false, reason: "no-host-token" };
  }

  // Shape mirrors NotificationService.sendNotification in lib/utils.dart
  // so processNotificationQueue handles it identically.
  await db.collection("notificationQueue").add({
    tokens: [token],
    title,
    body,
    eventId,
    timestamp: FieldValue.serverTimestamp(),
    status: "pending",
  });

  return { ok: true };
});
