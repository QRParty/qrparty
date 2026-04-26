import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils.dart';
import '../models/merch_order.dart';
import 'admin_order_detail_modal.dart';

const _cardDark    = Color(0xFF383B56);
const _cardLight   = Colors.white;
const _borderDark  = Color(0xFF4A4E6B);
const _borderLight = Color(0xFFE0E8E0);
const _mutedDark   = Color(0xFFA9A6B8);
const _mutedLight  = Color(0xFF8892A4);
const _purple      = Color(0xFF9C7FD4);
const _gold        = Color(0xFFC8922A);

const _filterStatuses = <(String, MerchStatus?)>[
  ('All',           null),
  ('Pending',       MerchStatus.pendingFulfillment),
  ('Sent',          MerchStatus.sentToPrinter),
  ('Shipped',       MerchStatus.shipped),
  ('Delivered',     MerchStatus.delivered),
  ('Cancelled',     MerchStatus.cancelled),
];

class AdminOrderTable extends StatefulWidget {
  const AdminOrderTable({super.key});
  @override
  State<AdminOrderTable> createState() => _AdminOrderTableState();
}

class _AdminOrderTableState extends State<AdminOrderTable> {
  MerchStatus? _filter;

  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;
  Color get _fg     => _isDark ? Colors.white : AppColors.dark;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('orders')
          .orderBy('createdAt', descending: true)
          .limit(200)
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator(color: _purple)),
          );
        }
        final all = (snap.data?.docs ?? []).map(MerchOrder.fromDoc).toList();
        final filtered = _filter == null
            ? all
            : all.where((o) => o.status == _filter).toList();

        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _statsRow(all),
          const SizedBox(height: 12),
          _filterPills(),
          const SizedBox(height: 12),
          _quickActions(),
          const SizedBox(height: 12),
          if (filtered.isEmpty)
            _emptyCard()
          else
            ...filtered.map((o) => _OrderCard(
              order: o,
              onTap: () => _openDetail(o),
              isDark: _isDark,
            )),
        ]);
      },
    );
  }

  // ── Stats ─────────────────────────────────────────────────────
  Widget _statsRow(List<MerchOrder> all) {
    final pending = all.where((o) => o.status == MerchStatus.pendingFulfillment).length;
    final weekAgo = DateTime.now().subtract(const Duration(days: 7));
    final thisWeek = all.where((o) => o.createdAt.isAfter(weekAgo)).toList();
    final weekRev = thisWeek.fold<int>(0, (s, o) => s + o.retailTotalCents);

    final shipped = all.where((o) =>
        o.status == MerchStatus.shipped || o.status == MerchStatus.delivered).toList();
    final fulfillmentSamples = shipped.where((o) {
      return o.statusHistory.any((h) => h['status'] == 'shipped');
    }).map((o) {
      final shipAt = o.statusHistory.firstWhere(
        (h) => h['status'] == 'shipped',
        orElse: () => const {},
      )['at'] as Timestamp?;
      if (shipAt == null) return null;
      return shipAt.toDate().difference(o.createdAt).inHours;
    }).whereType<int>().toList();
    final avgHours = fulfillmentSamples.isEmpty
        ? null
        : (fulfillmentSamples.reduce((a, b) => a + b) / fulfillmentSamples.length).round();

    final monthStart = DateTime(DateTime.now().year, DateTime.now().month, 1);
    final monthOrders = all.where((o) =>
        o.createdAt.isAfter(monthStart) && o.status != MerchStatus.cancelled).toList();
    final monthProfit = monthOrders.fold<int>(0, (s, o) => s + o.profitCents);

    return Row(children: [
      _stat('Pending', '$pending', _gold),
      const SizedBox(width: 8),
      _stat('This Week', '${thisWeek.length}\n${MerchPricing.format(weekRev)}', _purple, twoLine: true),
      const SizedBox(width: 8),
      _stat('Avg Fulfill', avgHours == null ? '—' : '${avgHours}h', AppColors.green),
      const SizedBox(width: 8),
      _stat('Profit / Mo', MerchPricing.format(monthProfit), _gold),
    ]);
  }

  Widget _stat(String label, String value, Color color, {bool twoLine = false}) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: _card, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value,
            style: TextStyle(
              fontFamily: 'FredokaOne', fontSize: twoLine ? 14 : 22, color: color, height: 1.1,
            )),
        const SizedBox(height: 4),
        Text(label.toUpperCase(),
            style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: _muted, letterSpacing: 1.2)),
      ]),
    ),
  );

  // ── Filter pills ──────────────────────────────────────────────
  Widget _filterPills() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (final (label, s) in _filterStatuses) ...[
          GestureDetector(
            onTap: () => setState(() => _filter = s),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: _filter == s ? _purple : _card,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _filter == s ? _purple : _border),
              ),
              child: Text(label,
                  style: TextStyle(
                    color: _filter == s ? Colors.white : _muted,
                    fontWeight: FontWeight.w800, fontSize: 12,
                  )),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ]),
    );
  }

  // ── Quick actions ─────────────────────────────────────────────
  Widget _quickActions() {
    return Row(children: [
      Expanded(child: _quickBtn(
        'Open Vistaprint', Icons.open_in_new, _gold,
        () => launchUrl(Uri.parse('https://www.vistaprint.com'), mode: LaunchMode.externalApplication),
      )),
      const SizedBox(width: 8),
      Expanded(child: _quickBtn(
        'Pending Only', Icons.assignment_late_outlined, _purple,
        () => setState(() => _filter = MerchStatus.pendingFulfillment),
      )),
    ]);
  }

  Widget _quickBtn(String label, IconData icon, Color color, VoidCallback onTap) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16, color: Colors.white),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5)),
      style: ElevatedButton.styleFrom(
        backgroundColor: color, foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _emptyCard() => Container(
    padding: const EdgeInsets.all(28),
    decoration: BoxDecoration(
      color: _card, borderRadius: BorderRadius.circular(14),
      border: Border.all(color: _border),
    ),
    child: Column(children: [
      Icon(Icons.inventory_2_outlined, size: 36, color: _muted),
      const SizedBox(height: 10),
      Text(_filter == null ? 'No orders yet' : 'No orders in this status',
          style: TextStyle(color: _fg, fontWeight: FontWeight.w800, fontSize: 14)),
    ]),
  );

  void _openDetail(MerchOrder order) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => AdminOrderDetailModal(order: order),
    );
  }
}

