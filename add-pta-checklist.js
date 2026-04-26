// One-time script: add checklist items to events/pgms-pta-demo.
//
// Prerequisites:
//   - npm install firebase-admin
//   - Place serviceAccountKey.json next to this script. Download from
//     Firebase Console → Project settings → Service accounts → Generate new private key.
//     (Already git-ignored — never commit it.)
//
// Run:
//   node add-pta-checklist.js

const admin = require('firebase-admin');
const serviceAccount = require('./serviceAccountKey.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

const db = admin.firestore();

const wishlist = [
  { name: 'Juice Boxes 🧃',             quantity: '2 cases',        claimed: 0 },
  { name: 'Paper Plates & Napkins 🍽️', quantity: '50 sets',        claimed: 0 },
  { name: 'Cookies & Snacks 🍪',        quantity: '2 dozen',        claimed: 0 },
  { name: 'Coffee & Tea ☕',            quantity: '1 thermos each', claimed: 0 },
  { name: 'Printed Agenda 📋',          quantity: '25 copies',      claimed: 0 },
  { name: 'Extra Chairs 🪑',            quantity: '10 chairs',      claimed: 0 },
  { name: 'Name Tags 📛',               quantity: '30 tags',        claimed: 0 },
];

async function main() {
  const ref = db.collection('events').doc('pgms-pta-demo');
  const snap = await ref.get();
  if (!snap.exists) {
    throw new Error('events/pgms-pta-demo does not exist');
  }
  await ref.update({ wishlist, listType: 'Checklist' });
  console.log(`✓ Wrote ${wishlist.length} items to events/pgms-pta-demo.wishlist (listType=Checklist)`);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
