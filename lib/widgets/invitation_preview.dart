import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../models/merch_order.dart';
import '../utils.dart';

/// Canonical RSVP URL — matches the format used in generate_qr_screen.dart,
/// order_merch_screen.dart, admin_order_detail_modal.dart, and the
/// `eventQrCode` field stamped on order docs by createMerchOrder.js.
String _eventQrUrl(String eventId) => 'https://partywithqr.com/event?id=$eventId';

/// Phase 1 Kids-birthday theme set. Each value resolves to a distinct
/// Flutter-rendered card (gradient + decorative shapes drawn from
/// Container / BoxDecoration / ClipPath / Stack — no external image
/// assets). Phase 2 will swap each design for commissioned artwork.
enum KidsBirthdayTheme {
  dinosaurs,
  space,
  unicornsRainbows,
  sports,
  animals,
  circusCarnival,
  mermaidsOcean,
  princessFairies,
}

/// Maps a [MerchTheme.key] to a [KidsBirthdayTheme] when one exists.
/// Returns `null` for keys without a Kids design (caller falls back to
/// the generic [_Card4x6]).
KidsBirthdayTheme? _kidsThemeFromKey(String key) {
  switch (key) {
    case 'dinosaur':  return KidsBirthdayTheme.dinosaurs;
    case 'space':     return KidsBirthdayTheme.space;
    case 'unicorn':   return KidsBirthdayTheme.unicornsRainbows;
    case 'sports':    return KidsBirthdayTheme.sports;
    case 'princess':  return KidsBirthdayTheme.princessFairies;
    case 'animals':   return KidsBirthdayTheme.animals;
    case 'circus':    return KidsBirthdayTheme.circusCarnival;
    case 'mermaids':  return KidsBirthdayTheme.mermaidsOcean;
    default:          return null;
  }
}

/// Bottom-sheet preview of a 4×6 invitation card. When [isKidsBirthday]
/// is true and the selected theme has a Kids-specific design, renders
/// the themed card; otherwise falls back to the generic variant-driven
/// card.
class InvitationPreviewSheet extends StatelessWidget {
  final String eventId;
  /// Optional 6-char short code (e.g. `A4B7K9`). When present we render
  /// `partywithqr.com/event/XXXXXX` under the QR as a typeable fallback.
  final String? shortCode;
  final MerchTheme theme;
  final int themeVariant;
  final String eventName;
  final DateTime? eventDate;
  final String accountTier; // 'personal' | 'business' | 'businessPlus'
  final String hostName;
  final String? orgLogoUrl;
  final int packSize;
  final bool isKidsBirthday;

  const InvitationPreviewSheet({
    super.key,
    required this.eventId,
    required this.theme,
    required this.themeVariant,
    required this.eventName,
    required this.accountTier,
    required this.hostName,
    required this.packSize,
    this.shortCode,
    this.eventDate,
    this.orgLogoUrl,
    this.isKidsBirthday = false,
  });

  static Future<void> show(
    BuildContext context, {
    required String eventId,
    String? shortCode,
    required MerchTheme theme,
    required int themeVariant,
    required String eventName,
    DateTime? eventDate,
    required String accountTier,
    required String hostName,
    String? orgLogoUrl,
    required int packSize,
    bool isKidsBirthday = false,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => InvitationPreviewSheet(
        eventId: eventId,
        shortCode: shortCode,
        theme: theme,
        themeVariant: themeVariant,
        eventName: eventName,
        eventDate: eventDate,
        accountTier: accountTier,
        hostName: hostName,
        orgLogoUrl: orgLogoUrl,
        packSize: packSize,
        isKidsBirthday: isKidsBirthday,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final variant = theme.variants[themeVariant.clamp(0, theme.variants.length - 1)];
    final kidsTheme = isKidsBirthday ? _kidsThemeFromKey(theme.key) : null;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 24 + MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.dark,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: AppColors.muted.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Invitation preview',
            style: TextStyle(fontFamily: 'FredokaOne', fontSize: 22, color: Colors.white),
          ),
          const SizedBox(height: 4),
          Text(
            kidsTheme != null
                ? '$packSize pack · ${theme.name} · Kids'
                : '$packSize pack · ${theme.name} · ${variant.name}',
            style: const TextStyle(
              fontFamily: 'Nunito', fontSize: 13,
              fontWeight: FontWeight.w600, color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 18),
          if (kidsTheme != null)
            KidsBirthdayInvitationCard(
              theme: kidsTheme,
              qrData: _eventQrUrl(eventId),
              shortCode: shortCode,
              eventName: eventName,
              eventDate: eventDate,
              accountTier: accountTier,
              hostName: hostName,
              orgLogoUrl: orgLogoUrl,
            )
          else
            _Card4x6(
              variant: variant,
              qrData: _eventQrUrl(eventId),
              shortCode: shortCode,
              eventName: eventName,
              eventDate: eventDate,
              accountTier: accountTier,
              hostName: hostName,
              orgLogoUrl: orgLogoUrl,
            ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.gold,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text(
                'Looks Good!',
                style: TextStyle(
                  fontFamily: 'Nunito', fontWeight: FontWeight.w800,
                  fontSize: 15, letterSpacing: 0.4,
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Theme-picker thumbnail. Renders the same Flutter-rendered card design
/// that ships in the order, but with no event info so it reads as
/// pure design preview. Use this inside the theme picker grid so each
/// tile fills with a true scaled-down invitation.
class ThemeMiniPreview extends StatelessWidget {
  final MerchTheme theme;
  final int variantIndex;
  final bool isKidsBirthday;

  const ThemeMiniPreview({
    super.key,
    required this.theme,
    this.variantIndex = 0,
    this.isKidsBirthday = false,
  });

  @override
  Widget build(BuildContext context) {
    final variant = theme.variants[variantIndex.clamp(0, theme.variants.length - 1)];
    final kidsTheme = isKidsBirthday ? _kidsThemeFromKey(theme.key) : null;
    if (kidsTheme != null) {
      return KidsBirthdayInvitationCard(
        theme: kidsTheme,
        qrData: 'https://partywithqr.com',
        eventName: '',
        accountTier: 'personal',
        hostName: '',
      );
    }
    return _Card4x6(
      variant: variant,
      qrData: 'https://partywithqr.com',
      eventName: '',
      accountTier: 'personal',
      hostName: '',
    );
  }
}

// ── PALETTE ────────────────────────────────────────────────────
// Internal helper bundling the colors each Kids theme uses. Kept private
// so the public API is just (theme + content props).
class _KidsPalette {
  final Color bg1;
  final Color bg2;
  final Color accent;
  final Color secondary;
  final Color text;
  const _KidsPalette({
    required this.bg1,
    required this.bg2,
    required this.accent,
    required this.secondary,
    required this.text,
  });
}

const _palettes = <KidsBirthdayTheme, _KidsPalette>{
  KidsBirthdayTheme.dinosaurs: _KidsPalette(
    bg1: Color(0xFF4A6B3A), bg2: Color(0xFF2C4A24),
    accent: Color(0xFFFFD23F), secondary: Color(0xFF8B6F47),
    text: Colors.white,
  ),
  KidsBirthdayTheme.space: _KidsPalette(
    bg1: Color(0xFF1B0E3D), bg2: Color(0xFF0A0524),
    accent: Color(0xFFFFB347), secondary: Color(0xFF9C7FD4),
    text: Colors.white,
  ),
  KidsBirthdayTheme.unicornsRainbows: _KidsPalette(
    bg1: Color(0xFFFFE0EC), bg2: Color(0xFFE6D6FF),
    accent: Color(0xFFE91E63), secondary: Color(0xFF9C7FD4),
    text: Color(0xFF5C2D69),
  ),
  KidsBirthdayTheme.sports: _KidsPalette(
    bg1: Color(0xFFD62828), bg2: Color(0xFF8B1A1A),
    accent: Color(0xFFFFCC00), secondary: Colors.white,
    text: Colors.white,
  ),
  KidsBirthdayTheme.animals: _KidsPalette(
    bg1: Color(0xFFF5E8D4), bg2: Color(0xFFEBD5B5),
    accent: Color(0xFFC97B4A), secondary: Color(0xFF6B8B5E),
    text: Color(0xFF4A2E1A),
  ),
  KidsBirthdayTheme.circusCarnival: _KidsPalette(
    bg1: Color(0xFFE63946), bg2: Color(0xFFC1121F),
    accent: Color(0xFFFFD23F), secondary: Colors.white,
    text: Colors.white,
  ),
  KidsBirthdayTheme.mermaidsOcean: _KidsPalette(
    bg1: Color(0xFF00838F), bg2: Color(0xFF004D5A),
    accent: Color(0xFFFF7F6B), secondary: Color(0xFF7FFFD4),
    text: Colors.white,
  ),
  KidsBirthdayTheme.princessFairies: _KidsPalette(
    bg1: Color(0xFFFFB7D5), bg2: Color(0xFFB07FE0),
    accent: Color(0xFFFFD700), secondary: Colors.white,
    text: Color(0xFF3D2A55),
  ),
};

// ── KIDS BIRTHDAY INVITATION CARD ──────────────────────────────
class KidsBirthdayInvitationCard extends StatelessWidget {
  final KidsBirthdayTheme theme;
  /// URL the QR encodes — typically `https://partywithqr.com/event?id=…`.
  final String qrData;
  /// Optional 6-char short code rendered as a typeable fallback below the QR.
  final String? shortCode;
  final String eventName;
  final DateTime? eventDate;
  final String accountTier;
  final String hostName;
  final String? orgLogoUrl;

  const KidsBirthdayInvitationCard({
    super.key,
    required this.theme,
    required this.qrData,
    required this.eventName,
    required this.accountTier,
    required this.hostName,
    this.shortCode,
    this.eventDate,
    this.orgLogoUrl,
  });

  @override
  Widget build(BuildContext context) {
    final p = _palettes[theme]!;
    return AspectRatio(
      aspectRatio: 4 / 6,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: p.accent.withValues(alpha: 0.65), width: 2),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 18, offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Stack(children: [
            // Layer 1: themed background gradient + decorative shapes.
            Positioned.fill(child: _ThemedBackground(theme: theme, palette: p)),
            // Layer 2: standard content overlay (eyebrow / name / date / QR /
            // scan caption / brand strip).
            Positioned.fill(child: _KidsContentOverlay(
              palette: p,
              qrData: qrData,
              shortCode: shortCode,
              eventName: eventName,
              eventDate: eventDate,
              accountTier: accountTier,
              hostName: hostName,
              orgLogoUrl: orgLogoUrl,
            )),
            // Layer 3: faint diagonal PREVIEW watermark.
            const Positioned.fill(child: _PreviewWatermark()),
          ]),
        ),
      ),
    );
  }
}

class _ThemedBackground extends StatelessWidget {
  final KidsBirthdayTheme theme;
  final _KidsPalette palette;
  const _ThemedBackground({required this.theme, required this.palette});

  @override
  Widget build(BuildContext context) {
    final base = Container(
      decoration: BoxDecoration(
        gradient: theme == KidsBirthdayTheme.space
            ? RadialGradient(
                center: const Alignment(0.5, -0.5),
                radius: 1.4,
                colors: [palette.bg1, palette.bg2],
              )
            : LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [palette.bg1, palette.bg2],
              ),
      ),
    );
    return Stack(children: [
      Positioned.fill(child: base),
      switch (theme) {
        KidsBirthdayTheme.dinosaurs        => _DinosaursDecor(p: palette),
        KidsBirthdayTheme.space            => _SpaceDecor(p: palette),
        KidsBirthdayTheme.unicornsRainbows => _UnicornsDecor(p: palette),
        KidsBirthdayTheme.sports           => _SportsDecor(p: palette),
        KidsBirthdayTheme.animals          => _AnimalsDecor(p: palette),
        KidsBirthdayTheme.circusCarnival   => _CircusDecor(p: palette),
        KidsBirthdayTheme.mermaidsOcean    => _MermaidsDecor(p: palette),
        KidsBirthdayTheme.princessFairies  => _PrincessDecor(p: palette),
      },
    ]);
  }
}

// ── CONTENT OVERLAY (shared) ───────────────────────────────────
class _KidsContentOverlay extends StatelessWidget {
  final _KidsPalette palette;
  final String qrData;
  final String? shortCode;
  final String eventName;
  final DateTime? eventDate;
  final String accountTier;
  final String hostName;
  final String? orgLogoUrl;
  const _KidsContentOverlay({
    required this.palette,
    required this.qrData,
    required this.eventName,
    required this.accountTier,
    required this.hostName,
    this.shortCode,
    this.eventDate,
    this.orgLogoUrl,
  });

  String? get _formattedDate {
    if (eventDate == null) return null;
    const months = [
      'January','February','March','April','May','June',
      'July','August','September','October','November','December',
    ];
    final d = eventDate!;
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Extra top/bottom padding leaves room for themed borders to sit
      // outside the content column without crowding the text. Bottom
      // padding trimmed by 4px to clear the residual ~3px overflow at
      // common phone widths — themed border art still sits comfortably
      // below the brand strip at this height.
      padding: const EdgeInsets.fromLTRB(20, 64, 20, 52),
      child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Text(
          "YOU'RE INVITED",
          style: TextStyle(
            fontFamily: 'Nunito', fontSize: 11, fontWeight: FontWeight.w800,
            letterSpacing: 3.2, color: palette.accent,
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Center(
            child: Text(
              eventName.isEmpty ? 'Your Event' : eventName,
              textAlign: TextAlign.center,
              maxLines: 3, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'FredokaOne', fontSize: 26, height: 1.05,
                color: palette.text,
                shadows: const [Shadow(color: Color(0x55000000), blurRadius: 4)],
              ),
            ),
          ),
        ),
        if (_formattedDate != null) ...[
          const SizedBox(height: 4),
          Text(
            _formattedDate!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Nunito', fontSize: 13, fontWeight: FontWeight.w700,
              color: palette.text.withValues(alpha: 0.92),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Container(
          width: 88, height: 88,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: palette.accent, width: 2),
          ),
          child: QrImageView(
            data: qrData,
            version: QrVersions.auto,
            backgroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Scan to RSVP',
          style: TextStyle(
            fontFamily: 'Nunito', fontSize: 11, fontWeight: FontWeight.w700,
            letterSpacing: 1.2, color: palette.text.withValues(alpha: 0.78),
          ),
        ),
        if (shortCode != null && shortCode!.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            'partywithqr.com/event/$shortCode',
            style: TextStyle(
              fontFamily: 'Nunito', fontSize: 10, fontWeight: FontWeight.w700,
              letterSpacing: 0.4, color: palette.text.withValues(alpha: 0.85),
            ),
          ),
        ],
        const SizedBox(height: 12),
        _BrandStrip(
          accountTier: accountTier,
          hostName: hostName,
          orgLogoUrl: orgLogoUrl,
          accent: palette.accent,
          text: palette.text,
        ),
      ]),
    );
  }
}

