// Seed script: creates the permanent demo event in Firestore via REST API
// Run: node seed-demo.js

const https = require('https');

const PROJECT_ID = 'qrparty-6e648';
const API_KEY    = 'AIzaSyDI8j_7H9VoIFMCwGdJzEij406ap_tRlcA';
const BASE       = `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents`;

const thirtyDaysFromNow = new Date();
thirtyDaysFromNow.setDate(thirtyDaysFromNow.getDate() + 30);
thirtyDaysFromNow.setHours(20, 0, 0, 0);

function patch(path, body) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const url  = new URL(`${BASE}/${path}?key=${API_KEY}`);
    const req  = https.request({
      hostname: url.hostname,
      path:     url.pathname + url.search,
      method:   'PATCH',
      headers:  { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) },
    }, res => {
      let buf = '';
      res.on('data', c => buf += c);
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          console.log(`  ✓  /${path}  →  ${res.statusCode}`);
          resolve(JSON.parse(buf));
        } else {
          console.error(`  ✗  /${path}  →  ${res.statusCode}: ${buf}`);
          reject(new Error(`HTTP ${res.statusCode}`));
        }
      });
    });
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

const sv = v  => ({ stringValue:  String(v)  });
const iv = v  => ({ integerValue: String(v)  });
const dv = v  => ({ doubleValue:  v          });
const bv = v  => ({ booleanValue: v          });
const tv = d  => ({ timestampValue: d.toISOString() });
const av = vs => ({ arrayValue:  { values: vs } });
const mv = f  => ({ mapValue:    { fields: f  } });

async function seed() {
  console.log('\n🎉  Seeding demo event (events/demo-event)…\n');

  // ── Main event document ─────────────────────────────────────────────────
  await patch('events/demo-event', {
    fields: {
      title:       sv('QR Party Demo Night 🎉'),
      description: sv('Welcome to QR Party! This is a live demo — explore all the features as a guest.'),
      eventType:   sv('Party'),
      eventEmoji:  sv('🎉'),
      eventColor:  sv('#6A1B9A'),   // Party purple: Color(0xFF6A1B9A)
      date:        tv(thirtyDaysFromNow),
      time:        sv('20:0'),
      location:    sv('123 Party Lane, Seaside CA'),
      hostId:      sv('demo'),
      hostName:    sv('QR Party Team'),
      listType:    sv('Wishlist'),
      yes:         iv(12),
      maybe:       iv(4),
      no:          iv(1),
      isPublic:    bv(true),
      isDraft:     bv(false),
      isDemo:      bv(true),
      createdAt:   tv(new Date()),

      wishlist: av([
        mv({
          name:        sv('Portable Bluetooth Speaker'),
          price:       dv(80),
          contributed: dv(60),
          bought:      bv(false),
        }),
        mv({
          name:        sv('Nice Bottle of Whiskey'),
          price:       dv(50),
          contributed: dv(25),
          bought:      bv(false),
        }),
        mv({
          name:        sv('Party Streamers & Balloons'),
          price:       dv(20),
          contributed: dv(20),
          bought:      bv(true),
        }),
      ]),

      announcements: av([
        mv({
          message:   sv('Welcome to the demo! Look around and explore all the features 🎉'),
          createdAt: tv(new Date()),
        }),
      ]),
    },
  });

  // ── RSVPs subcollection ─────────────────────────────────────────────────
  const rsvps = [
    { id: 'guest-sarah',  name: 'Sarah Chen',     status: 'Yes',   adults: 2, children: 0 },
    { id: 'guest-mike',   name: 'Mike Rodriguez', status: 'Yes',   adults: 1, children: 0 },
    { id: 'guest-lisa',   name: 'Lisa Park',      status: 'Yes',   adults: 2, children: 1 },
    { id: 'guest-james',  name: 'James Wilson',   status: 'Yes',   adults: 1, children: 0 },
    { id: 'guest-emily',  name: 'Emily Torres',   status: 'Maybe', adults: 2, children: 0 },
    { id: 'guest-daniel', name: 'Daniel Kim',     status: 'Maybe', adults: 1, children: 0 },
    { id: 'guest-rachel', name: 'Rachel Green',   status: 'No',    adults: 1, children: 0 },
  ];

  for (const r of rsvps) {
    await patch(`events/demo-event/rsvps/${r.id}`, {
      fields: {
        uid:      sv(r.id),
        name:     sv(r.name),
        status:   sv(r.status),
        adults:   iv(r.adults),
        children: iv(r.children),
      },
    });
  }

  console.log('\n✅  Done!\n');
  console.log('   Firestore document : events/demo-event');
  console.log('   RSVPs written      : ' + rsvps.length);
  console.log('   Event URL          : https://partywithqr.com/event/demo-event\n');
}

seed().catch(err => { console.error('Seed failed:', err.message); process.exit(1); });
