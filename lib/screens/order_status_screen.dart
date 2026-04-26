import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils.dart';
import '../models/merch_order.dart';

const _bgDark      = Color(0xFF2D3047);
const _bgLight     = Color(0xFFF8F7FC);
const _cardDark    = Color(0xFF383B56);
const _cardLight   = Colors.white;
const _borderDark  = Color(0xFF4A4E6B);
const _borderLight = Color(0xFFE0E8E0);
const _mutedDark   = Color(0xFFA9A6B8);
const _mutedLight  = Color(0xFF8892A4);
const _purple      = Color(0xFF9C7FD4);
const _gold        = Color(0xFFC8922A);

class OrderStatusScreen extends StatelessWidget {
  const OrderStatusScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? _bgDark : _bgLight;
    final muted = isDark ? _mutedDark : _mutedLight;
    final fg = isDark ? Colors.white : AppColors.dark;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg, elevation: 0, surfaceTintColor: Colors.transparent,
        title: Text('My Orders', style: TextStyle(fontWeight: FontWeight.w700, color: fg)),
      ),
      body: uid == null
          ? const Center(child: Text('Sign in to view orders'))
          : StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('orders')
                  .where('userId', isEqualTo: uid)
                  .orderBy('createdAt', descending: true)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator(color: _purple));
                }
                final docs = snap.data?.docs ?? [];
                if (docs.isEmpty) {
                  return Center(child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text('📦', style: TextStyle(fontSize: 56)),
                      const SizedBox(height: 14),
                      Text('No orders yet', style: TextStyle(fontFamily: 'FredokaOne', fontSize: 22, color: fg)),
                      const SizedBox(height: 8),
                      Text(
                        'After you generate a QR for an event, tap "Order Stickers" or "Order Invitations" from the QR screen.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13.5, color: muted, height: 1.5),
                      ),
                    ]),
                  ));
                }
                final orders = docs.map(MerchOrder.fromDoc).toList();
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  itemCount: orders.length,
                  itemBuilder: (_, i) => _OrderTile(order: orders[i], isDark: isDark),
                );
              },
            ),
    );
  }
}

class _OrderTile extends StatelessWidget {
  final MerchOrder order;
  final bool isDark;
  const _OrderTile({required this.order, required this.isDark});

  Color get _card   => isDark ? _cardDark   : _cardLight;
  Color get _border => isDark ? _borderDark : _borderLight;
  Color get _muted  => isDark ? _mutedDark  : _mutedLight;
  Color get _fg     => isDark ? Colors.white : AppColors.dark;

  Color _statusColor(MerchStatus s) => switch (s) {
    MerchStatus.delivered          => AppColors.green,
    MerchStatus.shipped            => _purple,
    MerchStatus.sentToPrinter      => _gold,
    MerchStatus.cancelled          => Colors.redAccent,
    MerchStatus.pendingFulfillment => _muted,
  };

  @override
  Widget build(BuildContext context) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final placedStr =
        '${months[order.createdAt.month - 1]} ${order.createdAt.day}, ${order.createdAt.year}';
    final isInvitation = order.productType == MerchProduct.invitation;
    final productLabel = isInvitation ? 'Invitations' : 'Stickers';
    final color = _statusColor(order.status);