// ── PREVIEW WATERMARK (shared) ─────────────────────────────────
class _PreviewWatermark extends StatelessWidget {
  const _PreviewWatermark();
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Center(
      child: Transform.rotate(
        angle: -math.pi / 6,
        child: Text(
          'PREVIEW',
          style: TextStyle(
            fontFamily: 'FredokaOne', fontSize: 64, letterSpacing: 6,
            color: Colors.white.withValues(alpha: 0.10),
          ),
        ),
      ),
    ),
  );
}

// ════════════════════════════════════════════════════════════════
// THEMED DECORATIONS
// Each is a Stack of Positioned shapes painted with Container /
// BoxDecoration / ClipPath / CustomPaint. No image assets.
// ════════════════════════════════════════════════════════════════

// ── 1. Dinosaurs ───────────────────────────────────────────────
class _DinosaursDecor extends StatelessWidget {
  final _KidsPalette p;
  const _DinosaursDecor({required this.p});

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      // Atmospheric mist behind everything — softens contrast in the
      // central column where the QR + name sit.
      Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -0.1), radius: 0.8,
          colors: [Colors.white.withValues(alpha: 0.06), Colors.transparent],
        ),
      ))),
      // Stegosaurus-back jagged plates along the top edge.
      Positioned(top: 0, left: 0, right: 0, height: 28,
        child: CustomPaint(painter: _ZigZagPainter(color: p.secondary, peaks: 9))),
      // Bottom: layered ground line with second jagged silhouette.
      Positioned(bottom: 22, left: 0, right: 0, height: 18,
        child: CustomPaint(painter: _ZigZagPainter(color: p.secondary.withValues(alpha: 0.6), peaks: 7, flip: true))),
      Positioned(bottom: 0, left: 0, right: 0, height: 24,
        child: CustomPaint(painter: _ZigZagPainter(color: p.secondary, peaks: 9, flip: true))),
      // Lush fern fronds at every corner.
      const Positioned(top: 22, left: -8,  child: _FernFrond(size: 96, lean: -0.1, alpha: 0.55)),
      const Positioned(top: 36, right: -12, child: _FernFrond(size: 88, lean: 0.5, alpha: 0.45, flip: true)),
      const Positioned(bottom: 28, left: -14, child: _FernFrond(size: 92, lean: -0.4, alpha: 0.50, mirror: true)),
      const Positioned(bottom: 38, right: -10, child: _FernFrond(size: 80, lean: 0.2, alpha: 0.55, flip: true, mirror: true)),
      // Volcanic rock clusters along the ground.
      Positioned(bottom: 24, left: 8,  child: _VolcanicRock(size: 36, color: Colors.black.withValues(alpha: 0.55))),
      Positioned(bottom: 28, left: 38, child: _VolcanicRock(size: 22, color: Colors.black.withValues(alpha: 0.40))),
      Positioned(bottom: 26, right: 18, child: _VolcanicRock(size: 30, color: Colors.black.withValues(alpha: 0.50))),
      // Big bold footprints scattered across the body.
      const Positioned(left: 16, top: 100, child: _DinoFootprint(size: 44, alpha: 0.22)),
      const Positioned(right: 14, top: 150, child: _DinoFootprint(size: 36, alpha: 0.18, flip: true)),
      const Positioned(left: 30, top: 230, child: _DinoFootprint(size: 28, alpha: 0.14)),
      const Positioned(right: 24, top: 280, child: _DinoFootprint(size: 38, alpha: 0.20, flip: true)),
      const Positioned(left: 18, bottom: 110, child: _DinoFootprint(size: 32, alpha: 0.18)),
      const Positioned(right: 18, bottom: 145, child: _DinoFootprint(size: 26, alpha: 0.16, flip: true)),
    ]);
  }
}

class _FernFrond extends StatelessWidget {
  /// Stylised fern frond — central stem with paired leaflets.
  /// `lean` rotates clockwise (radians-ish); `flip` mirrors horizontally;
  /// `mirror` flips vertically (for ground-anchored fronds).
  final double size;
  final double lean;
  final double alpha;
  final bool flip;
  final bool mirror;
  const _FernFrond({
    required this.size,
    required this.alpha,
    this.lean = 0,
    this.flip = false,
    this.mirror = false,
  });
  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: lean,
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()..scaleByDouble(flip ? -1.0 : 1.0, mirror ? -1.0 : 1.0, 1.0, 1.0),
        child: SizedBox(
          width: size, height: size * 1.6,
          child: CustomPaint(painter: _FernPainter(alpha: alpha)),
        ),
      ),
    );
  }
}

