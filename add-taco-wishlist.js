// One-time script: add Taco Tuesday wishlist items to events/demo-event.
//
// Prerequisites:
//   - npm install firebase-admin
//   - Place serviceAccountKey.json next to this script. Download from
//     Firebase Console → Project settings → Service accounts → Generate new private key.
//     (Already git-ignored — never commit it.)
//
// Run:
//   node add-taco-wishlist.js

const admin = require('firebase-admin');
const serviceAccount = require('./serviceAccountKey.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

const db = admin.firestore();

const wishlist = [
  { name: 'Hot Sauce 🌶️',       price: 5,  contributed: 3, bought: false },
  { name: 'Limes 🍋',            price: 3,  contributed: 3, bought: true  },
  { name: 'Drinks 🥤',           price: 15, contributed: 8, bought: false },
  { name: 'Extra Tortillas 🫓',  price: 4,  contributed: 0, bought: false },
  { name: 'Guacamole 🥑',        price: 8,  contributed: 5, bought: false },
];

async function main() {
  const ref = db.collection('events').doc('demo-event');
  const snap = await ref.get();
  if (!snap.exists) {
    throw new Error('events/demo-event does not exist');
  }
  await ref.update({ wishlist, listType: 'Wishlist' });
  console.log(`✓ Wrote ${wishlist.length} items to events/demo-event.wishlist (listType=Wishlist)`);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
