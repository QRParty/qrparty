import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// ── Product / shipping enums ──────────────────────────────────
enum MerchProduct { sticker, invitation }
enum MerchShipping { standard, expedited }

enum MerchStatus { pendingFulfillment, sentToPrinter, shipped, delivered, cancelled }

extension MerchStatusName on MerchStatus {
  String get wireName => switch (this) {
    MerchStatus.pendingFulfillment => 'pending_fulfillment',
    MerchStatus.sentToPrinter      => 'sent_to_printer',
    MerchStatus.shipped            => 'shipped',
    MerchStatus.delivered          => 'delivered',
    MerchStatus.cancelled          => 'cancelled',
  };
  String get label => switch (this) {
    MerchStatus.pendingFulfillment => 'Pending',
    MerchStatus.sentToPrinter      => 'Sent to Printer',
    MerchStatus.shipped            => 'Shipped',
    MerchStatus.delivered          => 'Delivered',
    MerchStatus.cancelled          => 'Cancelled',
  };
  static MerchStatus parse(String? s) => switch (s) {
    'sent_to_printer' => MerchStatus.sentToPrinter,
    'shipped'         => MerchStatus.shipped,
    'delivered'       => MerchStatus.delivered,
    'cancelled'       => MerchStatus.cancelled,
    _                 => MerchStatus.pendingFulfillment,
  };
}

// ── Theme catalog ─────────────────────────────────────────────
// Each entry has 3 color variants. Stickers get the QR + brand mark
// regardless of theme; the theme primarily styles invitations and the
// in-app preview. To swap in real art, add a [previewAsset] / [printAsset]
// path; the rest of the system wires through unchanged.
class MerchTheme {
  final String key;
  final String name;
  final String emoji;
  final String tagline;
  final List<MerchThemeVariant> variants;
  const MerchTheme({
    required this.key,
    required this.name,
    required this.emoji,
    required this.tagline,
    required this.variants,
  });
}

class MerchThemeVariant {
  final String name;
  final Color bg;
  final Color accent;
  final Color text;
  const MerchThemeVariant({required this.name, required this.bg, required this.accent, required this.text});
}