class _FernPainter extends CustomPainter {
  final double alpha;
  _FernPainter({required this.alpha});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF1F3A1A).withValues(alpha: alpha)
      ..style = PaintingStyle.fill;
    // Central stem
    final stem = Paint()
      ..color = const Color(0xFF3A5A2A).withValues(alpha: alpha + 0.1)
      ..strokeWidth = 2.5..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(size.width / 2, size.height), Offset(size.width / 2, 0), stem);
    // Leaflet pairs along the stem
    const pairs = 7;
    for (var i = 0; i < pairs; i++) {
      final t = (i + 0.4) / pairs; // 0.057..0.92
      final y = size.height * (1 - t);
      final w = size.width * (0.55 - 0.05 * i.abs() / pairs); // tapered tip
      // Left leaflet (curved teardrop)
      _drawLeaflet(canvas, paint, Offset(size.width / 2, y), w, true);
      // Right leaflet
      _drawLeaflet(canvas, paint, Offset(size.width / 2, y), w, false);
    }
  }
  void _drawLeaflet(Canvas canvas, Paint paint, Offset origin, double w, bool left) {
    final dir = left ? -1.0 : 1.0;
    final path = Path()
      ..moveTo(origin.dx, origin.dy)
      ..quadraticBezierTo(
        origin.dx + dir * w * 0.7, origin.dy - w * 0.3,
        origin.dx + dir * w, origin.dy - w * 0.05,
      )
      ..quadraticBezierTo(
        origin.dx + dir * w * 0.55, origin.dy + w * 0.15,
        origin.dx, origin.dy + 1,
      )
      ..close();
    canvas.drawPath(path, paint);
  }
  @override
  bool shouldRepaint(covariant _FernPainter old) => old.alpha != alpha;
}

class _VolcanicRock extends StatelessWidget {
  /// Irregular dark rounded blob suggesting a basalt boulder.
  final double size;
  final Color color;
  const _VolcanicRock({required this.size, required this.color});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size, height: size * 0.7,
      child: CustomPaint(painter: _BlobPainter(color: color)),
    );
  }
}

class _BlobPainter extends CustomPainter {
  final Color color;
  _BlobPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(size.width * 0.05, size.height * 0.7)
      ..quadraticBezierTo(0, size.height * 0.30, size.width * 0.30, size.height * 0.10)
      ..quadraticBezierTo(size.width * 0.55, -2, size.width * 0.78, size.height * 0.18)
      ..quadraticBezierTo(size.width, size.height * 0.40, size.width * 0.92, size.height * 0.85)
      ..quadraticBezierTo(size.width * 0.55, size.height * 1.05, size.width * 0.20, size.height * 0.92)
      ..close();
    canvas.drawPath(path, paint);
  }
  @override
  bool shouldRepaint(covariant _BlobPainter old) => old.color != color;
}

class _DinoFootprint extends StatelessWidget {
  final double size;
  final double alpha;
  final bool flip;
  const _DinoFootprint({required this.size, required this.alpha, this.flip = false});
  @override
  Widget build(BuildContext context) {
    final c = Colors.black.withValues(alpha: alpha);
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()..scaleByDouble(flip ? -1.0 : 1.0, 1.0, 1.0, 1.0),
      child: SizedBox(
        width: size, height: size * 1.1,
        child: Stack(children: [
          // Pad (heel)
          Positioned(
            bottom: 0, left: size * 0.15,
            child: Container(
              width: size * 0.7, height: size * 0.55,
              decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(size * 0.3)),
            ),
          ),
          // Three claws
          Positioned(top: 0, left: 0,
            child: Container(width: size * 0.2, height: size * 0.4,
              decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(size * 0.15)))),
          Positioned(top: 0, left: size * 0.4,
            child: Container(width: size * 0.2, height: size * 0.45,
              decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(size * 0.15)))),
          Positioned(top: 4, left: size * 0.78,
            child: Container(width: size * 0.18, height: size * 0.38,
              decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(size * 0.15)))),
        ]),
      ),
    );
  }
}

class _ZigZagPainter extends CustomPainter {
  final Color color;
  final int peaks;
  final bool flip;
  _ZigZagPainter({required this.color, required this.peaks, this.flip = false});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..style = PaintingStyle.fill;
    final path = Path();
    final step = size.width / peaks;
    if (!flip) {
      path.moveTo(0, size.height);
      for (var i = 0; i < peaks; i++) {
        path.lineTo(step * i + step / 2, 0);
        path.lineTo(step * (i + 1), size.height);
      }
    } else {
      path.moveTo(0, 0);
      for (var i = 0; i < peaks; i++) {
        path.lineTo(step * i + step / 2, size.height);
        path.lineTo(step * (i + 1), 0);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }
  @override
  bool shouldRepaint(covariant _ZigZagPainter old) =>
      old.color != color || old.peaks != peaks || old.flip != flip;
}

// ── 2. Space ───────────────────────────────────────────────────
class _SpaceDecor extends StatelessWidget {
  final _KidsPalette p;
  const _SpaceDecor({required this.p});

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      // Two cosmic glow patches — top-right warm + bottom-left cool — layered
      // for depth without obscuring the central QR.
      Positioned(top: -50, right: -50, child: Container(
        width: 180, height: 180,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [
            p.accent.withValues(alpha: 0.50), Colors.transparent,
          ]),
        ),
      )),
      Positioned(bottom: -60, left: -60, child: Container(
        width: 200, height: 200,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [
            p.secondary.withValues(alpha: 0.40), Colors.transparent,
          ]),
        ),
      )),
      // 36 deterministic stars at varied sizes — denser top + bottom edges.
      ..._scatterStars(),
      // Constellation cluster (5 dots + connecting lines) mid-left.
      Positioned(top: 175, left: 14, child: SizedBox(
        width: 60, height: 50,
        child: CustomPaint(painter: _ConstellationPainter()),
      )),
      // Big Saturn-style planet bottom-right, behind the brand strip area.
      Positioned(bottom: 70, right: -10, child: _SpacePlanet(
        bodySize: 80, ringWidth: 130, accent: p.accent, secondary: p.secondary,
      )),
      // Smaller distant planet top-left.
      Positioned(top: 90, left: 18, child: _SpacePlanet(
        bodySize: 26, ringWidth: 0, accent: const Color(0xFFFF6B6B), secondary: const Color(0xFFB23A48),
      )),
      // Three meteor streaks at different angles.
      const Positioned(top: 60,  right: 36, child: _MeteorStreak(length: 70, angle: -0.6)),
      const Positioned(top: 230, left: 60, child: _MeteorStreak(length: 50, angle: -0.4, alpha: 0.55)),
      const Positioned(top: 320, right: 50, child: _MeteorStreak(length: 60, angle: -0.7, alpha: 0.65)),
      // Star bursts (bigger sparkles) for variation.
      const Positioned(top: 150, right: 24, child: Icon(Icons.auto_awesome, size: 16, color: Color(0xCCFFD700))),
      const Positioned(bottom: 180, left: 30, child: Icon(Icons.auto_awesome, size: 14, color: Color(0xAAFFFFFF))),
      const Positioned(top: 280, left: 24, child: Icon(Icons.auto_awesome, size: 12, color: Color(0xAAFFD700))),
    ]);
  }

  List<Widget> _scatterStars() {
    // Deterministic scatter so the layout doesn't jitter across rebuilds.
    const positions = <(double dx, double dy, double size, double alpha)>[
      (0.05, 0.04, 4, 0.90), (0.18, 0.07, 2, 0.55), (0.30, 0.03, 3, 0.75),
      (0.42, 0.09, 2, 0.50), (0.55, 0.04, 4, 0.85), (0.68, 0.11, 3, 0.70),
      (0.78, 0.06, 2, 0.60), (0.88, 0.13, 3, 0.65), (0.96, 0.20, 2, 0.55),
      (0.10, 0.18, 2, 0.50), (0.25, 0.22, 3, 0.70), (0.45, 0.24, 2, 0.55),
      (0.62, 0.28, 4, 0.85), (0.82, 0.30, 2, 0.50), (0.05, 0.42, 3, 0.65),
      (0.40, 0.48, 2, 0.45), (0.92, 0.45, 3, 0.70), (0.10, 0.55, 2, 0.50),
      (0.30, 0.60, 2, 0.45), (0.50, 0.66, 3, 0.65), (0.70, 0.62, 2, 0.50),
      (0.85, 0.70, 4, 0.80), (0.15, 0.74, 3, 0.65), (0.35, 0.78, 2, 0.50),
      (0.55, 0.82, 3, 0.70), (0.78, 0.86, 2, 0.55), (0.25, 0.90, 4, 0.85),
      (0.45, 0.94, 2, 0.50), (0.65, 0.92, 3, 0.65), (0.92, 0.96, 2, 0.55),
      (0.08, 0.36, 2, 0.50), (0.22, 0.32, 3, 0.65), (0.72, 0.38, 2, 0.50),
      (0.05, 0.85, 3, 0.70), (0.40, 0.36, 2, 0.45), (0.60, 0.18, 2, 0.55),
    ];
    return [
      for (final pos in positions)
        Align(
          alignment: Alignment(pos.$1 * 2 - 1, pos.$2 * 2 - 1),
          child: Container(
            width: pos.$3, height: pos.$3,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: pos.$4),
              boxShadow: pos.$3 >= 3 ? [BoxShadow(
                color: Colors.white.withValues(alpha: pos.$4 * 0.4),
                blurRadius: 4,
              )] : null,
            ),
          ),
        ),
    ];
  }
}

