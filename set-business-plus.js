// One-time script: set klaus37f@gmail.com to businessPlus.
// Uses Firebase Admin SDK with the service account key in this directory.
// NOTE: actual file on disk is `serviceAccountKey.json.json` (double extension);
// rename it to `serviceAccountKey.json` and update the require below if you fix that.

const admin = require('firebase-admin');
const path = require('path');
const fs = require('fs');

const TARGET_EMAIL = 'klaus37f@gmail.com';
const PROJECT_ID = 'qrparty-6e648';

const candidates = ['serviceAccountKey.json', 'serviceAccountKey.json.json'];
const keyFile = candidates.map(f => path.join(__dirname, f)).find(p => fs.existsSync(p));
if (!keyFile) {
  console.error('Could not find serviceAccountKey.json (or .json.json) in', __dirname);
  process.exit(1);
}
console.log('Using key file:', keyFile);

admin.initializeApp({
  credential: admin.credential.cert(require(keyFile)),
  projectId: PROJECT_ID,
});

(async () => {
  const db = admin.firestore();
  try {
    const snap = await db.collection('users').where('email', '==', TARGET_EMAIL).limit(1).get();
    if (snap.empty) {
      console.error(`No user document found with email=${TARGET_EMAIL}`);
      process.exit(2);
    }
    const doc = snap.docs[0];
    console.log('Found user doc:', doc.id, '— current accountType =', doc.data().accountType, ', isTrialing =', doc.data().isTrialing);

    await doc.ref.update({
      accountType: 'businessPlus',
      isTrialing: false,
    });

    const after = (await doc.ref.get()).data();
    console.log('Updated. New accountType =', after.accountType, ', isTrialing =', after.isTrialing);
    process.exit(0);
  } catch (err) {
    console.error('Error:', err.message);
    process.exit(3);
  }
})();