// ── ORDER CARD ──────────────────────────────────────────────────
class _OrderCard extends StatelessWidget {
  final MerchOrder order;
  final VoidCallback onTap;
  final bool isDark;
  const _OrderCard({required this.order, required this.onTap, required this.isDark});

  Color get _card   => isDark ? _cardDark   : _cardLight;
  Color get _border => isDark ? _borderDark : _borderLight;
  Color get _muted  => isDark ? _mutedDark  : _mutedLight;
  Color get _fg     => isDark ? Colors.white : AppColors.dark;

  Color _statusColor() => switch (order.status) {
    MerchStatus.delivered          => AppColors.green,
    MerchStatus.shipped            => _purple,
    MerchStatus.sentToPrinter      => _gold,
    MerchStatus.cancelled          => Colors.redAccent,
    MerchStatus.pendingFulfillment => _gold,
  };

  String get _shortId => '#${order.id.substring(0, order.id.length.clamp(0, 4)).toUpperCase()}';

  String get _vistaprintBlock {
    // Vistaprint expects: name on line 1, street on line 2, city/state/zip line 3
    return '${order.shippingAddress.formatted}\n\n'
        'Order: $_shortId\n'
        'Product: ${order.packSize} ${order.productType == MerchProduct.invitation ? "invitations" : "stickers"}\n'
        'Theme: ${order.themeKey}${order.themeKey == "custom" ? "" : " · variant ${order.themeVariant}"}\n'
        'Event: ${order.eventName}';
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor();
    final isInvitation = order.productType == MerchProduct.invitation;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: _card, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: onTap,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(_shortId,
                    style: const TextStyle(
                      fontFamily: 'FredokaOne', fontSize: 18, color: _gold,
                    )),
                const SizedBox(width: 10),
                _statusBadge(color),
                const Spacer(),
                Text(MerchPricing.format(order.retailTotalCents),
                    style: TextStyle(color: _fg, fontWeight: FontWeight.w800, fontSize: 15)),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Text(isInvitation ? '✉️' : '🏷️', style: const TextStyle(fontSize: 18)),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  '${order.packSize} ${isInvitation ? "invitations" : "stickers"} · ${order.themeKey == "custom" ? "Custom" : themeByKey(order.themeKey).name}',
                  style: TextStyle(color: _fg, fontSize: 13.5, fontWeight: FontWeight.w700),
                )),
              ]),
              const SizedBox(height: 4),
              Text('${order.customerName} · ${order.customerEmail}',
                  style: TextStyle(color: _muted, fontSize: 12)),
              const SizedBox(height: 2),
              Text('Event: ${order.eventName}',
                  style: TextStyle(color: _muted, fontSize: 12)),
              const SizedBox(height: 6),
              GestureDetector(
                onTap: () => _copy(context, order.shippingAddress.formatted, 'Address copied'),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: _purple.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _purple.withValues(alpha: 0.30)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.content_copy, size: 14, color: _purple),
                    const SizedBox(width: 6),
                    Expanded(child: Text(
                      order.shippingAddress.formatted.replaceAll('\n', ' · '),
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _purple, fontSize: 11.5, fontWeight: FontWeight.w700),
                    )),
                  ]),
                ),
              ),
            ]),
          ),
        ),
        Container(height: 1, color: _border),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
          child: Wrap(spacing: 4, runSpacing: 4, children: [
            _action(context, 'Print File', Icons.download_outlined, _purple,
                onTap: order.printFileUrl == null
                    ? null
                    : () => launchUrl(Uri.parse(order.printFileUrl!), mode: LaunchMode.externalApplication)),
            _action(context, 'Copy Details', Icons.copy_all_outlined, _purple,
                onTap: () => _copy(context, _vistaprintBlock, 'Order block copied')),
            if (order.status == MerchStatus.pendingFulfillment)
              _action(context, 'Mark Sent', Icons.send_outlined, _gold,
                  onTap: () => _markSent(context)),
            if (order.status == MerchStatus.sentToPrinter || order.status == MerchStatus.pendingFulfillment)
              _action(context, 'Add Tracking', Icons.local_shipping_outlined, _purple,
                  onTap: () => _addTracking(context)),
            if (order.status == MerchStatus.shipped)
              _action(context, 'Mark Delivered', Icons.check_circle_outline, AppColors.green,
                  onTap: () => _markDelivered(context)),
            if (order.status != MerchStatus.delivered && order.status != MerchStatus.cancelled)
              _action(context, 'Cancel + Refund', Icons.cancel_outlined, Colors.redAccent,
                  onTap: () => _cancel(context)),
          ]),
        ),
      ]),
    );
  }

  Widget _statusBadge(Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withValues(alpha: 0.45)),
    ),
    child: Text(order.status.label.toUpperCase(),
        style: TextStyle(color: color, fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
  );

  Widget _action(BuildContext context, String label, IconData icon, Color color, {VoidCallback? onTap}) {
    final disabled = onTap == null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: (disabled ? _muted : color).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: (disabled ? _muted : color).withValues(alpha: 0.35)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: disabled ? _muted : color),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                color: disabled ? _muted : color,
                fontSize: 11.5, fontWeight: FontWeight.w800,
              )),
        ]),
      ),
    );
  }

  void _copy(BuildContext context, String text, String confirm) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(confirm), backgroundColor: AppColors.green, duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _markSent(BuildContext context) async {
    final cents = await _promptCost(context);
    if (cents == null) return;
    await _appendStatus(MerchStatus.sentToPrinter, fields: {'yourCostCents': cents});
    if (context.mounted) _toast(context, 'Marked sent — customer email queued');
  }

  Future<int?> _promptCost(BuildContext ctx) {
    final c = TextEditingController();
    return showDialog<int>(
      context: ctx,
      builder: (_) => AlertDialog(
        backgroundColor: _card,
        title: const Text('Vistaprint cost', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: c, autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'Total cost (USD)', labelStyle: TextStyle(color: _mutedDark),
            hintText: 'e.g. 12.34', hintStyle: TextStyle(color: _mutedDark),
            prefixText: '\$  ', prefixStyle: TextStyle(color: _mutedDark),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: _mutedDark))),
          TextButton(
            onPressed: () {
              final dollars = double.tryParse(c.text.trim());
              if (dollars == null) return;
              Navigator.pop(ctx, (dollars * 100).round());
            },
            child: const Text('Save', style: TextStyle(color: _purple, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }

  Future<void> _addTracking(BuildContext context) async {
    final result = await showDialog<({String num, String carrier})>(
      context: context,
      builder: (_) => _TrackingDialog(),
    );
    if (result == null) return;
    await _appendStatus(MerchStatus.shipped, fields: {
      'trackingNumber': result.num,
      'trackingCarrier': result.carrier,
    });
    if (context.mounted) _toast(context, 'Tracking added — customer notified');
  }

  Future<void> _markDelivered(BuildContext context) async {
    await _appendStatus(MerchStatus.delivered);
    if (context.mounted) _toast(context, 'Marked delivered — customer notified');
  }

  Future<void> _cancel(BuildContext context) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => _ReasonDialog(),
    );
    if (reason == null) return;
    await _appendStatus(MerchStatus.cancelled, fields: {'cancelReason': reason});
    if (context.mounted) _toast(context, 'Cancelled. Refund queued (skipped in test mode).');
  }

  Future<void> _appendStatus(MerchStatus next, {Map<String, dynamic> fields = const {}}) async {
    final adminUid = FirebaseAuth.instance.currentUser?.uid;
    final ref = FirebaseFirestore.instance.collection('orders').doc(order.id);
    await ref.update({
      'status': next.wireName,
      'updatedAt': FieldValue.serverTimestamp(),
      'statusHistory': FieldValue.arrayUnion([
        {
          'status': next.wireName,
          'at': Timestamp.now(),
          'byUid': adminUid,
          ...fields.containsKey('cancelReason') ? {'note': fields['cancelReason']} : {},
        }
      ]),
      ...fields,
    });
  }

  void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg), backgroundColor: AppColors.green, duration: const Duration(seconds: 2),
    ));
  }
}

