import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../utils.dart';
import '../services/business_qr_service.dart';

// ── Theme palette ──────────────────────────────────────────────
const _bgDark      = Color(0xFF2D3047);
const _bgLight     = Color(0xFFF8F7FC);
const _borderDark  = Color(0xFF4A4E6B);
const _borderLight = Color(0xFFE0E8E0);
const _mutedDark   = Color(0xFFA9A6B8);
const _mutedLight  = Color(0xFF8892A4);
const _purple      = Color(0xFF9C7FD4);
const _gold        = Color(0xFFC8922A);

/// Permanent business QR for a Business / Headquarters tier owner. Encodes
/// `https://partywithqr.com/biz/{slug}` — public web page lists every
/// upcoming public event the host has scheduled. Different from the
/// per-event QR ([GenerateQRCodeScreen]): one QR per account, never
/// rotates, lives on storefront windows, business cards, table tents.
///
/// Provisioning is idempotent — first visit writes `businesses/{slug}` +
/// the user pointer fields, every subsequent visit short-circuits to the
/// already-stored slug (see [BusinessQRService]).
class BusinessQRScreen extends StatefulWidget {
  const BusinessQRScreen({super.key});

  @override
  State<BusinessQRScreen> createState() => _BusinessQRScreenState();
}

class _BusinessQRScreenState extends State<BusinessQRScreen> {
  final GlobalKey _qrKey = GlobalKey();
  bool _busy = false;
  BusinessQRResult? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    _provision();
  }

  Future<void> _provision() async {
    try {
      final result = await BusinessQRService.ensureForCurrentUser();
      if (!mounted) return;
      setState(() => _result = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;

  Future<Uint8List?> _captureQr() async {
    try {
      final boundary = _qrKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint('[BizQR] capture failed: $e');
      return null;
    }
  }

  String _safeFilename() {
    final slug = _result?.slug ?? 'business';
    return 'qrparty_biz_${slug.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_').toLowerCase()}';
  }

  Future<void> _downloadQr() async {
    if (_busy || _result == null) return;
    setState(() => _busy = true);
    try {
      final bytes = await _captureQr();
      if (bytes == null) throw Exception('Could not capture QR');
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) throw Exception('Gallery access denied');
      }
      await Gal.putImageBytes(bytes, name: _safeFilename());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('📸 Business QR saved to your photos'),
          backgroundColor: AppColors.green,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Save failed: $e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareQr() async {
    if (_busy || _result == null) return;
    setState(() => _busy = true);
    try {
      final bytes = await _captureQr();
      if (bytes == null) throw Exception('Could not capture QR');
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${_safeFilename()}.png');
      await file.writeAsBytes(bytes);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/png')],
        text: 'Scan to see all our upcoming events: ${_result!.url}',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Share failed: $e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fg = _isDark ? Colors.white : AppColors.dark;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Text('Business QR Code', style: TextStyle(fontWeight: FontWeight.w700, color: fg)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: _error != null
                ? _buildError(fg)
                : _buildBody(fg),
          ),
        ),
      ),
      bottomNavigationBar: ColoredBox(
        color: _bg,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton.icon(
                    onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
                    icon: const Icon(Icons.home_outlined),
                    label: const Text('Back to Menu', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _purple,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ),
              ),
              debugLabel('Screen — Business QR Code'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildError(Color fg) => Column(
    children: [
      const SizedBox(height: 40),
      Text('Could not provision your business QR', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: fg)),
      const SizedBox(height: 10),
      Text(_error ?? '', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: _muted)),
      const SizedBox(height: 24),
      ElevatedButton(
        onPressed: () { setState(() { _error = null; _result = null; }); _provision(); },
        style: ElevatedButton.styleFrom(backgroundColor: _purple, foregroundColor: Colors.white),
        child: const Text('Retry'),
      ),
    ],
  );

  Widget _buildBody(Color fg) {
    final loaded = _result != null;
    return Column(
      children: [
        Text(
          'Permanent — share once, scan forever',
          style: TextStyle(fontSize: 13, color: _muted, letterSpacing: 1, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 16),
        // QR card — always white so scanners can read it. Wraps in a
        // RepaintBoundary so download / share captures only the card,
        // not the surrounding chrome.
        RepaintBoundary(
          key: _qrKey,
          child: Container(
            width: 260,
            height: 260,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: _purple, width: 3),
              boxShadow: [BoxShadow(color: _purple.withValues(alpha: 0.20), blurRadius: 40, spreadRadius: 4)],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (!loaded)
                  const SizedBox(
                    width: 200, height: 200,
                    child: Center(child: CircularProgressIndicator(color: _purple, strokeWidth: 3)),
                  )
                else
                  QrImageView(
                    data: _result!.url,
                    version: QrVersions.auto,
                    size: 200,
                    backgroundColor: Colors.white,
                  ),
                const SizedBox(height: 6),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'BUSINESS',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w900,
                      color: _mutedLight, letterSpacing: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (loaded) ...[
          const SizedBox(height: 14),
          Text(
            'Or visit',
            style: TextStyle(fontSize: 11, color: _muted, letterSpacing: 1.2, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          SelectableText(
            'partywithqr.com/biz/${_result!.slug}',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: _purple,
              letterSpacing: 0.5,
            ),
          ),
        ],
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: (_busy || !loaded) ? null : _downloadQr,
                icon: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.download_outlined, size: 18),
                label: const Text('Download', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: _border,
                  disabledForegroundColor: _muted,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: (_busy || !loaded) ? null : _shareQr,
                icon: const Icon(Icons.share_outlined, size: 18),
                label: const Text('Share', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _purple,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: _border,
                  disabledForegroundColor: _muted,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _purple.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _purple.withValues(alpha: 0.30)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'How it works',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: _purple, letterSpacing: 1.2),
              ),
              const SizedBox(height: 8),
              Text(
                'This QR is tied to your account, not a single event. Anyone who scans it lands on your public events page — every upcoming public event you\'re hosting, in one place.',
                style: TextStyle(fontSize: 13, color: _muted, height: 1.55),
              ),
              const SizedBox(height: 8),
              Text(
                'Print it once. Stick it on your door, table tents, business cards, receipts. Guests always see your latest events.',
                style: TextStyle(fontSize: 13, color: _muted, height: 1.55),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
