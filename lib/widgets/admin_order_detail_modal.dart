import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../utils.dart';
import '../models/merch_order.dart';

const _cardDark    = Color(0xFF383B56);
const _borderDark  = Color(0xFF4A4E6B);
const _mutedDark   = Color(0xFFA9A6B8);
const _purple      = Color(0xFF9C7FD4);
const _gold        = Color(0xFFC8922A);

class AdminOrderDetailModal extends StatefulWidget {
  final MerchOrder order;
  const AdminOrderDetailModal({super.key, required this.order});
  @override
  State<AdminOrderDetailModal> createState() => _AdminOrderDetailModalState();
}

class _AdminOrderDetailModalState extends State<AdminOrderDetailModal> {
  late final TextEditingController _notes = TextEditingController(text: widget.order.adminNotes);

  @override
  void dispose() { _notes.dispose(); super.dispose(); }

  // Live-watch the order doc so the modal reflects status updates from
  // the row buttons without requiring a re-open.
  Stream<DocumentSnapshot> get _stream =>
      FirebaseFirestore.instance.collection('orders').doc(widget.order.id).snapshots();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: _stream,
      builder: (context, snap) {
        final order = snap.hasData && snap.data!.exists
            ? MerchOrder.fromDoc(snap.data!)
            : widget.order;
        return Padding(
          padding: EdgeInsets.fromLTRB(20, 14, 20, 24 + MediaQuery.of(context).viewInsets.bottom),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Center(child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(color: _borderDark, borderRadius: BorderRadius.circular(2)),
              )),
              const SizedBox(height: 14),
              _header(order),
              const SizedBox(height: 16),
              _previewBlock(order),
              const SizedBox(height: 14),
              _addressBlock(order),
              const SizedBox(height: 14),
              _profitBlock(order),
              const SizedBox(height: 14),
              _timelineBlock(order),
              const SizedBox(height: 14),
              _notesEditor(order),
            ]),
          ),
        );
      },
    );
  }

  Widget _header(MerchOrder order) {
    final shortId = '#${order.id.substring(0, order.id.length.clamp(0, 4)).toUpperCase()}';
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(shortId, style: const TextStyle(fontFamily: 'FredokaOne', fontSize: 22, color: _gold)),
          const SizedBox(width: 10),
          _statusPill(order.status),
        ]),
        const SizedBox(height: 4),
        Text(order.eventName, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        InkWell(
          onTap: () => _copy(context, order.customerEmail, 'Email copied'),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.email_outlined, size: 14, color: _mutedDark),
            const SizedBox(width: 4),
            Text(order.customerEmail, style: const TextStyle(color: _mutedDark, fontSize: 12)),
          ]),
        ),
      ])),
      Text(MerchPricing.format(order.retailTotalCents),
          style: const TextStyle(fontFamily: 'FredokaOne', fontSize: 22, color: Colors.white)),
    ]);
  }

  Widget _statusPill(MerchStatus s) {
    final color = switch (s) {
      MerchStatus.delivered          => AppColors.green,
      MerchStatus.shipped            => _purple,
      MerchStatus.sentToPrinter      => _gold,
      MerchStatus.cancelled          => Colors.redAccent,
      MerchStatus.pendingFulfillment => _gold,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(s.label.toUpperCase(),
          style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.7)),
    );
  }

  // ── Preview + print file ──────────────────────────────────────
  Widget _previewBlock(MerchOrder order) {
    final theme = order.themeKey == 'custom' ? null : themeByKey(order.themeKey);
    final variant = theme?.variants[order.themeVariant.clamp(0, theme.variants.length - 1)];
    return _card(children: [
      Row(children: [
        const Text('PREVIEW',
            style: TextStyle(color: _mutedDark, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
        const Spacer(),
        if (order.printFileUrl != null)
          TextButton.icon(
            onPressed: () => launchUrl(Uri.parse(order.printFileUrl!), mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.download, size: 16, color: _purple),
            label: const Text('Print file', style: TextStyle(color: _purple, fontWeight: FontWeight.w800)),
          ),
      ]),
      const SizedBox(height: 8),
      Container(
        height: 180,
        decoration: BoxDecoration(
          color: variant?.bg ?? _cardDark,
          borderRadius: BorderRadius.circular(12),
          gradient: variant == null
              ? null
              : RadialGradient(
                  colors: [variant.accent.withValues(alpha: 0.55), variant.bg],
                  center: const Alignment(0.5, -0.4), radius: 1.2,
                ),
          border: Border.all(color: _borderDark),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Container(
              width: 110, height: 110, padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
              child: QrImageView(
                data: 'https://partywithqr.com/event?id=${order.eventId}',
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(order.themeKey == 'custom' ? 'Custom design' : (theme?.name ?? '—'),
                    style: TextStyle(
                      color: variant?.text ?? Colors.white, fontFamily: 'FredokaOne', fontSize: 18,
                    )),
                const SizedBox(height: 4),
                Text(
                  '${order.packSize} ${order.productType == MerchProduct.invitation ? "invitations" : "stickers"}',
                  style: TextStyle(color: variant?.text ?? Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(order.eventName, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: (variant?.text ?? Colors.white).withValues(alpha: 0.78), fontSize: 11)),
              ],
            )),
          ]),
        ),
      ),
      if (order.printFileUrl == null) ...[
        const SizedBox(height: 8),
        Text('Print file pending — TODO: server-side renderer (see generatePrintFile.js)',
            style: TextStyle(color: _mutedDark.withValues(alpha: 0.8), fontSize: 11, fontStyle: FontStyle.italic)),
      ],
    ]);
  }

  // ── Address ───────────────────────────────────────────────────
  Widget _addressBlock(MerchOrder order) {
    return _card(children: [
      Row(children: [
        const Text('SHIP TO',
            style: TextStyle(color: _mutedDark, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
        const Spacer(),
        TextButton.icon(
          onPressed: () => _copy(context, order.shippingAddress.formatted, 'Address copied'),
          icon: const Icon(Icons.content_copy, size: 14, color: _purple),
          label: const Text('Copy', style: TextStyle(color: _purple, fontWeight: FontWeight.w800)),
        ),
      ]),
      const SizedBox(height: 4),
      Text(order.shippingAddress.formatted,
          style: const TextStyle(color: Colors.white, fontSize: 13.5, height: 1.55, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Text('${order.shippingSpeed == MerchShipping.expedited ? "Expedited" : "Standard"}'
           ' · ${MerchPricing.format(MerchPricing.shippingCents(order.shippingSpeed))}',
          style: const TextStyle(color: _mutedDark, fontSize: 12)),
    ]);
  }

  // ── Profit ────────────────────────────────────────────────────
  Widget _profitBlock(MerchOrder order) {
    final cost = order.yourCostCents;
    return _card(children: [
      const Text('PROFIT',
          style: TextStyle(color: _mutedDark, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
      const SizedBox(height: 8),
      _moneyRow('Retail',          MerchPricing.format(order.retailTotalCents)),
      _moneyRow('Vistaprint cost', cost == null ? '—' : '−${MerchPricing.format(cost)}'),
      _moneyRow('Stripe fee est.', '−${MerchPricing.format(order.stripeFeeCents)}'),
      const Divider(color: _borderDark, height: 18),
      _moneyRow(
        'Profit',
        cost == null ? '—' : MerchPricing.format(order.profitCents),
        bold: true,
        color: cost == null ? _mutedDark : (order.profitCents >= 0 ? AppColors.green : Colors.redAccent),
      ),
      if (cost == null) ...[
        const SizedBox(height: 6),
        Text('Add Vistaprint cost via "Mark Sent" to see actual profit.',
            style: TextStyle(color: _mutedDark.withValues(alpha: 0.8), fontSize: 11, fontStyle: FontStyle.italic)),
      ],
    ]);
  }

  Widget _moneyRow(String label, String value, {bool bold = false, Color? color}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(children: [
      Expanded(child: Text(label,
          style: TextStyle(color: bold ? Colors.white : _mutedDark, fontSize: bold ? 14 : 13, fontWeight: bold ? FontWeight.w800 : FontWeight.w600))),
      Text(value,
          style: TextStyle(color: color ?? Colors.white, fontSize: bold ? 16 : 14, fontWeight: FontWeight.w800)),
    ]),
  );

  // ── Timeline ──────────────────────────────────────────────────
  Widget _timelineBlock(MerchOrder order) {
    final history = [
      ...order.statusHistory,
      // Synthesise the create event so the timeline always has a starting point.
      if (order.statusHistory.isEmpty)
        {'status': 'pending_fulfillment', 'at': Timestamp.fromDate(order.createdAt)},
    ];
    return _card(children: [
      const Text('TIMELINE',
          style: TextStyle(color: _mutedDark, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
      const SizedBox(height: 8),
      for (final h in history.reversed)
        _timelineRow(h),
    ]);
  }

  Widget _timelineRow(Map<String, dynamic> h) {
    final at = (h['at'] as Timestamp?)?.toDate();
    final s = MerchStatusName.parse(h['status'] as String?);
    final note = h['note'] as String? ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(padding: EdgeInsets.only(top: 5), child: Icon(Icons.circle, size: 6, color: _purple)),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12.5)),
          if (at != null) Text(_formatTs(at), style: const TextStyle(color: _mutedDark, fontSize: 11)),
          if (note.isNotEmpty) Text(note, style: const TextStyle(color: _mutedDark, fontSize: 11, fontStyle: FontStyle.italic)),
        ])),
      ]),
    );
  }

  String _formatTs(DateTime d) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year} · ${d.hour.toString().padLeft(2, "0")}:${d.minute.toString().padLeft(2, "0")}';
  }

  // ── Notes ─────────────────────────────────────────────────────
  Widget _notesEditor(MerchOrder order) {
    return _card(children: [
      const Text('ADMIN NOTES',
          style: TextStyle(color: _mutedDark, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
      const SizedBox(height: 8),
      TextField(
        controller: _notes, maxLines: 3,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: InputDecoration(
          hintText: 'e.g. Vistaprint order #VP12345',
          hintStyle: const TextStyle(color: _mutedDark),
          filled: true, fillColor: _cardDark,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _borderDark)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _borderDark)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _purple, width: 1.5)),
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerRight,
        child: ElevatedButton(
          onPressed: () async {
            final adminUid = FirebaseAuth.instance.currentUser?.uid;
            await FirebaseFirestore.instance.collection('orders').doc(order.id).update({
              'adminNotes': _notes.text,
              'updatedAt': FieldValue.serverTimestamp(),
              'lastNotedBy': adminUid,
            });
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Notes saved'), backgroundColor: AppColors.green,
                duration: Duration(seconds: 2),
              ));
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: _purple, foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          ),
          child: const Text('Save notes', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5)),
        ),
      ),
    ]);
  }

  // ── Helpers ───────────────────────────────────────────────────
  Widget _card({required List<Widget> children}) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: _cardDark, borderRadius: BorderRadius.circular(14),
      border: Border.all(color: _borderDark),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
  );

  void _copy(BuildContext context, String text, String confirm) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(confirm), backgroundColor: AppColors.green, duration: const Duration(seconds: 2),
    ));
  }
}