class _SpacePlanet extends StatelessWidget {
  final double bodySize;
  final double ringWidth;
  final Color accent;
  final Color secondary;
  const _SpacePlanet({
    required this.bodySize, required this.ringWidth,
    required this.accent, required this.secondary,
  });
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: ringWidth > 0 ? ringWidth : bodySize,
      height: ringWidth > 0 ? ringWidth * 0.45 : bodySize,
      child: Stack(alignment: Alignment.center, children: [
        if (ringWidth > 0)
          Transform.rotate(
            angle: -0.35,
            child: Container(
              width: ringWidth, height: ringWidth * 0.18,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(ringWidth),
                border: Border.all(
                  color: secondary.withValues(alpha: 0.65), width: 4,
                ),
              ),
            ),
          ),
        Container(
          width: bodySize, height: bodySize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [accent, secondary],
              begin: Alignment.topLeft, end: Alignment.bottomRight,
            ),
            boxShadow: [BoxShadow(
              color: accent.withValues(alpha: 0.45),
              blurRadius: 18, spreadRadius: 2,
            )],
          ),
        ),
      ]),
    );
  }
}

class _MeteorStreak extends StatelessWidget {
  final double length;
  final double angle; // radians, typically negative for top-right→bottom-left
  final double alpha;
  const _MeteorStreak({required this.length, required this.angle, this.alpha = 0.85});
  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: angle,
      child: Container(
        width: length, height: 2,
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [
            Colors.transparent,
            Colors.white.withValues(alpha: alpha),
          ]),
          borderRadius: BorderRadius.circular(1),
          boxShadow: [BoxShadow(
            color: Colors.white.withValues(alpha: alpha * 0.5),
            blurRadius: 4,
          )],
        ),
      ),
    );
  }
}

class _ConstellationPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final dot = Paint()..color = Colors.white.withValues(alpha: 0.85);
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.30)
      ..strokeWidth = 1..style = PaintingStyle.stroke;
    // 5 stars forming a loose 'W' (a kid's-scale Cassiopeia).
    final pts = [
      Offset(size.width * 0.08, size.height * 0.20),
      Offset(size.width * 0.30, size.height * 0.75),
      Offset(size.width * 0.50, size.height * 0.30),
      Offset(size.width * 0.72, size.height * 0.80),
      Offset(size.width * 0.95, size.height * 0.25),
    ];
    for (var i = 0; i < pts.length - 1; i++) {
      canvas.drawLine(pts[i], pts[i + 1], line);
    }
    for (final p in pts) {
      canvas.drawCircle(p, 2.2, dot);
    }
  }
  @override
  bool shouldRepaint(covariant _ConstellationPainter old) => false;
}

// ── 3. Unicorns & Rainbows ─────────────────────────────────────
class _UnicornsDecor extends StatelessWidget {
  final _KidsPalette p;
  const _UnicornsDecor({required this.p});

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      // Pastel sky gradient overlay — softens the bg towards mint at bottom.
      Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [
            Color(0x33FFD0E5), // pink wash top
            Color(0x33D4F5E0), // mint wash bottom
          ],
        ),
      ))),
      // Big rainbow arc spanning bottom-corner to upper-right — the
      // negative offset puts the arc center off-screen so the visible
      // sweep covers the full lower-right two-thirds of the card.
      Positioned(
        bottom: -160, right: -160,
        child: SizedBox(
          width: 480, height: 480,
          child: CustomPaint(painter: _RainbowArcPainter()),
        ),
      ),
      // Cloud puffs scattered top-to-bottom for depth.
      Positioned(top: 14,  left: -8,  child: _Cloud(width: 80, height: 28, alpha: 0.95)),
      Positioned(top: 28,  right: 18, child: _Cloud(width: 64, height: 24, alpha: 0.85)),
      Positioned(top: 130, left: -14, child: _Cloud(width: 70, height: 26, alpha: 0.55)),
      Positioned(bottom: 200, right: -10, child: _Cloud(width: 76, height: 26, alpha: 0.55)),
      Positioned(bottom: 50, left: 14, child: _Cloud(width: 60, height: 22, alpha: 0.80)),
      // Dense sparkle field — rotated stars + plus marks at varied sizes.
      const Positioned(top: 80,  right: 36, child: Icon(Icons.auto_awesome, size: 22, color: Color(0xDDFFD700))),
      const Positioned(top: 110, left: 90,  child: Icon(Icons.auto_awesome, size: 14, color: Color(0xAAFFB6E1))),
      const Positioned(top: 160, right: 80, child: Icon(Icons.auto_awesome, size: 12, color: Color(0xAAB07FE0))),
      const Positioned(top: 210, left: 30,  child: Icon(Icons.auto_awesome, size: 18, color: Color(0xCCFFD700))),
      const Positioned(top: 250, right: 30, child: Icon(Icons.auto_awesome, size: 14, color: Color(0xAA9C7FD4))),
      const Positioned(top: 290, left: 70,  child: Icon(Icons.auto_awesome, size: 16, color: Color(0xBBFFB6E1))),
      const Positioned(bottom: 150, left: 24,  child: Icon(Icons.auto_awesome, size: 18, color: Color(0xCCFFD700))),
      const Positioned(bottom: 100, right: 60, child: Icon(Icons.auto_awesome, size: 12, color: Color(0xAA9C7FD4))),
      const Positioned(bottom: 80,  left: 90,  child: Icon(Icons.auto_awesome, size: 14, color: Color(0xBBFFB6E1))),
      // Tiny dot sparkles for filler density.
      Positioned(top: 95,  left: 30,  child: _MicroSparkle(color: Colors.white.withValues(alpha: 0.85))),
      Positioned(top: 175, left: 60,  child: _MicroSparkle(color: const Color(0xFFFFB6E1).withValues(alpha: 0.9))),
      Positioned(top: 320, right: 70, child: _MicroSparkle(color: const Color(0xFFFFD700).withValues(alpha: 0.9))),
      Positioned(bottom: 220, left: 45, child: _MicroSparkle(color: Colors.white.withValues(alpha: 0.85))),
      Positioned(bottom: 60, right: 30, child: _MicroSparkle(color: const Color(0xFF9C7FD4).withValues(alpha: 0.9))),
    ]);
  }
}

/// Tiny 4-point sparkle — small enough to layer between Material auto_awesome
/// icons without crowding them.
class _MicroSparkle extends StatelessWidget {
  final Color color;
  const _MicroSparkle({required this.color});
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 6, height: 6,
    child: CustomPaint(painter: _MicroSparklePainter(color: color)),
  );
}

class _MicroSparklePainter extends CustomPainter {
  final Color color;
  _MicroSparklePainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..strokeWidth = 1.2..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(size.width / 2, 0), Offset(size.width / 2, size.height), paint);
    canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), paint);
  }
  @override
  bool shouldRepaint(covariant _MicroSparklePainter old) => old.color != color;
}

class _Cloud extends StatelessWidget {
  final double width;
  final double height;
  final double alpha;
  const _Cloud({required this.width, required this.height, required this.alpha});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width, height: height,
      child: Stack(children: [
        Positioned(left: width * 0.15, bottom: 0,
          child: Container(width: width * 0.7, height: height * 0.7,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: alpha),
              borderRadius: BorderRadius.circular(height),
            ))),
        Positioned(left: 0, bottom: 0,
          child: Container(width: height, height: height,
            decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: alpha)))),
        Positioned(right: 0, bottom: 0,
          child: Container(width: height, height: height,
            decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: alpha)))),
        Positioned(left: width * 0.30, top: 0,
          child: Container(width: height * 0.85, height: height * 0.85,
            decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: alpha)))),
      ]),
    );
  }
}

class _RainbowArcPainter extends CustomPainter {
  static const _bands = <Color>[
    Color(0xFFE91E63), Color(0xFFFF9800), Color(0xFFFFEB3B),
    Color(0xFF66BB6A), Color(0xFF42A5F5), Color(0xFFAB47BC),
  ];
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width;
    final cy = size.height;
    var radius = size.width * 0.95;
    const bandWidth = 12.0;
    for (final c in _bands) {
      final paint = Paint()
        ..color = c.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = bandWidth;
      canvas.drawArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: radius),
        math.pi, math.pi / 2, false, paint,
      );
      radius -= bandWidth + 2;
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

// ── 4. Sports ──────────────────────────────────────────────────
class _SportsDecor extends StatelessWidget {
  final _KidsPalette p;
  const _SportsDecor({required this.p});

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      // Bold diagonal color blocks — primary accent stripes crossing the
      // whole card for stadium-banner energy.
      Positioned.fill(
        child: CustomPaint(painter: _SportsBlocksPainter(
          accent: p.accent, secondary: p.secondary,
        )),
      ),
      // Top: triangular pennant flag string.
      Positioned(top: 6, left: 0, right: 0, height: 38,
        child: CustomPaint(painter: _PennantsPainter(color1: p.accent, color2: p.secondary))),
      // Second pennant string mid-card to amplify the stadium feel.
      Positioned(top: 95, left: 0, right: 0, height: 26,
        child: Opacity(
          opacity: 0.55,
          child: CustomPaint(painter: _PennantsPainter(color1: p.secondary, color2: p.accent)),
        ),
      ),
      // Big trophy silhouette behind the QR area for theme presence.
      Positioned(
        top: 130, left: 0, right: 0,
        child: Center(child: SizedBox(
          width: 130, height: 160,
          child: CustomPaint(painter: _TrophyPainter(
            color: p.accent.withValues(alpha: 0.15),
          )),
        )),
      ),
      // Confetti — small rotated rectangles scattered everywhere.
      ..._scatterConfetti(p),
      // Bottom: chevron stripe pattern.
      Positioned(bottom: 0, left: 0, right: 0, height: 22,
        child: CustomPaint(painter: _ChevronPainter(color: p.accent))),
    ]);
  }

  List<Widget> _scatterConfetti(_KidsPalette p) {
    const positions = <(double dx, double dy, double rot, int colorIdx)>[
      (0.10, 0.18, 0.4, 0), (0.30, 0.14, -0.6, 1), (0.55, 0.22, 0.3, 2),
      (0.78, 0.18, -0.5, 0), (0.92, 0.30, 0.7, 1), (0.18, 0.42, -0.3, 2),
      (0.45, 0.48, 0.5, 0), (0.72, 0.50, -0.4, 1), (0.10, 0.62, 0.6, 2),
      (0.38, 0.66, -0.5, 0), (0.66, 0.72, 0.4, 1), (0.92, 0.78, -0.3, 2),
      (0.20, 0.82, 0.5, 0), (0.50, 0.88, -0.4, 1), (0.80, 0.92, 0.6, 2),
    ];
    return [
      for (final pos in positions)
        Align(
          alignment: Alignment(pos.$1 * 2 - 1, pos.$2 * 2 - 1),
          child: Transform.rotate(
            angle: pos.$3,
            child: Container(
              width: 10, height: 4,
              color: switch (pos.$4) {
                0 => p.accent,
                1 => p.secondary,
                _ => Colors.white,
              }.withValues(alpha: 0.85),
            ),
          ),
        ),
    ];
  }
}

