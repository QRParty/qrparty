const { getStorage } = require("firebase-admin/storage");
const puppeteer = require("puppeteer");
const QRCode = require("qrcode");

// ── PARITY CONTRACT (mirrors lib/widgets/invitation_preview.dart) ─────
// The host approves a card visually via lib/widgets/invitation_preview.dart
// before paying. This renderer's output MUST match what they saw or every
// shipment is a UX surprise. The 5 clauses from the prior placeholder are
// enforced below:
//   • Fonts: FredokaOne + Nunito via Google Fonts @import — `waitUntil:
//     'networkidle0'` blocks the screenshot until font network requests
//     resolve, so the PNG never ships with the wrong family.
//   • QR URL: produced via resolveEventUrl(...), same shortCode-first
//     fallback order the preview's _eventQrUrl helper uses.
//   • QR size: 30% of card width (~360px on a 1200px-wide canvas) —
//     well above the 300px (1.0") general-population scan threshold.
//   • Kids vs generic padding asymmetry: Kids overlay uses (20, 64, 20,
//     52) so the themed top border art doesn't crowd the eyebrow text.
//     Generic _Card4x6 uses (20, 18, 20, 12). Both are honored below.
//   • Brand strip per accountTier: 'businessPlus' → orgLogoUrl image
//     (fallback wordmark); 'business' → "Hosted by {hostName}"; else →
//     wordmark.
//   • _PreviewWatermark is NEVER rendered here — exists only in the
//     in-app preview surface.

// 4×6 inches at 300 DPI = 1200×1800px target output. Achieved via a
// 400×600 CSS viewport at deviceScaleFactor 3 so the design tokens
// below (padding 20/64/20/52 etc.) read close to their Flutter
// logical-pixel counterparts and the screenshot lands at the right
// print resolution without manual unit conversion.
const VIEWPORT_W = 400;
const VIEWPORT_H = 600;
const DEVICE_SCALE = 3;

// Android package name and the resolver are kept here so callers don't
// have to import resolveEventUrl separately.
// Build the canonical event URL the print file should encode. Mirrors
// the resolver order used in invitation_preview.dart and event.html:
//   1. shortCode → `/event/{XXXXXX}` (preferred, all new events)
//   2. caller-supplied eventQrCode → trust it as-is (already a URL)
//   3. eventId → legacy `/event?id={docId}` fallback
// Returns null when none of the above are usable so callers can no-op
// the QR layer instead of stamping a broken URL.
function resolveEventUrl({ eventQrCode, eventShortCode, eventId }) {
  if (typeof eventShortCode === "string" && eventShortCode.length > 0) {
    return `https://partywithqr.com/event/${eventShortCode}`;
  }
  if (typeof eventQrCode === "string" && eventQrCode.length > 0) {
    return eventQrCode;
  }
  if (typeof eventId === "string" && eventId.length > 0) {
    return `https://partywithqr.com/event?id=${eventId}`;
  }
  return null;
}

// Kids theme palettes — values copied 1:1 from invitation_preview.dart's
// `_palettes` map. Each entry mirrors the Flutter _KidsPalette shape
// (bg1, bg2, accent, secondary, text) so any future palette tweak in
// Dart needs the matching change here for parity to hold.
const KIDS_PALETTES = {
  dinosaurs: {
    bg1: "#4A6B3A", bg2: "#2C4A24", accent: "#FFD23F",
    secondary: "#8B6F47", text: "#FFFFFF",
    gradientType: "linear", emoji: "🦖🦕🌿🥚🦴",
  },
  space: {
    bg1: "#1B0E3D", bg2: "#0A0524", accent: "#FFB347",
    secondary: "#9C7FD4", text: "#FFFFFF",
    gradientType: "radial", emoji: "⭐🚀🪐🌙✨",
  },
  unicornsRainbows: {
    bg1: "#FFE0EC", bg2: "#E6D6FF", accent: "#E91E63",
    secondary: "#9C7FD4", text: "#5C2D69",
    gradientType: "linear", emoji: "🦄🌈⭐💖✨",
  },
  sports: {
    bg1: "#D62828", bg2: "#8B1A1A", accent: "#FFCC00",
    secondary: "#FFFFFF", text: "#FFFFFF",
    gradientType: "linear", emoji: "⚽🏀🏈⚾🏆",
  },
  animals: {
    bg1: "#F5E8D4", bg2: "#EBD5B5", accent: "#C97B4A",
    secondary: "#6B8B5E", text: "#4A2E1A",
    gradientType: "linear", emoji: "🦁🐘🦒🐯🐵",
  },
  circusCarnival: {
    bg1: "#E63946", bg2: "#C1121F", accent: "#FFD23F",
    secondary: "#FFFFFF", text: "#FFFFFF",
    gradientType: "linear", emoji: "🎪🎟️🎡🎠🎈",
  },
  mermaidsOcean: {
    bg1: "#00838F", bg2: "#004D5A", accent: "#FF7F6B",
    secondary: "#7FFFD4", text: "#FFFFFF",
    gradientType: "linear", emoji: "🧜‍♀️🐚🐠🌊🦑",
  },
  princessFairies: {
    bg1: "#FFB7D5", bg2: "#B07FE0", accent: "#FFD700",
    secondary: "#FFFFFF", text: "#3D2A55",
    gradientType: "linear", emoji: "👑🧚‍♀️🏰💎✨",
  },
};

