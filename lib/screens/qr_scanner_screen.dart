import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../utils.dart';
import 'guest_event_screen.dart';

// ─── SCREEN: QR SCANNER ──────────────────────────────────────
class QRScannerScreen extends StatefulWidget {
  const QRScannerScreen({super.key});
  @override
  State<QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<QRScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _processing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing) return;
    final barcode = capture.barcodes.firstOrNull;
    if (barcode?.rawValue == null) return;

    setState(() => _processing = true);
    await _controller.stop();

    final raw = barcode!.rawValue!;
    debugPrint('[QRScanner] scanned raw="$raw"');

    // Pull the lookup token out of the URL. QR Party encodes events
    // as `https://partywithqr.com/event/{shortCode}` — the segment
    // after `/event/` is a 4–8 char uppercase shortCode (NOT a
    // Firestore doc id, which is much longer). The legacy form
    // `?id={docId}` is also accepted so older printed QR codes
    // still work. Bare scanned text (no scheme) is treated as the
    // lookup token directly — handy for QR codes someone made by
    // typing just the shortCode.
    final uri = Uri.tryParse(raw);
    String? lookup;
    if (uri != null) {
      final segs = uri.pathSegments;
      final eventIdx = segs.indexOf('event');
      if (eventIdx != -1 && eventIdx + 1 < segs.length) {
        lookup = segs[eventIdx + 1];
      } else {
        lookup = uri.queryParameters['id'];
      }
    }
    // No URL match — fall back to treating the raw scan as a
    // shortCode if it looks like one.
    if ((lookup == null || lookup.isEmpty)
        && RegExp(r'^[A-Za-z0-9]{4,8}$').hasMatch(raw.trim())) {
      lookup = raw.trim();
    }
    debugPrint('[QRScanner] parsed lookup="$lookup"');

    if (lookup == null || lookup.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not a valid QR Party code'), backgroundColor: Colors.redAccent),
      );
      setState(() => _processing = false);
      await _controller.start();
      return;
    }

    try {
      // Mirror main.dart's _resolveAndPushEvent: short tokens that
      // look like shortCodes are resolved via a where() query against
      // the indexed `shortCode` field; longer tokens (or shortCode
      // misses) fall through to a literal doc.get(). Without this,
      // every scanned URL was treated as a doc id and rejected with
      // "event not found" because shortCodes are NOT doc ids.
      final upper = lookup.toUpperCase();
      final looksLikeShortCode = RegExp(r'^[A-Z0-9]{4,8}$').hasMatch(upper);
      debugPrint('[QRScanner] looksLikeShortCode=$looksLikeShortCode '
          '(upper="$upper")');

      DocumentSnapshot? resolved;
      if (looksLikeShortCode) {
        final qs = await FirebaseFirestore.instance
            .collection('events')
            .where('shortCode', isEqualTo: upper)
            .limit(1)
            .get();
        debugPrint('[QRScanner] shortCode query → ${qs.docs.length} hit(s)');
        if (qs.docs.isNotEmpty) resolved = qs.docs.first;
      }
      // Doc-id fallback — handles the case where the QR encodes the
      // doc id directly (legacy print files / non-shortCode tokens).
      resolved ??= await FirebaseFirestore.instance
          .collection('events')
          .doc(lookup)
          .get();

      if (!mounted) return;
      if (!resolved.exists) {
        debugPrint('[QRScanner] no event for lookup="$lookup"');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Event not found'), backgroundColor: Colors.redAccent),
        );
        setState(() => _processing = false);
        await _controller.start();
        return;
      }
      debugPrint('[QRScanner] resolved → eventId=${resolved.id}');
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => GuestEventScreen(
            eventId: resolved!.id,
            eventData: resolved.data() as Map<String, dynamic>,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[QRScanner] lookup failed for "$lookup": $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error looking up event: $e'), backgroundColor: Colors.redAccent),
      );
      setState(() => _processing = false);
      await _controller.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan Event QR', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on_outlined, color: Colors.white),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            icon: const Icon(Icons.flip_camera_ios_outlined, color: Colors.white),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          // Dim overlay outside the scan frame
          ColorFiltered(
            colorFilter: ColorFilter.mode(Colors.black.withValues(alpha: 0.45), BlendMode.srcOut),
            child: Stack(
              children: [
                Container(color: Colors.black),
                Center(
                  child: Container(
                    width: 260,
                    height: 260,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Green scan frame
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.green, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          // Instructions
          Positioned(
            bottom: 80,
            left: 0,
            right: 0,
            child: Column(
              children: [
                Text(
                  'Point at an event QR code',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  'The camera will scan it automatically',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13),
                ),
              ],
            ),
          ),
          if (_processing)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: AppColors.green),
                    SizedBox(height: 16),
                    Text('Looking up event…', style: TextStyle(color: Colors.white, fontSize: 15)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