class _SportsBlocksPainter extends CustomPainter {
  final Color accent;
  final Color secondary;
  _SportsBlocksPainter({required this.accent, required this.secondary});
  @override
  void paint(Canvas canvas, Size size) {
    // Two diagonal stripes — accent thicker, secondary thinner, layered for
    // depth without overpowering the central QR area.
    final p1 = Paint()..color = accent.withValues(alpha: 0.18);
    final p2 = Paint()..color = secondary.withValues(alpha: 0.16);
    canvas.drawPath(
      Path()
        ..moveTo(0, size.height * 0.30)
        ..lineTo(size.width, size.height * 0.10)
        ..lineTo(size.width, size.height * 0.22)
        ..lineTo(0, size.height * 0.42)
        ..close(),
      p1,
    );
    canvas.drawPath(
      Path()
        ..moveTo(0, size.height * 0.55)
        ..lineTo(size.width, size.height * 0.40)
        ..lineTo(size.width, size.height * 0.48)
        ..lineTo(0, size.height * 0.63)
        ..close(),
      p2,
    );
  }
  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class _TrophyPainter extends CustomPainter {
  final Color color;
  _TrophyPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..strokeWidth = 3..style = PaintingStyle.stroke;
    final w = size.width;
    final h = size.height;
    // Cup body
    final cup = Path()
      ..moveTo(w * 0.18, h * 0.04)
      ..lineTo(w * 0.82, h * 0.04)
      ..lineTo(w * 0.78, h * 0.50)
      ..quadraticBezierTo(w * 0.50, h * 0.65, w * 0.22, h * 0.50)
      ..close();
    canvas.drawPath(cup, paint);
    canvas.drawPath(cup, stroke);
    // Handles
    canvas.drawArc(
      Rect.fromLTWH(-w * 0.12, h * 0.06, w * 0.30, h * 0.30),
      -math.pi / 2, math.pi, false, stroke,
    );
    canvas.drawArc(
      Rect.fromLTWH(w * 0.82, h * 0.06, w * 0.30, h * 0.30),
      -math.pi / 2, -math.pi, false, stroke,
    );
    // Stem
    canvas.drawRect(Rect.fromLTWH(w * 0.42, h * 0.55, w * 0.16, h * 0.20), paint);
    // Base
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.20, h * 0.80, w * 0.60, h * 0.18),
        const Radius.circular(4),
      ),
      paint,
    );
    // Cup highlight stripe
    canvas.drawRect(
      Rect.fromLTWH(w * 0.30, h * 0.20, w * 0.40, h * 0.04),
      Paint()..color = color.withValues(alpha: 0.25),
    );
  }
  @override
  bool shouldRepaint(covariant _TrophyPainter old) => old.color != color;
}

class _PennantsPainter extends CustomPainter {
  final Color color1;
  final Color color2;
  _PennantsPainter({required this.color1, required this.color2});
  @override
  void paint(Canvas canvas, Size size) {
    final string = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..strokeWidth = 1.2..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(0, 4), Offset(size.width, 4), string);
    const flags = 8;
    final step = size.width / flags;
    for (var i = 0; i < flags; i++) {
      final color = i.isEven ? color1 : color2;
      final paint = Paint()..color = color;
      final left = step * i + step * 0.15;
      final right = step * (i + 1) - step * 0.15;
      final mid = (left + right) / 2;
      final path = Path()
        ..moveTo(left, 4)
        ..lineTo(right, 4)
        ..lineTo(mid, size.height - 4)
        ..close();
      canvas.drawPath(path, paint);
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class _ChevronPainter extends CustomPainter {
  final Color color;
  _ChevronPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..style = PaintingStyle.fill;
    const peaks = 8;
    final step = size.width / peaks;
    final path = Path()..moveTo(0, size.height);
    for (var i = 0; i < peaks; i++) {
      path.lineTo(step * i + step / 2, 4);
      path.lineTo(step * (i + 1), size.height);
    }
    path.lineTo(size.width, size.height);
    path.close();
    canvas.drawPath(path, paint);
  }
  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

// ── 5. Animals ─────────────────────────────────────────────────
class _AnimalsDecor extends StatelessWidget {
  final _KidsPalette p;
  const _AnimalsDecor({required this.p});

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      // Big tropical leaves filling each corner — palm-fan silhouettes
      // anchor the safari feel.
      const Positioned(top: -18, left: -22, child: _PalmLeaf(size: 110, lean: -0.5, alpha: 0.40)),
      const Positioned(top: -10, right: -30, child: _PalmLeaf(size: 100, lean: 0.6,  alpha: 0.45, flip: true)),
      const Positioned(bottom: -22, left: -28, child: _PalmLeaf(size: 110, lean: 0.7, alpha: 0.40, mirror: true)),
      const Positioned(bottom: -16, right: -22, child: _PalmLeaf(size: 100, lean: -0.5, alpha: 0.45, flip: true, mirror: true)),
      // Animal silhouettes peeking from edges. Lion mane bottom-left,
      // bear ears top-center off-screen, elephant ear right.
      Positioned(top: -30, left: 70, child: _BearEars(size: 70, color: Colors.black.withValues(alpha: 0.18))),
      Positioned(top: 230, right: -28, child: _ElephantEar(size: 90, color: Colors.black.withValues(alpha: 0.18))),
      Positioned(bottom: -10, right: 60, child: _LionMane(size: 90, accent: p.accent.withValues(alpha: 0.30))),
      // Dense paw-print field across the body.
      Positioned(top: 100, left: 24, child: _PawPrint(size: 22, color: p.accent, alpha: 0.45)),
      Positioned(top: 130, right: 30, child: _PawPrint(size: 18, color: p.secondary, alpha: 0.45)),
      Positioned(top: 175, left: 60, child: _PawPrint(size: 16, color: p.accent, alpha: 0.40)),
      Positioned(top: 220, right: 70, child: _PawPrint(size: 20, color: p.secondary, alpha: 0.45)),
      Positioned(top: 280, left: 30, child: _PawPrint(size: 18, color: p.accent, alpha: 0.40)),
      Positioned(bottom: 180, right: 24, child: _PawPrint(size: 22, color: p.secondary, alpha: 0.50)),
      Positioned(bottom: 130, left: 50, child: _PawPrint(size: 16, color: p.accent, alpha: 0.40)),
      Positioned(bottom: 80, right: 60, child: _PawPrint(size: 18, color: p.secondary, alpha: 0.45)),
      // Polka dots + small leaf accents scattered for filler density.
      Positioned(top: 110, right: 80, child: _PolkaDot(size: 8, color: p.accent.withValues(alpha: 0.40))),
      Positioned(top: 200, left: 90, child: _PolkaDot(size: 6, color: p.secondary.withValues(alpha: 0.40))),
      Positioned(bottom: 200, left: 90, child: _PolkaDot(size: 10, color: p.accent.withValues(alpha: 0.35))),
      const Positioned(top: 250, right: 40, child: Icon(Icons.eco, size: 22, color: Color(0xAA6B8B5E))),
      const Positioned(bottom: 110, left: 22, child: Icon(Icons.eco, size: 18, color: Color(0xAA6B8B5E))),
      const Positioned(top: 90, right: 50, child: Icon(Icons.eco, size: 16, color: Color(0x886B8B5E))),
    ]);
  }
}

class _PalmLeaf extends StatelessWidget {
  final double size;
  final double lean;
  final double alpha;
  final bool flip;
  final bool mirror;
  const _PalmLeaf({
    required this.size, required this.alpha,
    this.lean = 0, this.flip = false, this.mirror = false,
  });
  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: lean,
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()..scaleByDouble(flip ? -1.0 : 1.0, mirror ? -1.0 : 1.0, 1.0, 1.0),
        child: SizedBox(
          width: size, height: size,
          child: CustomPaint(painter: _PalmLeafPainter(alpha: alpha)),
        ),
      ),
    );
  }
}

class _PalmLeafPainter extends CustomPainter {
  final double alpha;
  _PalmLeafPainter({required this.alpha});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF6B8B5E).withValues(alpha: alpha)
      ..style = PaintingStyle.fill;
    // Fan of 7 leaflet "fingers" radiating from the bottom-left corner.
    const fingers = 7;
    final origin = Offset(size.width * 0.05, size.height * 0.95);
    for (var i = 0; i < fingers; i++) {
      final t = i / (fingers - 1); // 0..1
      final angle = -math.pi / 2 - (math.pi / 4) + t * (math.pi / 2);
      final len = size.width * (0.85 - 0.06 * (i - fingers / 2).abs());
      final tip = origin + Offset(math.cos(angle) * len, math.sin(angle) * len);
      final perp = Offset(-math.sin(angle), math.cos(angle));
      final w = len * 0.12;
      final path = Path()
        ..moveTo(origin.dx + perp.dx * w * 0.5, origin.dy + perp.dy * w * 0.5)
        ..quadraticBezierTo(
          (origin.dx + tip.dx) / 2 + perp.dx * w,
          (origin.dy + tip.dy) / 2 + perp.dy * w,
          tip.dx, tip.dy,
        )
        ..quadraticBezierTo(
          (origin.dx + tip.dx) / 2 - perp.dx * w,
          (origin.dy + tip.dy) / 2 - perp.dy * w,
          origin.dx - perp.dx * w * 0.5, origin.dy - perp.dy * w * 0.5,
        )
        ..close();
      canvas.drawPath(path, paint);
    }
  }
  @override
  bool shouldRepaint(covariant _PalmLeafPainter old) => old.alpha != alpha;
}