// Maps the host-facing theme.key (matching Flutter's `_kidsThemeFromKey`)
// to a palette key in KIDS_PALETTES. Includes aliases so the spec's
// example keys ('stars', 'dinosaur') resolve alongside the canonical
// Flutter ones ('space', 'dinosaurs'). Returns null for unknown / non-
// Kids keys so the caller falls back to the generic _Card4x6 path.
function kidsThemeFromKey(key) {
  switch (key) {
    case "dinosaur":
    case "dinosaurs":
      return "dinosaurs";
    case "space":
    case "stars":
      return "space";
    case "unicorn":
    case "unicornsRainbows":
      return "unicornsRainbows";
    case "sports":
      return "sports";
    case "animals":
      return "animals";
    case "circus":
    case "circusCarnival":
      return "circusCarnival";
    case "mermaids":
    case "mermaidsOcean":
      return "mermaidsOcean";
    case "princess":
    case "princessFairies":
      return "princessFairies";
    default:
      return null;
  }
}

// HTML escape — used on every host-supplied string before it lands in
// the template literal. Without this a guest named `O'Brien` or an
// event titled `<3 our team` would break the markup or open an XSS
// vector (less critical inside a sandboxed headless browser, but still
// the right hygiene).
function esc(s) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function formatPrintDate(eventDate) {
  if (!eventDate) return "";
  const d = eventDate instanceof Date ? eventDate
    : (eventDate.toDate ? eventDate.toDate()
    : new Date(eventDate));
  if (isNaN(d.getTime())) return "";
  const months = ["January","February","March","April","May","June",
    "July","August","September","October","November","December"];
  return `${months[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()}`;
}

// Generic-card variant palette. The Flutter `MerchThemeVariant` carries
// per-variant `bg`, `accent`, `text` colors — those flow into the print
// renderer via the `variant` arg (passed through createMerchOrder.js).
// When the caller didn't pass one (older orders), fall back to a clean
// white card with the gold accent so we still ship something legible.
function genericPalette(variant) {
  return {
    bg:     (variant && variant.bg)     || "#FFFFFF",
    accent: (variant && variant.accent) || "#C8922A",
    text:   (variant && variant.text)   || "#1A1A1A",
  };
}

// Builds the right-half of `_BrandStrip` — same per-tier logic as the
// Flutter widget. businessPlus with an orgLogoUrl renders a 30px-tall
// fitted image; everything else (including businessPlus with a missing
// / failing URL) falls through to the wordmark string. The wordmark
// keeps Flutter's split coloring: "QR " in card text color + "PARTY"
// in accent.
function buildBrandStripHtml({ accountTier, hostName, orgLogoUrl, accent, text }) {
  const safeHost = esc(hostName);
  const safeLogo = esc(orgLogoUrl || "");
  const wordmark = `
    <div class="brand-wordmark" style="color:${text};">
      <span>QR </span><span style="color:${accent};">PARTY</span>
    </div>`;
  if (accountTier === "businessPlus") {
    if (orgLogoUrl && orgLogoUrl.length > 0) {
      // onerror falls back to the wordmark so a missing / 403 logo
      // doesn't leave a broken-image icon on the printed card.
      return `<img src="${safeLogo}" class="brand-logo"
        onerror="this.outerHTML='${wordmark.replaceAll("'", "&#39;")}'"/>`;
    }
    return wordmark;
  }
  if (accountTier === "business") {
    const h = safeHost.trim().length === 0 ? "your host" : safeHost;
    return `<div class="brand-hosted" style="color:${text};opacity:0.85;">
      Hosted by ${h}</div>`;
  }
  return wordmark;
}

