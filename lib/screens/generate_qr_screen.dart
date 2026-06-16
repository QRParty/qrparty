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
  // Anchor for the share-sheet popover on iPad / iOS. Without a non-
  // zero source rect, share_plus throws PlatformException with the
  // {{0,0},{0,0}} message Jennifer hit on her iPhone — UIActivity
  // ViewController requires the popover origin to live inside the
  // source view's coordinate space.
  final GlobalKey _shareKey = GlobalKey();
  bool _busy = false;
  String? _shortCode;
  // Cached host display name for the share-sheet invite text. Populated
  // from the same event-doc fetch as _shortCode so the share button
  // never has to round-trip on its own. Defaulted to 'Host' so the
  // invite text reads cleanly even when the field is missing.
  String _hostName = 'Host';

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
      final data = snap.data();
      final code = data?['shortCode'] as String?;
      // Pull hostName from the same fetch — share-sheet text reads it
      // and the screen has no other source for the host's display name.
      final host = (data?['hostName'] as String?) ?? 'Host';
      debugPrint('[GenerateQR] eventId=${widget.eventId} loaded shortCode=$code host=$host');
      setState(() {
        _hostName = host.isEmpty ? 'Host' : host;
        if (code != null && code.isNotEmpty) {
          _shortCode = code;
        }
      });
      if (code != null && code.isNotEmpty) {
        debugPrint('[GenerateQR] QR will encode: ${_qrUrl(code)}');
      } else {
        debugPrint('[GenerateQR] WARNING: shortCode missing on events/${widget.eventId} — QR will stay in loading state');
      }
    } catch (e) {
      debugPrint('[GenerateQR] _loadShortCode failed: $e');
    }
  }

  /// Canonical QR target. Encodes the public short URL the web app handles
  /// at `https://partywithqr.com/event/{shortCode}`. Centralised here so
  /// the rendered QR and the textual "Or visit" hint can never drift.
  String _qrUrl(String code) => 'https://partywithqr.com/event/$code';

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
      // Lead with the app + code. The mobile web event page now
      // routes iOS / Android visitors through a "Get QR Party" bridge
      // (public/event.html's __qrpIsMobile branch) that auto-copies
      // the code to their clipboard — the app's clipboard-detect on
      // resume then surfaces an "Open this event?" prompt the moment
      // they finish installing. So we surface the CODE prominently
      // in the share text: even a guest who pastes the message into
      // a non-clickable channel can type the code into the app's
      // Enter Code dialog and reach the event.
      //
      // The URL still points to /event/<code> for guests who tap;
      // their mobile browser hits the same bridge, desktop browsers
      // get the full web RSVP page. If shortCode hasn't resolved
      // yet (rare — share is gated on QR render which depends on
      // the same load), fall through to a code-less invite that
      // still gets the app into the guest's hands.
      final hasCode = _shortCode != null && _shortCode!.isNotEmpty;
      final code = hasCode ? _shortCode! : '';
      final appUrl = hasCode
          ? 'partywithqr.com/event/$code'
          : 'partywithqr.com/download';
      final shareText = hasCode
          ? "You're invited to ${widget.eventTitle} hosted by $_hostName! 🎉\n"
            "Open in QR Party with code: $code\n"
            "Get the app: $appUrl"
          : "You're invited to ${widget.eventTitle} hosted by $_hostName! 🎉\n"
            "Get the app: $appUrl";
      // iOS requires sharePositionOrigin pointing at the share button's
      // global rect; without it the share sheet has nowhere to anchor
      // its popover and share_plus throws. Harmless on Android — the
      // platform channel ignores the field.
      final box = _shareKey.currentContext?.findRenderObject() as RenderBox?;
      final origin = box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size;
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/png')],
        text: shareText,
        sharePositionOrigin: origin,
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
                        // Show a spinner until the shortCode resolves — we
                        // never want to render a QR that points to a
                        // not-yet-known URL. Once shortCode loads, the QR
                        // encodes https://partywithqr.com/event/{shortCode}
                        // (matches the web app's short-URL router and the
                        // "Or visit" hint shown below the card).
                        if (_shortCode == null || _shortCode!.isEmpty)
                          const SizedBox(
                            width: 200, height: 200,
                            child: Center(
                              child: CircularProgressIndicator(color: _purple, strokeWidth: 3),
                            ),
                          )
                        else
                          QrImageView(
                            data: _qrUrl(_shortCode!),
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
                // ── ON-SCREEN DIAGNOSTIC ──────────────────────────────
                // Surfaces the actual QR-encoded URL (or the load-state
                // reason if the QR is still a spinner). Lives below the
                // shareable card, so it never leaks into download/share
                // images. Useful for verifying — at a glance, no DevTools
                // — that the QR encodes /event/{shortCode} and never the
                // homepage. Remove once you're satisfied it's encoding
                // correctly in every flow.
                const SizedBox(height: 18),
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _purple.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _purple.withValues(alpha: 0.30)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('QR ENCODES',
                          style: TextStyle(
                            fontSize: 10, fontWeight: FontWeight.w900,
                            letterSpacing: 1.6, color: _purple,
                          )),
                      const SizedBox(height: 4),
                      SelectableText(
                        _shortCode == null || _shortCode!.isEmpty
                            ? '(loading… shortCode not yet read from events/${widget.eventId})'
                            : _qrUrl(_shortCode!),
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: fg,
                        ),
                      ),
                    ],
                  ),
                ),
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
                        key: _shareKey,
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
                // Merch ordering (invitations + stickers) is gated by
                // [kMerchOrderingEnabled] during beta. While off, the
                // two CTAs are replaced by a single Coming Soon tile
                // so users know the feature is planned, not removed.
                if (kMerchOrderingEnabled) ...[
                  Row(
                    children: [
                      Expanded(child: _actionButton(context, icon: Icons.mail_outline_rounded, label: 'Order Invitations', color: _gold, onTap: () => _openOrderDialog(MerchProduct.invitation))),
                      const SizedBox(width: 8),
                      Expanded(child: _actionButton(context, icon: Icons.star_outline_rounded, label: 'Order Stickers', color: const Color(0xFF7B5EA7), onTap: () => _openOrderDialog(MerchProduct.sticker))),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text('Invitations & stickers powered by Printably', style: TextStyle(fontSize: 11, color: _muted)),
                ] else ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _gold.withValues(alpha: 0.45)),
                    ),
                    child: Row(children: [
                      const Icon(Icons.local_mall_outlined, size: 20, color: _gold),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Stickers & Invitations',
                              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: fg),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Printed merch with your QR is on the way.',
                              style: TextStyle(fontSize: 11.5, color: _muted, height: 1.3),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: _gold,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          'COMING SOON',
                          style: TextStyle(
                            fontSize: 9, fontWeight: FontWeight.w900,
                            color: Colors.white, letterSpacing: 0.6,
                          ),
                        ),
                      ),
                    ]),
                  ),
                ],
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