class _BearEars extends StatelessWidget {
  final double size;
  final Color color;
  const _BearEars({required this.size, required this.color});
  @override
  Widget build(BuildContext context) => SizedBox(
    width: size, height: size * 0.6,
    child: Stack(children: [
      Positioned(left: 0, top: size * 0.05,
        child: Container(width: size * 0.45, height: size * 0.45,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color))),
      Positioned(right: 0, top: size * 0.05,
        child: Container(width: size * 0.45, height: size * 0.45,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color))),
    ]),
  );
}

class _ElephantEar extends StatelessWidget {
  final double size;
  final Color color;
  const _ElephantEar({required this.size, required this.color});
  @override
  Widget build(BuildContext context) => SizedBox(
    width: size, height: size,
    child: CustomPaint(painter: _ElephantEarPainter(color: color)),
  );
}

class _ElephantEarPainter extends CustomPainter {
  final Color color;
  _ElephantEarPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(size.width * 0.2, size.height * 0.10)
      ..quadraticBezierTo(size.width * 1.05, size.height * 0.20, size.width * 0.85, size.height * 0.85)
      ..quadraticBezierTo(size.width * 0.4, size.height * 1.05, size.width * 0.10, size.height * 0.55)
      ..quadraticBezierTo(size.width * -0.05, size.height * 0.20, size.width * 0.2, size.height * 0.10)
      ..close();
    canvas.drawPath(path, paint);
  }
  @override
  bool shouldRepaint(covariant _ElephantEarPainter old) => old.color != color;
}

class _LionMane extends StatelessWidget {
  final double size;
  final Color accent;
  const _LionMane({required this.size, required this.accent});
  @override
  Widget build(BuildContext context) => SizedBox(
    width: size, height: size * 0.7,
    child: CustomPaint(painter: _LionManePainter(accent: accent)),
  );
}

class _LionManePainter extends CustomPainter {
  final Color accent;
  _LionManePainter({required this.accent});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = accent..style = PaintingStyle.fill;
    final cx = size.width / 2;
    final cy = size.height * 0.95;
    // 9 mane "tufts" radiating outward — half-circles around the head.
    const tufts = 9;
    final r = size.width * 0.42;
    for (var i = 0; i < tufts; i++) {
      final t = i / (tufts - 1);
      final angle = -math.pi + t * math.pi;
      final x = cx + math.cos(angle) * r;
      final y = cy + math.sin(angle) * r;
      canvas.drawCircle(Offset(x, y), r * 0.32, paint);
    }
    // Face circle (slightly darker)
    canvas.drawCircle(Offset(cx, cy), r * 0.78,
        Paint()..color = accent.withValues(alpha: accent.a + 0.10));
  }
  @override
  bool shouldRepaint(covariant _LionManePainter old) => old.accent != accent;
}

class _PawPrint extends StatelessWidget {
  final double size;
  final Color color;
  final double alpha;
  const _PawPrint({required this.size, required this.color, required this.alpha});
  @override
  Widget build(BuildContext context) {
    final c = color.withValues(alpha: alpha);
    return SizedBox(
      width: size, height: size,
      child: Stack(children: [
        // Pad
        Positioned(bottom: 0, left: size * 0.2,
          child: Container(width: size * 0.6, height: size * 0.45,
            decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(size)))),
        // Toes
        Positioned(top: 0, left: size * 0.05,
          child: Container(width: size * 0.22, height: size * 0.28,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle))),
        Positioned(top: size * -0.05, left: size * 0.39,
          child: Container(width: size * 0.22, height: size * 0.28,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle))),
        Positioned(top: 0, right: size * 0.05,
          child: Container(width: size * 0.22, height: size * 0.28,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle))),
      ]),
    );
  }
}

class _PolkaDot extends StatelessWidget {
  final double size;
  final Color color;
  const _PolkaDot({required this.size, required this.color});
  @override
  Widget build(BuildContext context) => Container(
    width: size, height: size,
    decoration: BoxDecoration(shape: BoxShape.circle, color: color),
  );
}

// ── 6. Circus & Carnival ───────────────────────────────────────
class _CircusDecor extends StatelessWidget {
  final _KidsPalette p;
  const _CircusDecor({required this.p});

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      // Bold red + white vertical stripes filling the entire card.
      Positioned.fill(
        child: CustomPaint(painter: _StripesPainter(
          stripe1: p.bg1, stripe2: p.secondary, count: 14,
        )),
      ),
      // Two diagonal spotlight beams from the top corners.
      Positioned.fill(child: CustomPaint(painter: _SpotlightPainter(color: p.accent))),
      // Big top tent peaks across the top edge.
      Positioned(top: 0, left: 0, right: 0, height: 44,
        child: CustomPaint(painter: _TentPeaksPainter(color: p.accent))),
      // Bunting strung below the tent peaks.
      Positioned(top: 50, left: 0, right: 0, height: 26,
        child: CustomPaint(painter: _PennantsPainter(color1: p.accent, color2: p.secondary))),
      // Yellow stars sprinkled across the body — denser than before.
      const Positioned(top: 100, right: 26, child: Icon(Icons.star, size: 22, color: Color(0xDDFFD23F))),
      const Positioned(top: 130, left: 30,  child: Icon(Icons.star, size: 14, color: Color(0xBBFFD23F))),
      const Positioned(top: 175, right: 80, child: Icon(Icons.star, size: 16, color: Color(0xCCFFD23F))),
      const Positioned(top: 220, left: 60,  child: Icon(Icons.star, size: 12, color: Color(0xAAFFD23F))),
      const Positioned(top: 270, right: 50, child: Icon(Icons.star, size: 18, color: Color(0xCCFFD23F))),
      const Positioned(bottom: 170, left: 24, child: Icon(Icons.star, size: 14, color: Color(0xBBFFD23F))),
      const Positioned(bottom: 130, right: 22, child: Icon(Icons.star, size: 20, color: Color(0xDDFFD23F))),
      const Positioned(bottom: 90,  left: 70, child: Icon(Icons.star, size: 12, color: Color(0xAAFFD23F))),
      // Bottom bunting.
      Positioned(bottom: 8, left: 0, right: 0, height: 24,
        child: CustomPaint(painter: _PennantsPainter(color1: p.secondary, color2: p.accent))),
    ]);
  }
}

class _SpotlightPainter extends CustomPainter {
  final Color color;
  _SpotlightPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color.withValues(alpha: 0.10);
    // Left spotlight beam — triangular fan from top-left corner.
    canvas.drawPath(
      Path()
        ..moveTo(0, 0)
        ..lineTo(size.width * 0.55, 0)
        ..lineTo(size.width * 0.10, size.height * 0.85)
        ..lineTo(0, size.height * 0.40)
        ..close(),
      paint,
    );
    // Right spotlight beam.
    canvas.drawPath(
      Path()
        ..moveTo(size.width, 0)
        ..lineTo(size.width * 0.45, 0)
        ..lineTo(size.width * 0.90, size.height * 0.85)
        ..lineTo(size.width, size.height * 0.40)
        ..close(),
      paint,
    );
  }
  @override
  bool shouldRepaint(covariant _SpotlightPainter old) => old.color != color;
}