// Hard-coded for Phase 1. When real art lands, expand each variant with
// [previewAssetPath] / [printAssetPath] fields and update the picker + the
// generatePrintFile Cloud Function to read them.
const merchThemes = <MerchTheme>[
  MerchTheme(
    key: 'classic',
    name: 'Classic',
    emoji: '🎉',
    tagline: 'Confetti, brand colors, works for any event',
    variants: [
      MerchThemeVariant(name: 'Purple', bg: Color(0xFF2D3047), accent: Color(0xFF9C7FD4), text: Colors.white),
      MerchThemeVariant(name: 'Gold',   bg: Color(0xFF1F1F1F), accent: Color(0xFFC8922A), text: Colors.white),
      MerchThemeVariant(name: 'Forest', bg: Color(0xFF2C3E36), accent: Color(0xFF52796F), text: Colors.white),
    ],
  ),
  MerchTheme(
    key: 'superhero',
    name: 'Superhero',
    emoji: '🦸',
    tagline: 'Bold action — original mask, no licensed characters',
    variants: [
      MerchThemeVariant(name: 'Red',   bg: Color(0xFF8B1A1A), accent: Color(0xFFFFCC00), text: Colors.white),
      MerchThemeVariant(name: 'Blue',  bg: Color(0xFF15396A), accent: Color(0xFFFF3B30), text: Colors.white),
      MerchThemeVariant(name: 'Green', bg: Color(0xFF1F5C2A), accent: Color(0xFFFFCC00), text: Colors.white),
    ],
  ),
  MerchTheme(
    key: 'princess',
    name: 'Princess',
    emoji: '👑',
    tagline: 'Crown, sparkles, original castle silhouette',
    variants: [
      MerchThemeVariant(name: 'Pink',     bg: Color(0xFFFCE4EC), accent: Color(0xFFD4AF37), text: Color(0xFF55204A)),
      MerchThemeVariant(name: 'Lavender', bg: Color(0xFFE9DEFF), accent: Color(0xFFC8922A), text: Color(0xFF3D2A55)),
      MerchThemeVariant(name: 'Mint',     bg: Color(0xFFD8F3DC), accent: Color(0xFFD4AF37), text: Color(0xFF1B4332)),
    ],
  ),
  MerchTheme(
    key: 'pirate',
    name: 'Pirate',
    emoji: '🏴‍☠️',
    tagline: 'Skull, treasure map, classic black + red + gold',
    variants: [
      MerchThemeVariant(name: 'Midnight', bg: Color(0xFF111111), accent: Color(0xFFC8922A), text: Colors.white),
      MerchThemeVariant(name: 'Crimson',  bg: Color(0xFF4A0E0E), accent: Color(0xFFE3C04F), text: Colors.white),
      MerchThemeVariant(name: 'Parchment',bg: Color(0xFFE8D8A8), accent: Color(0xFF6B0E0E), text: Color(0xFF1A1A1A)),
    ],
  ),
  MerchTheme(
    key: 'dinosaur',
    name: 'Dinosaur',
    emoji: '🦖',
    tagline: 'Friendly cartoon dinos, prehistoric energy',
    variants: [
      MerchThemeVariant(name: 'Jungle', bg: Color(0xFF2F5233), accent: Color(0xFFE76F51), text: Colors.white),
      MerchThemeVariant(name: 'Sunset', bg: Color(0xFF5A2D2D), accent: Color(0xFFF4A261), text: Colors.white),
      MerchThemeVariant(name: 'Sky',    bg: Color(0xFF7AB7C4), accent: Color(0xFF264653), text: Colors.white),
    ],
  ),
  MerchTheme(
    key: 'space',
    name: 'Space',
    emoji: '🚀',
    tagline: 'Planets, rockets, original starscape',
    variants: [
      MerchThemeVariant(name: 'Deep',   bg: Color(0xFF0B0F2A), accent: Color(0xFF9C7FD4), text: Colors.white),
      MerchThemeVariant(name: 'Nebula', bg: Color(0xFF2D1B5E), accent: Color(0xFFE0B0FF), text: Colors.white),
      MerchThemeVariant(name: 'Steel',  bg: Color(0xFF1F2933), accent: Color(0xFFC0C9D6), text: Colors.white),
    ],
  ),
  MerchTheme(
    key: 'unicorn',
    name: 'Unicorn',
    emoji: '🦄',
    tagline: 'Pastel rainbow, clouds, sparkle',
    variants: [
      MerchThemeVariant(name: 'Pastel', bg: Color(0xFFFFE5F0), accent: Color(0xFF9C7FD4), text: Color(0xFF5C2D69)),
      MerchThemeVariant(name: 'Mint',   bg: Color(0xFFE0F7E9), accent: Color(0xFFFF6BB5), text: Color(0xFF2D3047)),
      MerchThemeVariant(name: 'Sky',    bg: Color(0xFFD4EDFF), accent: Color(0xFFFFC857), text: Color(0xFF1A2D5A)),
    ],
  ),
  MerchTheme(
    key: 'sports',
    name: 'Sports',
    emoji: '🏆',
    tagline: 'Ball + trophy graphic, pick a sport at checkout',
    variants: [
      MerchThemeVariant(name: 'Field',  bg: Color(0xFF1F5C2A), accent: Color(0xFFFFCC00), text: Colors.white),
      MerchThemeVariant(name: 'Court',  bg: Color(0xFFD2691E), accent: Color(0xFF1A1A1A), text: Colors.white),
      MerchThemeVariant(name: 'Diamond',bg: Color(0xFF1F3A93), accent: Color(0xFFFFFFFF), text: Colors.white),
    ],
  ),
  MerchTheme(
    key: 'animals',
    name: 'Animals',
    emoji: '🐾',
    tagline: 'Friendly critters, paw prints, warm earth tones',
    variants: [
      MerchThemeVariant(name: 'Sand', bg: Color(0xFFF5E8D4), accent: Color(0xFFC97B4A), text: Color(0xFF4A2E1A)),
      MerchThemeVariant(name: 'Sage', bg: Color(0xFFD8E4D0), accent: Color(0xFFC97B4A), text: Color(0xFF2C3E36)),
      MerchThemeVariant(name: 'Clay', bg: Color(0xFFD2A07A), accent: Color(0xFFFFF3D6), text: Color(0xFF3A1E0F)),
    ],
  ),
  MerchTheme(
    key: 'circus',
    name: 'Circus & Carnival',
    emoji: '🎪',
    tagline: 'Big-top stripes, bunting, festive energy',
    variants: [
      MerchThemeVariant(name: 'Big Top', bg: Color(0xFFE63946), accent: Color(0xFFFFD23F), text: Colors.white),
      MerchThemeVariant(name: 'Sunrise', bg: Color(0xFFFFD23F), accent: Color(0xFFE63946), text: Color(0xFF1A1A1A)),
      MerchThemeVariant(name: 'Vintage', bg: Color(0xFFFAE5C9), accent: Color(0xFFC1121F), text: Color(0xFF6B0E0E)),
    ],
  ),
  MerchTheme(
    key: 'mermaids',
    name: 'Mermaids & Ocean',
    emoji: '🧜',
    tagline: 'Teals, corals, waves and shimmer',
    variants: [
      MerchThemeVariant(name: 'Lagoon', bg: Color(0xFF00838F), accent: Color(0xFFFF7F6B), text: Colors.white),
      MerchThemeVariant(name: 'Reef',   bg: Color(0xFF004D5A), accent: Color(0xFF7FFFD4), text: Colors.white),
      MerchThemeVariant(name: 'Shore',  bg: Color(0xFFB2EBF2), accent: Color(0xFFE45A5A), text: Color(0xFF003B40)),
    ],
  ),
];