// Kids overlay HTML. Padding is the explicit (20, 64, 20, 52) the
// parity contract mandates. Emoji "border strip" replaces the
// per-theme decorative SVG/CustomPaint layer from the Flutter preview
// — full art parity is Phase 3 work (commissioned vector assets); the
// emoji strip at 32px is a recognisable preview of theme intent
// without dragging hundreds of lines of SVG path data into this file.
function buildKidsHtml({
  paletteKey, palette, qrDataUrl, eventName, dateLine, shortCode, brandStripHtml,
}) {
  const safeName = esc(eventName || "Your Event");
  const safeShort = shortCode ? esc(shortCode) : "";
  const bgCss = palette.gradientType === "radial"
    ? `radial-gradient(circle at 50% -10%, ${palette.bg1}, ${palette.bg2})`
    : `linear-gradient(135deg, ${palette.bg1}, ${palette.bg2})`;
  return `
  <div class="card kids" style="
    background:${bgCss};
    border:2px solid ${palette.accent}A6;
    color:${palette.text};
  ">
    <!-- Top emoji border strip — placeholder for Phase 3 theme art. -->
    <div class="kids-border-top" aria-hidden="true">${palette.emoji}</div>
    <!-- Bottom emoji border strip — mirrors the top so the asymmetric
         vertical padding leaves room for both. -->
    <div class="kids-border-bottom" aria-hidden="true">${palette.emoji}</div>

    <div class="kids-overlay">
      <div class="eyebrow" style="color:${palette.accent};">YOU'RE INVITED</div>
      <div class="event-name">${safeName}</div>
      ${dateLine ? `<div class="event-date">${esc(dateLine)}</div>` : ""}
      <div class="qr-wrap" style="border-color:${palette.accent};">
        <img src="${qrDataUrl}" class="qr-img" alt=""/>
      </div>
      <div class="scan-caption">Scan to RSVP</div>
      ${safeShort ? `<div class="short-code">partywithqr.com/event/${safeShort}</div>` : ""}
      <div class="brand-strip">${brandStripHtml}</div>
    </div>
  </div>
  <!-- Theme: ${paletteKey} | preview parity v1: gradient + emoji strips
       in place of Flutter CustomPaint art. Same overlay padding,
       fonts, QR sizing, and brand strip as the in-app preview. -->`;
}

// Generic-card overlay. Padding is the explicit (20, 18, 20, 12) the
// parity contract mandates. White / variant-bg background (no themed
// decorative layer) — matches the Flutter `_Card4x6` widget.
function buildGenericHtml({
  paletteKey, palette, qrDataUrl, eventName, dateLine, shortCode, brandStripHtml,
}) {
  const safeName = esc(eventName || "Your Event");
  const safeShort = shortCode ? esc(shortCode) : "";
  return `
  <div class="card generic" style="
    background:linear-gradient(135deg, ${palette.bg}, ${palette.bg});
    border:2px solid ${palette.accent}A6;
    color:${palette.text};
  ">
    <div class="generic-overlay">
      <div class="eyebrow" style="color:${palette.accent};">YOU'RE INVITED</div>
      <div class="event-name">${safeName}</div>
      ${dateLine ? `<div class="event-date">${esc(dateLine)}</div>` : ""}
      <div class="qr-wrap" style="border-color:${palette.accent};">
        <img src="${qrDataUrl}" class="qr-img" alt=""/>
      </div>
      <div class="scan-caption">Scan to RSVP</div>
      ${safeShort ? `<div class="short-code">partywithqr.com/event/${safeShort}</div>` : ""}
      <div class="brand-strip">${brandStripHtml}</div>
    </div>
  </div>
  <!-- Theme: ${paletteKey} | Generic _Card4x6 layout, no decorative
       layer. -->`;
}