class _StripesPainter extends CustomPainter {
  final Color stripe1;
  final Color stripe2;
  final int count;
  _StripesPainter({required this.stripe1, required this.stripe2, required this.count});
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width / count;
    for (var i = 0; i < count; i++) {
      final paint = Paint()..color = i.isEven ? stripe1 : stripe2.withValues(alpha: 0.85);
      canvas.drawRect(Rect.fromLTWH(w * i, 0, w + 0.5, size.height), paint);
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class _TentPeaksPainter extends CustomPainter {
  final Color color;
  _TentPeaksPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const peaks = 5;
    final step = size.width / peaks;
    final path = Path()..moveTo(0, size.height);
    for (var i = 0; i < peaks; i++) {
      path.lineTo(step * i + step / 2, 0);
      path.lineTo(step * (i + 1), size.height);
    }
    path.close();
    canvas.drawPath(path, paint);
    // Flag on top of the center peak
    final flag = Paint()..color = Colors.white;
    final cx = size.width / 2;
    canvas.drawRect(Rect.fromLTWH(cx - 1, -10, 2, 10), Paint()..color = color);
    final flagPath = Path()
      ..moveTo(cx, -10)
      ..lineTo(cx + 8, -7)
      ..lineTo(cx, -4)
      ..close();
    canvas.drawPath(flagPath, flag);
  }
  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

// ── 7. Mermaids & Ocean ────────────────────────────────────────
class _MermaidsDecor extends StatelessWidget {
  final _KidsPalette p;
  const _MermaidsDecor({required this.p});

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      // Layered waves: 2 at top, 3 at bottom for a sea-floor feel.
      Positioned(top: -8, left: 0, right: 0, height: 50,
        child: CustomPaint(painter: _WavePainter(color: p.secondary.withValues(alpha: 0.45)))),
      Positioned(top: 28, left: 0, right: 0, height: 42,
        child: CustomPaint(painter: _WavePainter(color: p.secondary.withValues(alpha: 0.30)))),
      Positioned(bottom: 48, left: 0, right: 0, height: 56,
        child: CustomPaint(painter: _WavePainter(color: p.accent.withValues(alpha: 0.35), flip: true))),
      Positioned(bottom: 22, left: 0, right: 0, height: 50,
        child: CustomPaint(painter: _WavePainter(color: p.secondary.withValues(alpha: 0.55), flip: true))),
      Positioned(bottom: 0, left: 0, right: 0, height: 40,
        child: CustomPaint(painter: _WavePainter(color: p.secondary.withValues(alpha: 0.75), flip: true))),
      // Seaweed silhouettes hugging both edges.
      const Positioned(bottom: 30, left: 4,   child: _Seaweed(height: 110, alpha: 0.45)),
      const Positioned(bottom: 30, left: 22,  child: _Seaweed(height: 80,  alpha: 0.35, flip: true)),
      const Positioned(bottom: 30, right: 6,  child: _Seaweed(height: 100, alpha: 0.45, flip: true)),
      const Positioned(bottom: 30, right: 24, child: _Seaweed(height: 70,  alpha: 0.35)),
      // Coral cluster nestled between the bottom waves.
      Positioned(bottom: 28, left: 0, right: 0, child: Center(child: _Coral(
        size: 80, color: p.accent.withValues(alpha: 0.55),
      ))),
      // Many bubbles rising — varied sizes, scattered horizontally.
      const Positioned(top: 80, left: 30, child: _Bubble(size: 16, alpha: 0.55)),
      const Positioned(top: 110, right: 50, child: _Bubble(size: 10, alpha: 0.50)),
      const Positioned(top: 150, left: 60, child: _Bubble(size: 12, alpha: 0.50)),
      const Positioned(top: 180, right: 30, child: _Bubble(size: 18, alpha: 0.45)),
      const Positioned(top: 230, left: 26, child: _Bubble(size: 14, alpha: 0.55)),
      const Positioned(top: 260, right: 70, child: _Bubble(size: 8,  alpha: 0.60)),
      const Positioned(top: 300, left: 50, child: _Bubble(size: 22, alpha: 0.40)),
      const Positioned(top: 340, right: 40, child: _Bubble(size: 12, alpha: 0.55)),
      const Positioned(bottom: 180, right: 80, child: _Bubble(size: 16, alpha: 0.50)),
      const Positioned(bottom: 140, left: 48, child: _Bubble(size: 10, alpha: 0.55)),
      // Shimmer dots — a couple of bright sparkles for "underwater shine".
      const Positioned(top: 100, left: 80, child: Icon(Icons.auto_awesome, size: 14, color: Color(0xAAFFFFFF))),
      const Positioned(top: 200, right: 90, child: Icon(Icons.auto_awesome, size: 12, color: Color(0xAAFFFFFF))),
      const Positioned(bottom: 250, left: 80, child: Icon(Icons.auto_awesome, size: 14, color: Color(0xAAFFFFFF))),
    ]);
  }
}

class _Seaweed extends StatelessWidget {
  final double height;
  final double alpha;
  final bool flip;
  const _Seaweed({required this.height, required this.alpha, this.flip = false});
  @override
  Widget build(BuildContext context) {
    return Transform(
      alignment: Alignment.bottomCenter,
      transform: Matrix4.identity()..scaleByDouble(flip ? -1.0 : 1.0, 1.0, 1.0, 1.0),
      child: SizedBox(
        width: 24, height: height,
        child: CustomPaint(painter: _SeaweedPainter(alpha: alpha)),
      ),
    );
  }
}

class _SeaweedPainter extends CustomPainter {
  final double alpha;
  _SeaweedPainter({required this.alpha});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF2E5E4D).withValues(alpha: alpha)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 4;
    // Wavy stalk.
    final path = Path()..moveTo(size.width * 0.5, size.height);
    for (var i = 0; i < 5; i++) {
      final t = i / 5;
      final y1 = size.height * (1 - t - 0.05);
      final y2 = size.height * (1 - t - 0.10);
      final dx = (i.isEven ? -1 : 1) * size.width * 0.4;
      path.quadraticBezierTo(size.width * 0.5 + dx, y1, size.width * 0.5, y2);
    }
    canvas.drawPath(path, paint);
  }
  @override
  bool shouldRepaint(covariant _SeaweedPainter old) => old.alpha != alpha;
}

class _Coral extends StatelessWidget {
  final double size;
  final Color color;
  const _Coral({required this.size, required this.color});
  @override
  Widget build(BuildContext context) => SizedBox(
    width: size, height: size * 0.7,
    child: CustomPaint(painter: _CoralPainter(color: color)),
  );
}

class _CoralPainter extends CustomPainter {
  final Color color;
  _CoralPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color..style = PaintingStyle.stroke
      ..strokeWidth = 3..strokeCap = StrokeCap.round;
    final cx = size.width / 2;
    final base = size.height;
    // Three branching arms.
    for (final dx in [-size.width * 0.35, 0.0, size.width * 0.35]) {
      final path = Path()..moveTo(cx + dx, base);
      path.quadraticBezierTo(cx + dx + size.width * 0.05, base * 0.55, cx + dx, base * 0.10);
      canvas.drawPath(path, paint);
      // Side branchlets.
      canvas.drawLine(
        Offset(cx + dx, base * 0.55),
        Offset(cx + dx + (dx >= 0 ? 1 : -1) * size.width * 0.10, base * 0.30),
        paint,
      );
    }
  }
  @override
  bool shouldRepaint(covariant _CoralPainter old) => old.color != color;
}

class _Bubble extends StatelessWidget {
  final double size;
  final double alpha;
  const _Bubble({required this.size, required this.alpha});
  @override
  Widget build(BuildContext context) => Container(
    width: size, height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: Colors.white.withValues(alpha: alpha * 0.4),
      border: Border.all(color: Colors.white.withValues(alpha: alpha), width: 1.2),
    ),
  );
}

class _WavePainter extends CustomPainter {
  final Color color;
  final bool flip;
  _WavePainter({required this.color, this.flip = false});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path();
    if (!flip) {
      path.moveTo(0, 0);
      path.lineTo(size.width, 0);
      path.lineTo(size.width, size.height * 0.6);
      path.cubicTo(
        size.width * 0.75, size.height,
        size.width * 0.25, 0,
        0, size.height * 0.6,
      );
    } else {
      path.moveTo(0, size.height);
      path.lineTo(size.width, size.height);
      path.lineTo(size.width, size.height * 0.4);
      path.cubicTo(
        size.width * 0.75, 0,
        size.width * 0.25, size.height,
        0, size.height * 0.4,
      );
    }
    path.close();
    canvas.drawPath(path, paint);
  }
  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.color != color || old.flip != flip;
}

// ── 8. Princess & Fairies ──────────────────────────────────────
class _PrincessDecor extends StatelessWidget {
  final _KidsPalette p;
  const _PrincessDecor({required this.p});

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      // Soft pink → gold radial glow at the top — fairy-light effect.
      Positioned(top: -40, left: 0, right: 0, child: Container(
        height: 200,
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topCenter, radius: 0.9,
            colors: [
              p.accent.withValues(alpha: 0.30),
              Colors.transparent,
            ],
          ),
        ),
      )),
      // Castle silhouette anchored at the bottom — multi-tower with windows.
      Positioned(bottom: 18, left: 0, right: 0, height: 130,
        child: CustomPaint(painter: _CastlePainter(color: p.text.withValues(alpha: 0.18)))),
      // Big crown centered at the top.
      Positioned(top: 14, left: 0, right: 0,
        child: Center(child: SizedBox(
          width: 110, height: 50,
          child: CustomPaint(painter: _CrownPainter(color: p.accent)),
        )),
      ),
      // Magical sparkle field — denser than the previous version.
      const Positioned(top: 80, right: 22, child: Icon(Icons.auto_awesome, size: 22, color: Color(0xDDFFD700))),
      const Positioned(top: 100, left: 28, child: Icon(Icons.auto_awesome, size: 14, color: Color(0xAAFFFFFF))),
      const Positioned(top: 140, right: 70, child: Icon(Icons.auto_awesome, size: 12, color: Color(0xAAFFD700))),
      const Positioned(top: 180, left: 60, child: Icon(Icons.auto_awesome, size: 18, color: Color(0xCCFFFFFF))),
      const Positioned(top: 220, right: 30, child: Icon(Icons.auto_awesome, size: 14, color: Color(0xBBFFD700))),
      const Positioned(top: 260, left: 24, child: Icon(Icons.auto_awesome, size: 16, color: Color(0xCCFFFFFF))),
      const Positioned(top: 300, right: 50, child: Icon(Icons.auto_awesome, size: 12, color: Color(0xAAFFD700))),
      const Positioned(bottom: 200, left: 80, child: Icon(Icons.auto_awesome, size: 14, color: Color(0xBBFFFFFF))),
      const Positioned(bottom: 160, right: 80, child: Icon(Icons.auto_awesome, size: 18, color: Color(0xDDFFD700))),
      // Tiny micro-sparkles for fairy dust density.
      Positioned(top: 130, left: 80, child: _MicroSparkle(color: const Color(0xFFFFD700).withValues(alpha: 0.85))),
      Positioned(top: 200, right: 90, child: _MicroSparkle(color: Colors.white.withValues(alpha: 0.85))),
      Positioned(top: 280, left: 100, child: _MicroSparkle(color: const Color(0xFFFFD700).withValues(alpha: 0.85))),
      Positioned(bottom: 220, right: 30, child: _MicroSparkle(color: Colors.white.withValues(alpha: 0.85))),
      Positioned(bottom: 100, left: 50, child: _MicroSparkle(color: const Color(0xFFFFD700).withValues(alpha: 0.85))),
      // Bottom scalloped curl as a finishing touch above the castle base.
      Positioned(bottom: 0, left: 0, right: 0, height: 22,
        child: CustomPaint(painter: _ScallopPainter(color: p.secondary.withValues(alpha: 0.85)))),
    ]);
  }
}

