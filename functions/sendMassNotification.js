const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { getFirestore, FieldPath } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");

// ── MASS NOTIFICATION ────────────────────────────────────────────
// Fans a single push notification out to every guest who has RSVPed
// to ANY event the caller hosts. Driven by the Contacts tab on the
// Business / Headquarters home feed (see business_home_feed_screen.dart
// → _showNotifySheet).
//
// Pipeline:
//   1. Auth check + payload validation (title ≤ 60, body ≤ 160).
//   2. Defense-in-depth: hostUid in the payload MUST equal the
//      caller's uid. Without this, anyone authenticated could blast
//      under another host's roster.
//   3. Read every event the caller hosts.
//   4. Walk each event's `rsvps` subcollection and accumulate the
//      app-side `uid` field. Web RSVPs (auto-id docs without a uid
//      field) have no FCM token — they're skipped here.
//   5. Look up `users/{uid}` in 30-id whereIn chunks (Firestore cap),
//      pull `fcmToken`, drop nulls/empties.
//   6. Send via `sendEachForMulticast` in 500-token chunks (FCM cap),
//      tally success / failure.
//
// Returns `{ success, sent, skipped }`. `sent` = successful FCM
// deliveries; `skipped` = guests reached at the rsvps layer but
// dropped along the way (no user doc, no fcmToken, FCM-side failure).
exports.sendMassNotification = onCall(async (request) => {
  const callId = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
  const log = (msg, extra) =>
    console.log(`[sendMassNotification ${callId}] ${msg}`, extra || "");

  const uid = request.auth?.uid;
  log("invoke", { uid, hasData: !!request.data });
  if (!uid) throw new HttpsError("unauthenticated", "Sign in required");

  try {
    const { title, body, hostUid } = request.data || {};

    // ── Validate payload ─────────────────────────────────────────
    if (typeof title !== "string" || title.trim().length === 0) {
      throw new HttpsError("invalid-argument", "title is required");
    }
    if (title.length > 60) {
      throw new HttpsError("invalid-argument", "title must be 60 characters or fewer");
    }
    if (typeof body !== "string" || body.trim().length === 0) {
      throw new HttpsError("invalid-argument", "body is required");
    }
    if (body.length > 160) {
      throw new HttpsError("invalid-argument", "body must be 160 characters or fewer");
    }
    if (typeof hostUid !== "string" || hostUid.length === 0) {
      throw new HttpsError("invalid-argument", "hostUid is required");
    }
    // Lock the caller to their own roster — see header comment.
    if (hostUid !== uid) {
      throw new HttpsError("permission-denied",
        "hostUid must match the caller's uid");
    }
    log("validated", { titleLen: title.length, bodyLen: body.length });

    const db = getFirestore();

    // ── Step 1: every event the caller hosts ─────────────────────
    const eventsSnap = await db.collection("events")
      .where("hostId", "==", hostUid)
      .get();
    log("events fetched", { count: eventsSnap.size });
    if (eventsSnap.empty) {
      return { success: true, sent: 0, skipped: 0 };
    }

    // ── Step 2: collect unique app-side rsvp uids ────────────────
    // We pull ALL statuses, not just Yes/Maybe — the Contacts tab is
    // every-RSVP-ever, so the mass blast follows the same surface.
    // Web RSVPs without a `uid` field are skipped (no token to push).
    const uniqueUids = new Set();
    let webSkipped = 0;
    for (const eventDoc of eventsSnap.docs) {
      const rsvpSnap = await eventDoc.ref.collection("rsvps").get();
      for (const r of rsvpSnap.docs) {
        const u = r.data().uid;
        if (typeof u === "string" && u.length > 0) {
          uniqueUids.add(u);
        } else {
          webSkipped++;
        }
      }
    }
    log("rsvp scan", { uniqueUids: uniqueUids.size, webSkipped });
    if (uniqueUids.size === 0) {
      return { success: true, sent: 0, skipped: webSkipped };
    }

    // ── Step 3: chunked user-doc lookup (in-query cap = 30) ──────
    const uidsArray = Array.from(uniqueUids);
    const tokens = [];
    let userSkipped = 0;
    for (let i = 0; i < uidsArray.length; i += 30) {
      const chunk = uidsArray.slice(i, i + 30);
      const userSnap = await db.collection("users")
        .where(FieldPath.documentId(), "in", chunk)
        .get();
      const seenUids = new Set();
      for (const u of userSnap.docs) {
        seenUids.add(u.id);
        const t = u.data().fcmToken;
        if (typeof t === "string" && t.length > 0) {
          tokens.push(t);
        } else {
          userSkipped++;
        }
      }
      // Uids in the chunk that didn't return a doc — count as skipped.
      for (const wantedUid of chunk) {
        if (!seenUids.has(wantedUid)) userSkipped++;
      }
    }
    log("token resolution", { tokens: tokens.length, userSkipped });
    if (tokens.length === 0) {
      return { success: true, sent: 0, skipped: webSkipped + userSkipped };
    }

    // ── Step 4: chunked FCM send (multicast cap = 500) ───────────
    const messaging = getMessaging();
    let sent = 0;
    let fcmSkipped = 0;
    for (let i = 0; i < tokens.length; i += 500) {
      const chunk = tokens.slice(i, i + 500);
      const response = await messaging.sendEachForMulticast({
        tokens: chunk,
        notification: { title: title.trim(), body: body.trim() },
        // Tag so the in-app notification handler can route differently
        // from event-specific pushes if it ever needs to.
        data: { type: "mass_notification" },
        android: {
          notification: {
            sound: "default",
            priority: "high",
            // Must match the channel created in lib/main.dart's
            // NotificationBridge — Android 8+ drops notifications
            // sent without a registered channel.
            channel_id: "qrparty_default",
          },
        },
        apns: { payload: { aps: { sound: "default", badge: 1 } } },
      });
      sent += response.successCount;
      fcmSkipped += response.failureCount;
    }
    const skipped = webSkipped + userSkipped + fcmSkipped;
    log("complete", { sent, skipped });
    return { success: true, sent, skipped };
  } catch (err) {
    if (err instanceof HttpsError) throw err;
    console.error(`[sendMassNotification ${callId}] UNCAUGHT:`,
      err && err.message, err && err.stack);
    throw new HttpsError("internal",
      `Send failed: ${err && err.message ? err.message : String(err)}`);
  }
});