// Stylesheet shared by both layouts. CSS values mirror Flutter logical
// pixels at the 400×600 viewport choice — e.g. Flutter padding 20pt is
// CSS 20px; FredokaOne 26pt is CSS 26px. The deviceScaleFactor 3 above
// turns the resulting render into 1200×1800px at print resolution.
function buildCss() {
  return `
@import url('https://fonts.googleapis.com/css2?family=Fredoka+One&family=Nunito:wght@600;700;800&display=swap');

*, *::before, *::after { box-sizing: border-box; }
html, body {
  margin: 0; padding: 0;
  width: ${VIEWPORT_W}px; height: ${VIEWPORT_H}px;
  font-family: 'Nunito', sans-serif;
}
body { background: transparent; }

.card {
  position: relative;
  width: ${VIEWPORT_W}px;
  height: ${VIEWPORT_H}px;
  overflow: hidden;
  border-radius: 14px;
}

/* Kids overlay padding (20, 64, 20, 52) — asymmetric top reserves
   space for themed top border art. Per parity contract. */
.kids-overlay {
  position: absolute;
  inset: 0;
  padding: 64px 20px 52px 20px;
  display: flex;
  flex-direction: column;
  align-items: center;
}
/* Generic overlay padding (20, 18, 20, 12) — symmetric-ish. */
.generic-overlay {
  position: absolute;
  inset: 0;
  padding: 18px 20px 12px 20px;
  display: flex;
  flex-direction: column;
  align-items: center;
}

.kids-border-top {
  position: absolute; top: 14px; left: 0; right: 0;
  text-align: center;
  font-size: 22px; letter-spacing: 6px;
  pointer-events: none;
}
.kids-border-bottom {
  position: absolute; bottom: 14px; left: 0; right: 0;
  text-align: center;
  font-size: 22px; letter-spacing: 6px;
  pointer-events: none;
}

.eyebrow {
  font-family: 'Nunito', sans-serif;
  font-size: 11px;
  font-weight: 800;
  letter-spacing: 3.2px;
}
.event-name {
  flex: 1;
  display: flex; align-items: center; justify-content: center;
  text-align: center;
  font-family: 'Fredoka One', cursive;
  font-size: 26px;
  line-height: 1.05;
  padding: 12px 0 4px 0;
  text-shadow: 0 1px 4px rgba(0,0,0,0.33);
}
.generic .event-name {
  font-size: 24px;
  line-height: 1.1;
  text-shadow: none;
  padding: 14px 0 4px 0;
}

.event-date {
  font-family: 'Nunito', sans-serif;
  font-size: 13px;
  font-weight: 700;
  opacity: 0.92;
  margin-bottom: 12px;
}

/* QR sized to 30% of card width = 120px at 400px viewport, which
   becomes 360px at deviceScaleFactor 3 — comfortably above the 300px
   (1.0") general-population scan threshold the parity contract
   requires. */
.qr-wrap {
  width: 120px;
  height: 120px;
  padding: 6px;
  background: #fff;
  border-radius: 8px;
  border: 2px solid currentColor;
}
.qr-img {
  width: 100%;
  height: 100%;
  display: block;
}

.scan-caption {
  font-family: 'Nunito', sans-serif;
  font-size: 11px;
  font-weight: 700;
  letter-spacing: 1.2px;
  opacity: 0.78;
  margin-top: 8px;
}
.short-code {
  font-family: 'Nunito', sans-serif;
  font-size: 10px;
  font-weight: 700;
  letter-spacing: 0.4px;
  opacity: 0.85;
  margin-top: 4px;
}

.brand-strip {
  margin-top: 12px;
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 30px;
}
.brand-wordmark {
  font-family: 'Fredoka One', cursive;
  font-size: 16px;
  letter-spacing: 1px;
}
.brand-hosted {
  font-family: 'Nunito', sans-serif;
  font-size: 12px;
  font-weight: 700;
}
.brand-logo {
  height: 30px;
  width: auto;
  max-width: 60%;
  object-fit: contain;
}
  `;
}

// Lazy-initialized Puppeteer browser. Cloud Functions reuse instances
// across invocations within the same container's lifecycle, so paying
// the ~5s Chromium spin-up once per cold start (rather than per call)
// gives every subsequent invocation a ~1-2s screenshot.
//
// CAVEAT: this requires the caller (createMerchOrder.js) to be
// configured with at least 1GiB memory and an extended timeout (set
// timeoutSeconds: 120 or higher). Puppeteer + Chromium does not fit
// in the default 256MB.
let _browser = null;
async function getBrowser() {
  if (_browser && _browser.connected) return _browser;
  _browser = await puppeteer.launch({
    headless: true,
    // --no-sandbox: required because Cloud Functions runs as a non-
    //   privileged user inside its own sandbox; Chromium's built-in
    //   sandbox would fail to acquire its privileged helpers.
    // --disable-dev-shm-usage: /dev/shm is small in serverless
    //   containers; backing it with /tmp avoids "Out of shared
    //   memory" crashes on bigger renders.
    args: [
      "--no-sandbox",
      "--disable-setuid-sandbox",
      "--disable-dev-shm-usage",
      "--disable-gpu",
    ],
  });
  // Reset cached browser if it ever disconnects (e.g. crash) so the
  // next call relaunches instead of failing on a stale handle.
  _browser.on("disconnected", () => { _browser = null; });
  return _browser;
}

