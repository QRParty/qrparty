const { getStorage } = require("firebase-admin/storage");

// Phase-1 placeholder. Generates a clearly-labeled SVG saying
// "PLACEHOLDER PRINT FILE — DO NOT SHIP" so Chris can see at a glance that
// this isn't a real artwork file. Vistaprint won't accept SVG either, which
// is a feature here — uploading this file would visibly fail preflight.
//
// When the real renderer lands, swap this out for a CMYK/300DPI PNG. Two
// viable approaches:
//   1. puppeteer + HTML/CSS template (easiest layout, ~250MB cold start)
//   2. sharp + qrcode + SVG composite (lightweight, more layout code)
// Inputs already wired: theme, themeVariant, productType, packSize,
// eventQrCode, eventShortCode, eventId, eventName, eventDate, hostName,
// accountTier, customDesignUrl.
//
// ── PARITY CONTRACT (future renderer) ──────────────────────────────────
// The host approves a card visually via lib/widgets/invitation_preview.dart
// before the order is placed. Whatever the print render produces MUST
// match what the host saw, or every shipment is a UX surprise. When
// swapping this placeholder for the real PNG renderer, the new code
// must satisfy ALL of:
//   • Fonts: FredokaOne (display) + Nunito (body), same weights as
//     the preview. Embed via google_fonts metadata or ship the font
//     files in the function bundle — system font fallback drifts.
//   • QR URL: pass through resolveEventUrl(...) below — same shortCode-
//     first / legacy-id-fallback order the preview uses via
//     invitation_preview.dart's _eventQrUrl helper.
//   • QR size: ≥1.0 inch on the printed long side at 300 DPI for
//     general-population scan reliability. The preview now sizes its
//     QR container at 104px / 540px card-height (~19.3%), targeting
//     ~1.16" on a 6"-tall card. Match that proportion or exceed it.
//   • Kids vs generic padding: Kids overlay uses fromLTRB(20, 64, 20,
//     52) — the asymmetric 64-pt top reserves space for themed border
//     art that sits OUTSIDE the content column. Generic _Card4x6 uses
//     fromLTRB(20, 18, 20, 12). Mirror the asymmetry per theme; uniform
//     padding will collide eyebrow text with Kids border art.
//   • Brand strip per accountTier (see _BrandStrip in the preview):
//       'businessPlus' → orgLogoUrl image (fallback: QR PARTY wordmark)
//       'business'     → "Hosted by {hostName}" line
//       else (personal) → QR PARTY wordmark
//   • DO NOT draw the _PreviewWatermark layer the preview overlays.
//     That widget exists ONLY to mark the in-app preview surface; it
//     must be excluded from any shipped print artwork.

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

async function generatePrintFile({
  orderId,
  theme,
  themeVariant,
  productType,
  packSize,
  eventQrCode,
  eventShortCode,
  eventId,
  eventName,
  eventDate,
  hostName,
  accountTier,
  customDesignUrl,
}) {
  // Single source of truth for the URL that will be rendered into the
  // print-file QR. The placeholder SVG below doesn't actually use it
  // yet, but resolving it here keeps the input-shape contract honest
  // for the real renderer swap.
  const printQrUrl = resolveEventUrl({ eventQrCode, eventShortCode, eventId });
  const safeName = (eventName || "").replace(/[<>&"']/g, "").slice(0, 80);
  const variantLabel = customDesignUrl ? "CUSTOM UPLOAD" : `${theme || "classic"} · v${themeVariant ?? 0}`;
  const productLabel = productType === "invitation" ? "INVITATION" : "STICKER";

  const svg = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 800" width="1200" height="800">',
    '  <defs>',
    '    <pattern id="warn" width="80" height="80" patternUnits="userSpaceOnUse" patternTransform="rotate(-45)">',
    '      <rect width="80" height="80" fill="#1A1A1A"/>',
    '      <rect x="0" y="0" width="40" height="80" fill="#C8922A"/>',
    '    </pattern>',
    '  </defs>',
    '  <rect width="1200" height="800" fill="url(#warn)"/>',
    '  <rect x="60" y="60" width="1080" height="680" fill="#1A1A1A" stroke="#C8922A" stroke-width="6"/>',
    '  <text x="600" y="240" text-anchor="middle" font-family="Arial Black, sans-serif" font-size="92" fill="#C8922A" font-weight="900">PLACEHOLDER</text>',
    '  <text x="600" y="340" text-anchor="middle" font-family="Arial Black, sans-serif" font-size="92" fill="#FFFFFF" font-weight="900">PRINT FILE</text>',
    '  <text x="600" y="430" text-anchor="middle" font-family="Arial, sans-serif" font-size="48" fill="#FF3B30" font-weight="800">DO NOT SHIP</text>',
    `  <text x="600" y="540" text-anchor="middle" font-family="Arial, sans-serif" font-size="28" fill="#FFFFFF" font-weight="700">${packSize || ""} ${productLabel} ${packSize === 1 ? "" : "S"}</text>`,
    `  <text x="600" y="586" text-anchor="middle" font-family="Arial, sans-serif" font-size="22" fill="#A9A6B8">Event: ${safeName}</text>`,
    `  <text x="600" y="618" text-anchor="middle" font-family="Arial, sans-serif" font-size="22" fill="#A9A6B8">Theme: ${variantLabel}</text>`,
    `  <text x="600" y="650" text-anchor="middle" font-family="Arial, sans-serif" font-size="22" fill="#A9A6B8">Tier: ${accountTier || "personal"}</text>`,
    `  <text x="600" y="700" text-anchor="middle" font-family="Arial, sans-serif" font-size="16" fill="#A9A6B8">Order ${orderId}</text>`,
    '</svg>',
  ].join("\n");

  const bucket = getStorage().bucket();
  const file = bucket.file(`orders/${orderId}/print-file.svg`);
  await file.save(Buffer.from(svg), {
    contentType: "image/svg+xml",
    public: false,
    resumable: false,
    metadata: {
      cacheControl: "no-cache, max-age=0",
      metadata: {
        placeholder: "true",
        warning: "DO_NOT_SHIP",
      },
    },
  });

  // Signed URL valid for 7 days — long enough for any human admin to download.
  const [signed] = await file.getSignedUrl({
    action: "read",
    expires: Date.now() + 7 * 24 * 60 * 60 * 1000,
  });

  // Side-effects intentionally explicit so future SVG→PNG swap is one return.
  void hostName; void eventQrCode; void eventDate; void printQrUrl;
  return { url: signed, isPlaceholder: true };
}

module.exports = { generatePrintFile, resolveEventUrl };
