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
    final uri = Uri.tryParse(raw);
    String? eventId;
    if (uri != null) {
      final segments = uri.pathSegments;
      final idx = segments.indexOf('event');
      if (idx != -1 && idx + 1 < segments.length) {
        eventId = segments[idx + 1];
      }
    }

    if (eventId == null || eventId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not a valid QR Party code'), backgroundColor: Colors.redAccent),
      );
      setState(() => _processing = false);
      await _controller.start();
      return;
    }

    try {
      final doc = await FirebaseFirestore.instance.collection('events').doc(eventId).get();
      if (!mounted) return;
      if (!doc.exists) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Event not found'), backgroundColor: Colors.redAccent),
        );
        setState(() => _processing = false);
        await _controller.start();
        return;
      }
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => GuestEventScreen(eventId: eventId, eventData: doc.data()),
        ),
      );
    } catch (e) {
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
