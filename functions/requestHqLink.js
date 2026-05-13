const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

// ── HQ LINK REQUEST (reverse flow) ──────────────────────────────
// Reverse direction of the HQ→Business invite (acceptOrgInvite handles
// the forward flow). A Business owner asks to link UP to a Headquarters
// by entering the HQ admin's email; this CF runs the same shape of
// validation _sendInvite uses on the HQ side, with the roles swapped,
// then writes the pending invite doc with `requestedByUid` set so the
// HQ-side banner (future turn) can distinguish "request" from "invite".
//
// Why a CF instead of a direct Firestore write: firestore.rules
// requires the HQ owner to sign invite-create writes (rules:307-310).
// A Business owner writing the same path gets permission-denied. Admin
// SDK bypasses — same pattern acceptOrgInvite.js uses.
//
// Writes (single set on success):
//   /organizations/{businessOrgId}/invites/{hqOrgId} {
//     hqOrgId, hqOwnerUid, hqOrgName,
//     status:         'pending',
//     sentAt:         serverTimestamp,
//     sentByUid:      callerUid,        // the Business owner here
//     requestedByUid: callerUid,        // discriminator — absent on HQ-initiated invites
//   }
//
// Invariants enforced:
//   • Caller signed in
//   • Caller owns a Business org with accountType == 'business'
//   • Caller's email != hqOrgEmail (no self-link)
//   • Business not already linked elsewhere (parentOrgId null/empty)
//   • Target user exists, accountType == 'businessPlus'
//   • Target HQ org exists
//   • Business not already in HQ.linkedBusinessOrgIds
//
// Idempotent on re-send: doc id is hqOrgId, so a duplicate request
// from the same Business to the same HQ refreshes sentAt without
// creating a second pending invite.
exports.requestHqLink = onCall(async (request) => {
  const callId = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
  const log = (msg, extra) =>
    console.log(`[requestHqLink ${callId}] ${msg}`, extra || "");

  const uid = request.auth?.uid;
  log("invoke", { uid, hasData: !!request.data });
  if (!uid) throw new HttpsError("unauthenticated", "Sign in required");

  try {
    const { hqOrgEmail } = request.data || {};
    if (typeof hqOrgEmail !== "string") {
      throw new HttpsError("invalid-argument", "hqOrgEmail is required");
    }
    const email = hqOrgEmail.trim().toLowerCase();
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!email || !emailRegex.test(email)) {
      throw new HttpsError("invalid-argument", "Enter a valid email address");
    }

    const db = getFirestore();

    // ── Caller user doc — confirms tier + grabs caller's email
    //    for the self-link check.
    const callerSnap = await db.collection("users").doc(uid).get();
    if (!callerSnap.exists) {
      throw new HttpsError("failed-precondition",
        "Your account is incomplete — sign in again");
    }
    const callerData = callerSnap.data();
    const callerEmail = (callerData.email || "").trim().toLowerCase();
    const callerAcct  = callerData.accountType;

    if (callerAcct !== "business") {
      throw new HttpsError("failed-precondition",
        "Only Business accounts can request a Headquarters link");
    }
    if (callerEmail === email) {
      throw new HttpsError("invalid-argument",
        "That's your own email — you can't link to yourself");
    }

    // ── Caller's Business org ──
    const businessOrgQuery = await db.collection("organizations")
      .where("ownerId", "==", uid)
      .limit(1)
      .get();
    if (businessOrgQuery.empty) {
      throw new HttpsError("failed-precondition",
        "Set up your Business organization first");
    }
    const businessOrgDoc = businessOrgQuery.docs[0];
    const businessOrgId  = businessOrgDoc.id;
    const businessOrgData = businessOrgDoc.data();

    const existingParent = businessOrgData.parentOrgId;
    if (typeof existingParent === "string" && existingParent.length > 0) {
      throw new HttpsError("failed-precondition",
        "Your Business is already linked to a Headquarters — unlink first");
    }
    log("caller resolved", { businessOrgId });

    // ── Target HQ user lookup by email ──
    const hqUserQuery = await db.collection("users")
      .where("email", "==", email)
      .limit(1)
      .get();
    if (hqUserQuery.empty) {
      throw new HttpsError("not-found",
        "No account found for this email");
    }
    const hqUserDoc = hqUserQuery.docs[0];
    const hqOwnerUid = hqUserDoc.id;
    const hqAcct     = hqUserDoc.data().accountType;
    if (hqAcct !== "businessPlus") {
      throw new HttpsError("failed-precondition",
        "That account is not on the Headquarters tier");
    }

    // ── HQ org doc ──
    const hqOrgQuery = await db.collection("organizations")
      .where("ownerId", "==", hqOwnerUid)
      .limit(1)
      .get();
    if (hqOrgQuery.empty) {
      throw new HttpsError("failed-precondition",
        "That Headquarters hasn't set up their organization yet");
    }
    const hqOrgDoc = hqOrgQuery.docs[0];
    const hqOrgId  = hqOrgDoc.id;
    const hqOrgData = hqOrgDoc.data();
    const hqOrgName = (typeof hqOrgData.name === "string" && hqOrgData.name.trim().length > 0)
      ? hqOrgData.name.trim()
      : "Headquarters";

    // Already in HQ's linked array → reject as an idempotent friendly
    // failure (the link already exists, just hadn't propagated to
    // parentOrgId yet OR was set via a prior accept).
    const linkedOrgIds = Array.isArray(hqOrgData.linkedBusinessOrgIds)
      ? hqOrgData.linkedBusinessOrgIds
      : [];
    if (linkedOrgIds.includes(businessOrgId)) {
      throw new HttpsError("failed-precondition",
        "Your Business is already linked to this Headquarters");
    }
    log("HQ resolved", { hqOrgId, hqOrgName });

    // ── Write the pending invite ──
    await db.collection("organizations").doc(businessOrgId)
      .collection("invites").doc(hqOrgId)
      .set({
        hqOrgId,
        hqOwnerUid,
        hqOrgName,
        status:         "pending",
        sentAt:         FieldValue.serverTimestamp(),
        sentByUid:      uid,
        // requestedByUid distinguishes reverse-flow (Business asked) from
        // forward-flow (HQ invited). Forward-flow invites omit this
        // field; the future HQ-side incoming-request banner will key on
        // its presence to render the right action chrome.
        requestedByUid: uid,
      });
    log("invite written", { businessOrgId, hqOrgId });

    return { success: true, hqOrgName };
  } catch (err) {
    if (err instanceof HttpsError) throw err;
    console.error(`[requestHqLink ${callId}] UNCAUGHT:`,
      err && err.message, err && err.stack);
    throw new HttpsError("internal",
      `Request failed: ${err && err.message ? err.message : String(err)}`);
  }
});