class _CastlePainter extends CustomPainter {
  final Color color;
  _CastlePainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..style = PaintingStyle.fill;
    final w = size.width;
    final h = size.height;
    // Castle silhouette — main body + 3 towers + crenellated parapet.
    final body = Path()
      ..moveTo(w * 0.10, h)               // bottom-left
      ..lineTo(w * 0.10, h * 0.55)        // up to wall
      ..lineTo(w * 0.20, h * 0.55)        // crenellation step
      ..lineTo(w * 0.20, h * 0.45)
      ..lineTo(w * 0.26, h * 0.45)
      ..lineTo(w * 0.26, h * 0.55)
      ..lineTo(w * 0.32, h * 0.55)
      ..lineTo(w * 0.32, h * 0.10)        // up the left tower
      ..lineTo(w * 0.30, h * 0.05)        // tower flag pole
      ..lineTo(w * 0.39, h * 0.10)        // tower roof peak
      ..lineTo(w * 0.39, h * 0.55)        // back down
      ..lineTo(w * 0.42, h * 0.55)
      ..lineTo(w * 0.42, h * 0.30)        // up center tower
      ..lineTo(w * 0.50, h * 0.05)        // center peak
      ..lineTo(w * 0.58, h * 0.30)        // back down
      ..lineTo(w * 0.58, h * 0.55)
      ..lineTo(w * 0.61, h * 0.55)
      ..lineTo(w * 0.61, h * 0.10)        // right tower up
      ..lineTo(w * 0.70, h * 0.05)
      ..lineTo(w * 0.68, h * 0.10)
      ..lineTo(w * 0.68, h * 0.55)
      ..lineTo(w * 0.74, h * 0.55)
      ..lineTo(w * 0.74, h * 0.45)
      ..lineTo(w * 0.80, h * 0.45)
      ..lineTo(w * 0.80, h * 0.55)
      ..lineTo(w * 0.90, h * 0.55)
      ..lineTo(w * 0.90, h)
      ..close();
    canvas.drawPath(body, paint);
    // Tower windows (slightly darker tint).
    final window = Paint()..color = color.withValues(alpha: color.a + 0.10);
    canvas.drawRect(Rect.fromLTWH(w * 0.34, h * 0.20, w * 0.03, h * 0.12), window);
    canvas.drawRect(Rect.fromLTWH(w * 0.485, h * 0.40, w * 0.03, h * 0.10), window);
    canvas.drawRect(Rect.fromLTWH(w * 0.63, h * 0.20, w * 0.03, h * 0.12), window);
    // Main gate (darker arch).
    final gate = Paint()..color = color.withValues(alpha: color.a + 0.15);
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(w * 0.46, h * 0.70, w * 0.08, h * 0.30),
        topLeft: const Radius.circular(8),
        topRight: const Radius.circular(8),
      ),
      gate,
    );
  }
  @override
  bool shouldRepaint(covariant _CastlePainter old) => old.color != color;
}

class _CrownPainter extends CustomPainter {
  final Color color;
  _CrownPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    // Base
    canvas.drawRect(
      Rect.fromLTWH(0, size.height * 0.65, size.width, size.height * 0.30),
      paint,
    );
    // 3 peaks
    final path = Path()..moveTo(0, size.height * 0.65);
    path.lineTo(size.width * 0.18, 0);
    path.lineTo(size.width * 0.34, size.height * 0.5);
    path.lineTo(size.width * 0.5, 0);
    path.lineTo(size.width * 0.66, size.height * 0.5);
    path.lineTo(size.width * 0.82, 0);
    path.lineTo(size.width, size.height * 0.65);
    path.close();
    canvas.drawPath(path, paint);
    // Jewels at peak tips
    final jewel = Paint()..color = Colors.white.withValues(alpha: 0.9);
    canvas.drawCircle(Offset(size.width * 0.18, 0), 3, jewel);
    canvas.drawCircle(Offset(size.width * 0.5, 0),  3.5, jewel);
    canvas.drawCircle(Offset(size.width * 0.82, 0), 3, jewel);
  }
  @override
  bool shouldRepaint(covariant _CrownPainter old) => old.color != color;
}

class _ScallopPainter extends CustomPainter {
  final Color color;
  _ScallopPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const scallops = 6;
    final r = size.width / (scallops * 2);
    final y = size.height - r;
    for (var i = 0; i < scallops; i++) {
      canvas.drawCircle(Offset(r * (2 * i + 1), y), r, paint);
    }
    canvas.drawRect(Rect.fromLTRB(0, y, size.width, size.height), paint);
  }
  @override
  bool shouldRepaint(covariant _ScallopPainter old) => old.color != color;
}

// ════════════════════════════════════════════════════════════════
// FALLBACK: generic _Card4x6 (used for non-Kids contexts)
// ════════════════════════════════════════════════════════════════
class _Card4x6 extends StatelessWidget {
  final MerchThemeVariant variant;
  final String qrData;
  final String? shortCode;
  final String eventName;
  final DateTime? eventDate;
  final String accountTier;
  final String hostName;
  final String? orgLogoUrl;

  const _Card4x6({
    required this.variant,
    required this.qrData,
    required this.eventName,
    required this.accountTier,
    required this.hostName,
    this.shortCode,
    this.eventDate,
    this.orgLogoUrl,
  });

  String? get _formattedDate {
    if (eventDate == null) return null;
    const months = [
      'January','February','March','April','May','June',
      'July','August','September','October','November','December',
    ];
    final d = eventDate!;
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 4 / 6,
      child: Stack(children: [
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: LinearGradient(
              colors: [
                variant.bg,
                Color.lerp(variant.bg, variant.accent, 0.18) ?? variant.bg,
              ],
              begin: Alignment.topLeft, end: Alignment.bottomRight,
            ),
            border: Border.all(color: variant.accent.withValues(alpha: 0.65), width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 18, offset: const Offset(0, 10),
              ),
            ],
          ),
          // Vertical padding kept tight at the bottom so the brand
          // strip clears the card edge without the 3px overflow we
          // saw at common phone widths. The Expanded eventName slot
          // absorbs any remaining slack so longer names still center
          // cleanly without forcing the QR off the bottom.
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Text(
              "YOU'RE INVITED",
              style: TextStyle(
                fontFamily: 'Nunito', fontSize: 11, fontWeight: FontWeight.w800,
                letterSpacing: 3.2, color: variant.accent,
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: Center(
                child: Text(
                  eventName.isEmpty ? 'Your Event' : eventName,
                  textAlign: TextAlign.center,
                  maxLines: 3, overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'FredokaOne', fontSize: 24, height: 1.1,
                    color: variant.text,
                  ),
                ),
              ),
            ),
            if (_formattedDate != null) ...[
              const SizedBox(height: 4),
              Text(
                _formattedDate!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Nunito', fontSize: 13, fontWeight: FontWeight.w700,
                  color: variant.text.withValues(alpha: 0.9),
                ),
              ),
              const SizedBox(height: 12),
            ] else
              const SizedBox(height: 12),
            Container(
              width: 88, height: 88,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: variant.accent, width: 2),
              ),
              child: QrImageView(
                data: qrData,
                version: QrVersions.auto,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Scan to RSVP',
              style: TextStyle(
                fontFamily: 'Nunito', fontSize: 11, fontWeight: FontWeight.w700,
                letterSpacing: 1.2, color: variant.text.withValues(alpha: 0.78),
              ),
            ),
            if (shortCode != null && shortCode!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'partywithqr.com/event/$shortCode',
                style: TextStyle(
                  fontFamily: 'Nunito', fontSize: 10, fontWeight: FontWeight.w700,
                  letterSpacing: 0.4, color: variant.text.withValues(alpha: 0.85),
                ),
              ),
            ],
            const SizedBox(height: 14),
            _BrandStrip(
              accountTier: accountTier,
              hostName: hostName,
              orgLogoUrl: orgLogoUrl,
              accent: variant.accent,
              text: variant.text,
            ),
          ]),
        ),
        const Positioned.fill(
          child: ClipRect(child: _PreviewWatermark()),
        ),
      ]),
    );
  }
}

// ── BRAND STRIP (shared) ───────────────────────────────────────
class _BrandStrip extends StatelessWidget {
  final String accountTier;
  final String hostName;
  final String? orgLogoUrl;
  final Color accent;
  final Color text;
  const _BrandStrip({
    required this.accountTier,
    required this.hostName,
    required this.accent,
    required this.text,
    this.orgLogoUrl,
  });

  @override
  Widget build(BuildContext context) {
    if (accountTier == 'businessPlus') {
      if (orgLogoUrl != null && orgLogoUrl!.isNotEmpty) {
        return SizedBox(
          height: 30,
          child: Image.network(
            orgLogoUrl!,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => _wordmark(),
          ),
        );
      }
      return _wordmark();
    }
    if (accountTier == 'business') {
      final h = hostName.trim().isEmpty ? 'your host' : hostName.trim();
      return Text(
        'Hosted by $h',
        style: TextStyle(
          fontFamily: 'Nunito', fontSize: 12, fontWeight: FontWeight.w700,
          color: text.withValues(alpha: 0.85),
        ),
      );
    }
    return _wordmark();
  }

  Widget _wordmark() {
    return RichText(
      text: TextSpan(
        style: const TextStyle(fontFamily: 'FredokaOne', fontSize: 16, letterSpacing: 1),
        children: [
          TextSpan(text: 'QR ', style: TextStyle(color: text)),
          TextSpan(text: 'PARTY', style: TextStyle(color: accent)),
        ],
      ),
    );
  }
}
