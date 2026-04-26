import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils.dart';
import '../models/merch_order.dart';
import 'order_merch_screen.dart';

// ── Theme palette ──────────────────────────────────────────────
const _bgDark      = Color(0xFF2D3047);
const _bgLight     = Color(0xFFF8F7FC);
const _borderDark  = Color(0xFF4A4E6B);
const _borderLight = Color(0xFFE0E8E0);
const _mutedDark   = Color(0xFFA9A6B8);
const _mutedLight  = Color(0xFF8892A4);
const _purple      = Color(0xFF9C7FD4);
const _gold        = Color(0xFFC8922A);

class GenerateQRCodeScreen extends StatefulWidget {
  final String eventId;
  final String eventTitle;
  const GenerateQRCodeScreen({super.key, required this.eventId, required this.eventTitle});

  @override
  State<GenerateQRCodeScreen> createState() => _GenerateQRCodeScreenState();
}

class _GenerateQRCodeScreenState extends State<GenerateQRCodeScreen> {
  final GlobalKey _qrKey = GlobalKey();
  bool _busy = false;
  String? _shortCode;

  @override
  void initState() {
    super.initState();
    _loadShortCode();
  }

  Future<void> _loadShortCode() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('events').doc(widget.eventId).get();
      if (!mounted) return;
      final code = snap.data()?['shortCode'] as String?;
      if (code != null && code.isNotEmpty) {
        setState(() => _shortCode = code);
      }
    } catch (_) {/* silent — UI hides the line when null */}
  }

  // Theme-aware color getters — resolve light vs dark variant from the current Theme.
  // NOTE: The QR-code card itself is always white so scanners can read it;
  // these getters only affect the surrounding chrome.
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
      debugPrint('[QR] capture failed: $e');
      return null;
    }
  }

  String _safeFilename() {
    final raw = widget.eventTitle.isEmpty ? widget.eventId : widget.eventTitle;
    return raw.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_').toLowerCase();
  }

  Future<void> _downloadQr() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await _captureQr();
      if (bytes == null) throw Exception('Could not capture QR');
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) throw Exception('Gallery access denied');
      }
      await Gal.putImageBytes(bytes, name: 'qrparty_${_safeFilename()}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('📸 QR code saved to your photos'),
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

  Future<void> _openOrderDialog(MerchProduct product) async {
    // Fetch event doc on demand so the order screen can show host + date in
    // the live preview. Screen itself only has eventId + eventTitle from props.
    try {
      final snap = await FirebaseFirestore.instance.collection('events').doc(widget.eventId).get();
      if (!mounted) return;
      final data = snap.data() ?? {};
      final ts = data['date'] as Timestamp?;
      Navigator.of(context).push(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => OrderMerchScreen(
          eventId: widget.eventId,
          eventTitle: widget.eventTitle,
          hostName: (data['hostName'] as String?) ?? '',
          eventDate: ts?.toDate(),
          eventType: data['eventType'] as String?,
          shortCode: (data['shortCode'] as String?) ?? _shortCode,
          initialProduct: product,
        ),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open order: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  Future<void> _shareQr() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await _captureQr();
      if (bytes == null) throw Exception('Could not capture QR');
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/qrparty_${_safeFilename()}.png');
      await file.writeAsBytes(bytes);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/png')],
        text: 'RSVP to ${widget.eventTitle} — scan this QR with the QR Party app!',
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
        title: Text('Event QR Code', style: TextStyle(fontWeight: FontWeight.w700, color: fg)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                Text('Unique to this event', style: TextStyle(fontSize: 14, color: _muted, letterSpacing: 1, fontWeight: FontWeight.w500)),
                const SizedBox(height: 16),
                // ── QR card: ALWAYS white, never theme-swapped (scanners need white bg) ─────
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
                        QrImageView(
                          data: 'https://partywithqr.com/event?id=${widget.eventId}',
                          version: QrVersions.auto,
                          size: 200,
                          backgroundColor: Colors.white,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            widget.eventTitle,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            // Hardcoded muted — this text sits ON the always-white QR card,
                            // so it must not flip with the theme.
                            style: const TextStyle(fontSize: 11, color: _mutedLight, fontWeight: FontWeight.w500),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Short URL — sits OUTSIDE the RepaintBoundary so it doesn't
                // appear in downloaded/shared QR images. Hidden until the
                // shortCode load resolves.
                if (_shortCode != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    'Or visit',
                    style: TextStyle(fontSize: 11, color: _muted, letterSpacing: 1.2, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    'partywithqr.com/event/$_shortCode',
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
                // ── DOWNLOAD + SHARE primary row ────────────────
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _busy ? null : _downloadQr,
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
                        onPressed: _busy ? null : _shareQr,
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
                const SizedBox(height: 20),
                Text(
                  'Guests scan this to RSVP, view\nthe wishlist, and upload photos',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: _muted, height: 1.6),
                ),
                const SizedBox(height: 12),
                Text(
                  'Print it, text it, or post it — scanning takes guests straight to your event.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: _muted, height: 1.5),
                ),
                const SizedBox(height: 28),
                // ── Secondary actions ──────────────────────────
                Row(
                  children: [
                    Expanded(child: _actionButton(context, icon: Icons.mail_outline_rounded, label: 'Order Invitations', color: _gold, onTap: () => _openOrderDialog(MerchProduct.invitation))),
                    const SizedBox(width: 8),
                    Expanded(child: _actionButton(context, icon: Icons.star_outline_rounded, label: 'Order Stickers', color: const Color(0xFF7B5EA7), onTap: () => _openOrderDialog(MerchProduct.sticker))),
                  ],
                ),
                const SizedBox(height: 12),
                Text('Invitations & stickers powered by Printably', style: TextStyle(fontSize: 11, color: _muted)),
              ],
            ),
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
              debugLabel('Screen 4 — Generate QR Code'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionButton(BuildContext context, {required IconData icon, required String label, required Color color, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(14)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