MerchTheme themeByKey(String key) =>
    merchThemes.firstWhere((t) => t.key == key, orElse: () => merchThemes.first);

// ── Pricing tables ────────────────────────────────────────────
// Standard shipping is built into pack prices (free), so the listed
// retail = what the customer pays for standard shipping. Expedited adds
// a flat upgrade. Server (functions/createMerchOrder.js) mirrors these —
// keep both in sync or live amount checks fail.
class MerchPricing {
  static const Map<int, int> _stickerCents = {10: 2499, 25: 4499, 50: 7499};
  static const Map<int, int> _inviteCents  = {25: 3999, 50: 6499, 100: 10499};
  static const int shippingStandardCents  = 0;
  static const int shippingExpeditedCents = 999;

  static List<int> packsFor(MerchProduct p) =>
      p == MerchProduct.invitation ? const [25, 50, 100] : const [10, 25, 50];

  static int? subtotalCents({required MerchProduct product, required int packSize}) =>
      (product == MerchProduct.invitation ? _inviteCents : _stickerCents)[packSize];

  static int shippingCents(MerchShipping s) =>
      s == MerchShipping.expedited ? shippingExpeditedCents : shippingStandardCents;

  /// Stripe US standard rate. Used only for admin profit math.
  static int estimateStripeFeeCents(int totalCents) =>
      (totalCents * 0.029).round() + 30;

  static String format(int cents) => '\$${(cents / 100).toStringAsFixed(2)}';
}

// ── Order address ────────────────────────────────────────────
class MerchAddress {
  final String name;
  final String line1;
  final String line2;
  final String city;
  final String state;
  final String zip;
  final String country;
  const MerchAddress({
    required this.name, required this.line1, this.line2 = '',
    required this.city, required this.state, required this.zip, this.country = 'US',
  });
  Map<String, dynamic> toMap() => {
    'name': name, 'line1': line1, 'line2': line2,
    'city': city, 'state': state, 'zip': zip, 'country': country,
    'formatted': formatted,
  };
  static MerchAddress fromMap(Map<String, dynamic> m) => MerchAddress(
    name:    (m['name']    as String?) ?? '',
    line1:   (m['line1']   as String?) ?? '',
    line2:   (m['line2']   as String?) ?? '',
    city:    (m['city']    as String?) ?? '',
    state:   (m['state']   as String?) ?? '',
    zip:     (m['zip']     as String?) ?? '',
    country: (m['country'] as String?) ?? 'US',
  );
  String get formatted {
    final cityLine = '$city, $state $zip';
    return [name, line1, if (line2.isNotEmpty) line2, cityLine].join('\n');
  }
  bool get isComplete =>
      name.isNotEmpty && line1.isNotEmpty && city.isNotEmpty &&
      state.isNotEmpty && zip.isNotEmpty;
}