    return GestureDetector(
      onTap: () => _showDetail(context),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _card, borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(isInvitation ? '✉️' : '🏷️', style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${order.packSize} pack · $productLabel',
                  style: TextStyle(color: _fg, fontWeight: FontWeight.w800, fontSize: 15)),
              const SizedBox(height: 2),
              Text('${order.eventName} · placed $placedStr',
                  style: TextStyle(color: _muted, fontSize: 12)),
            ])),
            _statusBadge(color),
          ]),
          const SizedBox(height: 10),
          _timeline(),
          if (order.trackingNumber != null && order.trackingNumber!.isNotEmpty) ...[
            const SizedBox(height: 10),
            _trackingTile(),
          ],
        ]),
      ),
    );
  }

  Widget _statusBadge(Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withValues(alpha: 0.45)),
    ),
    child: Text(order.status.label.toUpperCase(),
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
  );

  Widget _timeline() {
    const all = [
      MerchStatus.pendingFulfillment,
      MerchStatus.sentToPrinter,
      MerchStatus.shipped,
      MerchStatus.delivered,
    ];
    final reachedIndex = all.indexOf(order.status);
    if (order.status == MerchStatus.cancelled) {
      return Text('Cancelled', style: TextStyle(color: Colors.redAccent.shade100, fontSize: 12, fontWeight: FontWeight.w700));
    }
    return Row(children: [
      for (int i = 0; i < all.length; i++) ...[
        Expanded(child: Container(
          height: 4,
          decoration: BoxDecoration(
            color: i <= reachedIndex ? _purple : _border,
            borderRadius: BorderRadius.circular(2),
          ),
        )),
        if (i < all.length - 1) const SizedBox(width: 4),
      ],
    ]);
  }

  Widget _trackingTile() {
    return InkWell(
      onTap: () {
        final url = _trackingUrl();
        if (url != null) launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: _purple.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _purple.withValues(alpha: 0.40)),
        ),
        child: Row(children: [
          const Icon(Icons.local_shipping_outlined, size: 16, color: _purple),
          const SizedBox(width: 8),
          Expanded(child: Text(
            '${order.trackingCarrier ?? 'Tracking'}: ${order.trackingNumber}',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _purple, fontSize: 12, fontWeight: FontWeight.w800),
          )),
          const Icon(Icons.open_in_new, size: 14, color: _purple),
        ]),
      ),
    );
  }

  String? _trackingUrl() {
    final n = order.trackingNumber;
    if (n == null) return null;
    final c = (order.trackingCarrier ?? '').toLowerCase();
    if (c.contains('usps')) return 'https://tools.usps.com/go/TrackConfirmAction?tLabels=$n';
    if (c.contains('ups'))  return 'https://www.ups.com/track?tracknum=$n';
    if (c.contains('fedex'))return 'https://www.fedex.com/fedextrack/?trknbr=$n';
    return 'https://www.google.com/search?q=track+package+$n';
  }

  void _showDetail(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 24 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: _border, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 14),
          Text('Order #${order.id.substring(0, order.id.length.clamp(0, 8))}',
              style: const TextStyle(fontFamily: 'FredokaOne', fontSize: 22, color: Colors.white)),
          const SizedBox(height: 4),
          Text(order.eventName, style: TextStyle(color: _muted, fontSize: 13)),
          const SizedBox(height: 18),
          _detailRow('Product',  '${order.packSize} pack · ${order.productType == MerchProduct.invitation ? 'Invitations' : 'Stickers'}'),
          _detailRow('Theme',    order.themeKey == 'custom' ? 'Custom design' : themeByKey(order.themeKey).name),
          _detailRow('Status',   order.status.label),
          _detailRow('Total',    MerchPricing.format(order.retailTotalCents)),
          _detailRow('Shipping', '${order.shippingAddress.formatted}\n${order.shippingSpeed == MerchShipping.expedited ? "Expedited (2–3 days)" : "Standard (5–7 days)"}'),
          if (order.estimatedDelivery != null)
            _detailRow('Est. delivery', _formatDate(order.estimatedDelivery!)),
          if (order.statusHistory.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('TIMELINE',
                style: TextStyle(color: _mutedDark, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
            const SizedBox(height: 6),
            for (final h in order.statusHistory.reversed) _timelineRow(h),
          ],
        ]),
      ),
    );
  }

  Widget _detailRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 110, child: Text(label,
          style: const TextStyle(color: _mutedDark, fontSize: 12, fontWeight: FontWeight.w700))),
      Expanded(child: Text(value,
          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600, height: 1.4))),
    ]),
  );

  Widget _timelineRow(Map<String, dynamic> h) {
    final at = (h['at'] as Timestamp?)?.toDate();
    final status = h['status'] as String? ?? '';
    final note = h['note'] as String? ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(padding: EdgeInsets.only(top: 5), child: Icon(Icons.circle, size: 6, color: _purple)),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(MerchStatusName.parse(status).label,
              style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w800)),
          if (at != null)
            Text(_formatDateTime(at), style: const TextStyle(color: _mutedDark, fontSize: 11)),
          if (note.isNotEmpty)
            Text(note, style: const TextStyle(color: _mutedDark, fontSize: 11.5, fontStyle: FontStyle.italic)),
        ])),
      ]),
    );
  }

  String _formatDate(DateTime d) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
  String _formatDateTime(DateTime d) {
    return '${_formatDate(d)} · ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