// ── Tracking + reason dialogs ──────────────────────────────────
class _TrackingDialog extends StatefulWidget {
  @override
  State<_TrackingDialog> createState() => _TrackingDialogState();
}

class _TrackingDialogState extends State<_TrackingDialog> {
  final _num = TextEditingController();
  String _carrier = 'USPS';
  static const _carriers = ['USPS', 'UPS', 'FedEx', 'Other'];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _cardDark,
      title: const Text('Add tracking', style: TextStyle(color: Colors.white)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButtonFormField<String>(
          initialValue: _carrier,
          dropdownColor: _cardDark,
          style: const TextStyle(color: Colors.white),
          items: [for (final c in _carriers) DropdownMenuItem(value: c, child: Text(c))],
          onChanged: (v) => setState(() => _carrier = v ?? 'USPS'),
          decoration: const InputDecoration(
            labelText: 'Carrier', labelStyle: TextStyle(color: _mutedDark),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _num, autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'Tracking number', labelStyle: TextStyle(color: _mutedDark),
          ),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(color: _mutedDark))),
        TextButton(
          onPressed: () {
            final n = _num.text.trim();
            if (n.isEmpty) return;
            Navigator.pop(context, (num: n, carrier: _carrier));
          },
          child: const Text('Save', style: TextStyle(color: _purple, fontWeight: FontWeight.w800)),
        ),
      ],
    );
  }
}

class _ReasonDialog extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = TextEditingController();
    return AlertDialog(
      backgroundColor: _cardDark,
      title: const Text('Cancel + refund', style: TextStyle(color: Colors.white)),
      content: TextField(
        controller: c, autofocus: true, maxLines: 3,
        style: const TextStyle(color: Colors.white),
        decoration: const InputDecoration(
          labelText: 'Reason (sent to customer)',
          labelStyle: TextStyle(color: _mutedDark),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Keep order', style: TextStyle(color: _mutedDark))),
        TextButton(
          onPressed: () => Navigator.pop(context, c.text.trim().isEmpty ? 'Cancelled by support.' : c.text.trim()),
          child: const Text('Cancel + refund', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w800)),
        ),
      ],
    );
  }
}