// ── Order doc ────────────────────────────────────────────────
class MerchOrder {
  final String id;
  final String userId;
  final String eventId;
  final String eventName;
  final DateTime? eventDate;
  final MerchProduct productType;
  final int packSize;
  final String themeKey;
  final int themeVariant;
  final String? customDesignUrl;
  final String? printFileUrl;
  final MerchAddress shippingAddress;
  final MerchShipping shippingSpeed;
  final int retailTotalCents;
  final int? yourCostCents;
  final int stripeFeeCents;
  final MerchStatus status;
  final List<Map<String, dynamic>> statusHistory;
  final String? trackingNumber;
  final String? trackingCarrier;
  final DateTime? estimatedDelivery;
  final String adminNotes;
  final String customerName;
  final String customerEmail;
  final String accountTier;
  final String? stripePaymentIntentId;
  final bool isTestOrder;
  final DateTime createdAt;
  final DateTime? updatedAt;

  const MerchOrder({
    required this.id, required this.userId, required this.eventId,
    required this.eventName, required this.productType, required this.packSize,
    required this.themeKey, required this.themeVariant, required this.shippingAddress,
    required this.shippingSpeed, required this.retailTotalCents, required this.stripeFeeCents,
    required this.status, required this.statusHistory, required this.adminNotes,
    required this.customerName, required this.customerEmail,
    required this.accountTier, required this.isTestOrder, required this.createdAt,
    this.eventDate, this.customDesignUrl, this.printFileUrl,
    this.yourCostCents, this.trackingNumber, this.trackingCarrier,
    this.estimatedDelivery, this.stripePaymentIntentId, this.updatedAt,
  });

  int get profitCents {
    final cost = yourCostCents ?? 0;
    return retailTotalCents - cost - stripeFeeCents;
  }

  static MerchOrder fromDoc(DocumentSnapshot doc) {
    final m = doc.data() as Map<String, dynamic>;
    return MerchOrder(
      id: doc.id,
      userId:    (m['userId']    as String?) ?? '',
      eventId:   (m['eventId']   as String?) ?? '',
      eventName: (m['eventName'] as String?) ?? '',
      eventDate: (m['eventDate'] as Timestamp?)?.toDate(),
      productType: (m['productType'] as String?) == 'invitation'
          ? MerchProduct.invitation
          : MerchProduct.sticker,
      packSize:    (m['packSize']    as num?)?.toInt() ?? 0,
      themeKey:    (m['theme']       as String?) ?? 'classic',
      themeVariant:(m['themeVariant']as num?)?.toInt() ?? 0,
      customDesignUrl: m['customDesignUrl'] as String?,
      printFileUrl:    m['printFileUrl']    as String?,
      shippingAddress: MerchAddress.fromMap(
          (m['shippingAddress'] as Map?)?.cast<String, dynamic>() ?? const {}),
      shippingSpeed: (m['shippingSpeed'] as String?) == 'expedited'
          ? MerchShipping.expedited
          : MerchShipping.standard,
      retailTotalCents: (m['retailTotalCents'] as num?)?.toInt()
          ?? (m['totalCents'] as num?)?.toInt() ?? 0,
      yourCostCents: (m['yourCostCents'] as num?)?.toInt(),
      stripeFeeCents: (m['stripeFeeCents'] as num?)?.toInt() ?? 0,
      status: MerchStatusName.parse(m['status'] as String?),
      statusHistory: ((m['statusHistory'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map)).toList(),
      trackingNumber:  m['trackingNumber']  as String?,
      trackingCarrier: m['trackingCarrier'] as String?,
      estimatedDelivery: (m['estimatedDelivery'] as Timestamp?)?.toDate(),
      adminNotes:    (m['adminNotes']    as String?) ?? '',
      customerName:  (m['customerName']  as String?) ?? '',
      customerEmail: (m['customerEmail'] as String?) ?? '',
      accountTier:   (m['accountTier']   as String?) ?? 'personal',
      stripePaymentIntentId: m['stripePaymentIntentId'] as String?,
      isTestOrder:   m['isTestOrder']    == true,
      createdAt: (m['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (m['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}