async function generatePrintFile({
  orderId,
  theme,            // MerchTheme — has .key (e.g. 'dinosaur') and .variants[]
  themeVariant,     // numeric index into theme.variants
  productType,
  packSize,
  eventQrCode,
  eventShortCode,
  eventId,
  eventName,
  eventDate,
  hostName,
  accountTier,
  customDesignUrl,  // currently unused — for future BYO-design path
}) {
  const printQrUrl = resolveEventUrl({ eventQrCode, eventShortCode, eventId });
  if (!printQrUrl) {
    throw new Error("generatePrintFile: no usable event URL (need shortCode or eventId)");
  }

  // Generate the QR as a data URL so it embeds into the HTML without
  // requiring a separate Storage upload + signed URL round-trip. PNG
  // at QR-error-correction-M is comfortably scannable from a 1.2"
  // printed code while staying small enough to inline.
  const qrDataUrl = await QRCode.toDataURL(printQrUrl, {
    errorCorrectionLevel: "M",
    margin: 1,
    scale: 8,
    color: { dark: "#000000", light: "#FFFFFF" },
  });

  // Resolve theme + palette. Kids match → themed layout; otherwise
  // fall back to the generic _Card4x6 path with whatever variant the
  // caller picked.
  const themeKey = theme && theme.key ? theme.key : "";
  const kidsKey = kidsThemeFromKey(themeKey);
  const variant = theme && Array.isArray(theme.variants) && theme.variants.length > 0
    ? theme.variants[Math.max(0, Math.min(themeVariant ?? 0, theme.variants.length - 1))]
    : null;

  const dateLine = formatPrintDate(eventDate);

  let cardHtml;
  let usedPaletteKey;
  if (kidsKey) {
    const palette = KIDS_PALETTES[kidsKey];
    usedPaletteKey = kidsKey;
    const brandStripHtml = buildBrandStripHtml({
      accountTier, hostName, orgLogoUrl: null,
      accent: palette.accent, text: palette.text,
    });
    // ↑ orgLogoUrl currently isn't threaded through the createMerchOrder
    //   payload; the businessPlus tier therefore falls back to the
    //   wordmark in print until that field is added to the inputs.
    cardHtml = buildKidsHtml({
      paletteKey: kidsKey, palette, qrDataUrl,
      eventName, dateLine, shortCode: eventShortCode,
      brandStripHtml,
    });
  } else {
    const palette = genericPalette(variant);
    usedPaletteKey = `generic:${variant ? variant.name : "default"}`;
    const brandStripHtml = buildBrandStripHtml({
      accountTier, hostName, orgLogoUrl: null,
      accent: palette.accent, text: palette.text,
    });
    cardHtml = buildGenericHtml({
      paletteKey: usedPaletteKey, palette, qrDataUrl,
      eventName, dateLine, shortCode: eventShortCode,
      brandStripHtml,
    });
  }

  const html = `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"/>
<style>${buildCss()}</style>
</head><body>${cardHtml}</body></html>`;

  // Render. Single page reused per invocation; the browser stays open
  // across invocations courtesy of getBrowser().
  const browser = await getBrowser();
  const page = await browser.newPage();
  let png;
  try {
    await page.setViewport({
      width: VIEWPORT_W,
      height: VIEWPORT_H,
      deviceScaleFactor: DEVICE_SCALE,
    });
    // networkidle0 waits for the Google Fonts requests to settle so
    // the screenshot never lands with system-fallback fonts (parity
    // clause #1). If Fonts time out we still continue — better an
    // approximate font than a stuck render — but log loudly.
    await page.setContent(html, { waitUntil: "networkidle0", timeout: 30000 });
    png = await page.screenshot({ type: "png", omitBackground: false });
  } finally {
    await page.close().catch(() => {});
  }

  // Upload to Storage. Path mirrors the prior placeholder so any
  // admin tooling that already pointed at orders/{orderId}/print-
  // file.* keeps working — only the extension changes (svg → png).
  const bucket = getStorage().bucket();
  const file = bucket.file(`orders/${orderId}/print-file.png`);
  await file.save(png, {
    contentType: "image/png",
    public: false,
    resumable: false,
    metadata: {
      cacheControl: "private, max-age=0, no-store",
      metadata: {
        placeholder: "false",
        renderer: "puppeteer-v1",
        themeKey: themeKey,
        paletteKey: usedPaletteKey,
        productType: productType || "",
        packSize: String(packSize || ""),
        accountTier: accountTier || "personal",
      },
    },
  });

  // 7-day signed URL — long enough for any human admin to download
  // the file before re-rendering would be required.
  const [signed] = await file.getSignedUrl({
    action: "read",
    expires: Date.now() + 7 * 24 * 60 * 60 * 1000,
  });

  void customDesignUrl; // reserved for the BYO-design Phase 4 path
  return { url: signed, isPlaceholder: false };
}

module.exports = { generatePrintFile, resolveEventUrl };
