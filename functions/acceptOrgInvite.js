const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

// ── ORG LINK INVITE ACCEPT ──────────────────────────────────────
// Atomic 3-doc transaction triggered by a Business owner accepting
// an invite from a Headquarters (businessPlus) account. Lives in a
// Cloud Function because firestore.rules can't safely express
// "Business owner writes to HQ org doc's `linkedBusiness*` arrays"
// without complex permissive logic — the CF uses Admin SDK to bypass
// rules and write all three docs atomically.
//
// Writes (single transaction):
//   1. /organizations/{businessOrgId}/invites/{hqOrgId}
//        status: 'accepted', respondedAt: now
//   2. /organizations/{businessOrgId}
//        parentOrgId: hqOrgId, linkedAt: now
//   3. /organizations/{hqOrgId}
//        linkedBusinessOrgIds:    arrayUnion(businessOrgId)
//        linkedBusinessOwnerUids: arrayUnion(callerUid)
//
// Invariants enforced (all from Phase 1 spec):
//   • Caller signed in
//   • Caller owns a Business-tier org (accountType == 'business')
//   • HQ owner is on businessPlus tier
//   • Invite exists and is currently 'pending'
//   • Business not already linked (parentOrgId is null)
//   • Caller is not the HQ owner (no self-link)
//   • HQ.linkedBusinessOwnerUids.length < 29 (events whereIn cap is
//     30 including HQ owner's own uid in slot 30)
//
// Idempotency: if `parentOrgId` is already set to this `hqOrgId` and
// caller's uid is already in HQ's array, treat the accept as a no-op
// success — the transaction still flips invite status to 'accepted'
// but skips the array-union write. Prevents double-link if the user
// double-taps Accept while the round-trip is in flight.
exports.acceptOrgInvite = onCall(async (request) => {
  const callId = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
  const log = (msg, extra) => console.log(`[acceptOrgInvite ${callId}] ${msg}`, extra || "");

  const uid = request.auth?.uid;
  log("invoke", { uid, hasData: !!request.data });

  if (!uid) throw new HttpsError("unauthenticated", "Sign in required");

  const { hqOrgId } = request.data || {};
  if (!hqOrgId || typeof hqOrgId !== "string") {
    throw new HttpsError("invalid-argument", "hqOrgId is required");
  }

  const db = getFirestore();

  // Resolve the caller's Business org outside the transaction —
  // collection queries can't be added to a transaction's read set in
  // the same way doc gets can. We re-fetch the doc by id inside the
  // transaction for proper isolation; this query just gives us the
  // doc id to fetch.
  const businessOrgQuery = await db.collection("organizations")
    .where("ownerId", "==", uid)
    .limit(1)
    .get();
  if (businessOrgQuery.empty) {
    throw new HttpsError("failed-precondition", "You don't own a Business organization");
  }
  const businessOrgId = businessOrgQuery.docs[0].id;
  log("resolved businessOrgId", { businessOrgId });

  if (businessOrgId === hqOrgId) {
    throw new HttpsError("invalid-argument", "Cannot link an organization to itself");
  }

  const inviteRef     = db.collection("organizations").doc(businessOrgId).collection("invites").doc(hqOrgId);
  const businessOrgRef = db.collection("organizations").doc(businessOrgId);
  const hqOrgRef       = db.collection("organizations").doc(hqOrgId);

  try {
    const result = await db.runTransaction(async (tx) => {
      // ── Reads (all before any writes per Firestore tx rules) ────
      const inviteSnap      = await tx.get(inviteRef);
      const businessOrgSnap = await tx.get(businessOrgRef);
      const hqOrgSnap       = await tx.get(hqOrgRef);

      if (!inviteSnap.exists) {
        throw new HttpsError("not-found", "Invite not found — it may have been revoked");
      }
      if (!businessOrgSnap.exists) {
        throw new HttpsError("not-found", "Your Business organization no longer exists");
      }
      if (!hqOrgSnap.exists) {
        throw new HttpsError("not-found", "The Headquarters organization no longer exists");
      }

      const invite      = inviteSnap.data();
      const businessOrg = businessOrgSnap.data();
      const hqOrg       = hqOrgSnap.data();

      if (invite.status !== "pending") {
        throw new HttpsError("failed-precondition",
          `Invite is already ${invite.status} — accept aborted`);
      }

      // Caller-owns-business re-check inside tx (defends against the
      // outer query lookup being stale by transaction-time).
      if (businessOrg.ownerId !== uid) {
        throw new HttpsError("permission-denied", "You don't own the Business organization");
      }

      // No self-link via owner identity.
      if (hqOrg.ownerId === uid) {
        throw new HttpsError("invalid-argument", "Cannot link to your own organization");
      }

      // Idempotency check: detect a fully-completed prior accept.
      const currentUids = Array.isArray(hqOrg.linkedBusinessOwnerUids)
        ? hqOrg.linkedBusinessOwnerUids : [];
      const currentOrgIds = Array.isArray(hqOrg.linkedBusinessOrgIds)
        ? hqOrg.linkedBusinessOrgIds : [];
      const alreadyLinkedSameHq = businessOrg.parentOrgId === hqOrgId
        && currentUids.includes(uid)
        && currentOrgIds.includes(businessOrgId);

      // Already linked to a DIFFERENT HQ → reject. The Business must
      // unlink first via a future unlink flow before linking elsewhere.
      if (businessOrg.parentOrgId && businessOrg.parentOrgId !== hqOrgId) {
        throw new HttpsError("failed-precondition",
          "Your Business is already linked to another Headquarters — unlink first");
      }

      // Account type validation via user docs (read inside tx for
      // consistency — accountType rarely changes but a concurrent
      // subscription event could flip it mid-accept).
      const businessUserSnap = await tx.get(db.collection("users").doc(uid));
      const hqUserSnap       = await tx.get(db.collection("users").doc(hqOrg.ownerId));

      const businessAcct = businessUserSnap.exists ? businessUserSnap.data().accountType : null;
      const hqAcct       = hqUserSnap.exists       ? hqUserSnap.data().accountType       : null;

      if (businessAcct !== "business") {
        throw new HttpsError("failed-precondition",
          `Your account must be on the Business tier (currently ${businessAcct || "unknown"})`);
      }
      if (hqAcct !== "businessPlus") {
        throw new HttpsError("failed-precondition",
          "The inviting account is no longer on the Headquarters tier");
      }

      // Cap: events whereIn supports 30 values; HQ uses one slot for
      // its own uid, leaving 29 for linked Businesses.
      if (!alreadyLinkedSameHq && currentUids.length >= 29) {
        throw new HttpsError("resource-exhausted",
          "Headquarters has reached the maximum number of linked Business locations (29)");
      }

      // ── Writes ──────────────────────────────────────────────────
      tx.update(inviteRef, {
        status: "accepted",
        respondedAt: FieldValue.serverTimestamp(),
      });
      tx.update(businessOrgRef, {
        parentOrgId: hqOrgId,
        linkedAt: FieldValue.serverTimestamp(),
      });
      if (!alreadyLinkedSameHq) {
        tx.update(hqOrgRef, {
          linkedBusinessOrgIds:    FieldValue.arrayUnion(businessOrgId),
          linkedBusinessOwnerUids: FieldValue.arrayUnion(uid),
        });
      }

      return {
        businessOrgId,
        hqOrgId,
        hqOrgName: hqOrg.name || "Headquarters",
        alreadyLinkedSameHq,
      };
    });

    log("complete", result);
    return { success: true, ...result };
  } catch (err) {
    if (err instanceof HttpsError) throw err;
    console.error(`[acceptOrgInvite ${callId}] UNCAUGHT:`, err.message, err.stack);
    throw new HttpsError("internal", `Accept failed: ${err && err.message ? err.message : String(err)}`);
  }
});
