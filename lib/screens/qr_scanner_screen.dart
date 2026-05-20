import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../utils.dart';
import 'guest_event_screen.dart';
import 'public_org_screen.dart';

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

    // QR Party encodes three URL shapes the scanner has to disambiguate:
    //   • `https://partywithqr.com/event/{shortCode}` (or legacy
    //     `?id={docId}`) → resolve to an event and push GuestEventScreen
    //   • `https://partywithqr.com/org/{orgId}` → push PublicOrgScreen
    //     directly (no Firestore lookup needed — orgId IS the doc id)
    //   • `https://partywithqr.com/biz/{slug}` → no in-app counterpart
    //     yet, surface a friendly snackbar pointing to the browser
    // Bare scanned text (no scheme) falls through to the event path
    // when it looks like a shortCode (4–8 char alphanumeric) — handy
    // for QR codes someone made by typing just the shortCode.
    final uri = Uri.tryParse(raw);
    String? eventLookup;
    String? orgId;
    bool isBizUrl = false;
    if (uri != null) {
      final segs = uri.pathSegments;
      final eventIdx = segs.indexOf('event');
      final orgIdx   = segs.indexOf('org');
      final bizIdx   = segs.indexOf('biz');
      if (eventIdx != -1 && eventIdx + 1 < segs.length) {
        eventLookup = segs[eventIdx + 1];
      } else if (orgIdx != -1 && orgIdx + 1 < segs.length) {
        orgId = segs[orgIdx + 1];
      } else if (bizIdx != -1 && bizIdx + 1 < segs.length) {
        isBizUrl = true;
      } else {
        eventLookup = uri.queryParameters['id'];
      }
    }
    if ((eventLookup == null || eventLookup.isEmpty)
        && orgId == null
        && !isBizUrl
        && RegExp(r'^[A-Za-z0-9]{4,8}$').hasMatch(raw.trim())) {
      eventLookup = raw.trim();
    }
    debugPrint('[QRScanner] parsed eventLookup="$eventLookup" orgId="$orgId" isBizUrl=$isBizUrl');

    // /biz/ — no in-app screen yet; route the user to the browser.
    if (isBizUrl) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Business QR codes aren't supported in-app yet — visit the URL in your browser"),
          backgroundColor: Colors.redAccent,
          duration: Duration(seconds: 4),
        ),
      );
      setState(() => _processing = false);
      await _controller.start();
      return;
    }

    // /org/ — push the public org screen directly (no Firestore
    // resolve needed; the orgId IS the doc id). Mirrors main.dart's
    // _pushOrgScreen in the deep-link path so a scanned org QR and a
    // tapped org URL land on the same screen.
    if (orgId != null && orgId.isNotEmpty) {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => PublicOrgScreen(orgId: orgId!)),
      );
      return;
    }

    if (eventLookup == null || eventLookup.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not a valid QR Party code'), backgroundColor: Colors.redAccent),
      );
      setState(() => _processing = false);
      await _controller.start();
      return;
    }
    final lookup = eventLookup;

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
