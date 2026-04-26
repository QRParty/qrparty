import 'dart:math' show pi;
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../utils.dart';
import '../widgets/website_analytics_section.dart';
import '../widgets/admin_order_table.dart';

// ── Theme palette ──────────────────────────────────────────────
// Light + dark variants for the four surface colors; accents stay the same.
// Instance getters inside each State class pick the right variant from
// Theme.of(context) at build time, so the screen follows the ThemeNotifier.
const _bgDark      = Color(0xFF2D3047); // dark-mode scaffold
const _bgLight     = Color(0xFFF8F7FC);
const _cardDark    = Color(0xFF383B56);
const _cardLight   = Colors.white;
const _borderDark  = Color(0xFF4A4E6B);
const _borderLight = Color(0xFFE0E8E0);
const _mutedDark   = Color(0xFFA9A6B8);
const _mutedLight  = Color(0xFF8892A4);
const _purple      = Color(0xFF9C7FD4);
const _gold        = Color(0xFFC8922A);

class _HeatGaugePainter extends CustomPainter {
  final double fraction;
  final Color color;
  final Color trackColor;
  final Color labelColor;

  const _HeatGaugePainter({
    required this.fraction,
    required this.color,
    required this.trackColor,
    required this.labelColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.82;
    final radius = size.width * 0.38;
    const strokeWidth = 16.0;

    // Background track
    final bgPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: radius),
      pi, pi, false, bgPaint,
    );

    // Filled arc
    if (fraction > 0.01) {
      final fillPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: radius),
        pi, pi * fraction, false, fillPaint,
      );
    }

    // $0 / $2k axis labels
    final tp = TextPainter(textDirection: TextDirection.ltr);
    void drawLabel(String text, Offset offset) {
      tp.text = TextSpan(
        text: text,
        style: TextStyle(
            fontSize: 11, color: labelColor, fontFamily: 'Nunito'),
      );
      tp.layout();
      tp.paint(canvas, offset - Offset(tp.width / 2, tp.height / 2));
    }

    final left  = Offset(cx - radius, cy);
    final right = Offset(cx + radius, cy);
    drawLabel('\$0',  left  + const Offset(0, 14));
    drawLabel('\$2k', right + const Offset(0, 14));
  }

  @override
  bool shouldRepaint(_HeatGaugePainter old) =>
      old.fraction   != fraction   ||
      old.color      != color      ||
      old.trackColor != trackColor ||
      old.labelColor != labelColor;
}

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});
  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _events = [];
  String? _error;

  bool _isAdmin = false;
  bool _revenueLoading = false;
  double? _stripeRevenue;
  int? _chargeCount;
  DateTime? _revenueUpdatedAt;
  String? _revenueError;

  final GlobalKey<WebsiteAnalyticsSectionState> _websiteKey = GlobalKey<WebsiteAnalyticsSectionState>();

  // Theme-aware color getters — resolve light vs dark variant from the current Theme.
  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;

  @override
  void initState() {
    super.initState();
    _loadEvents();
    _checkAdmin();
  }

  Future<void> _loadEvents() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) { setState(() => _loading = false); return; }
    setState(() { _loading = true; _error = null; });
    try {
      final snap = await FirebaseFirestore.instance
          .collection('events')
          .where('hostId', isEqualTo: user.uid)
          .get();
      if (mounted) {
        setState(() {
          _events = snap.docs
              .map((d) => {'id': d.id, ...d.data()})
              .where((e) => (e['isDraft'] as bool?) != true)
              .toList();
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  Future<void> _checkAdmin() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      if (doc.data()?['isAdmin'] == true && mounted) {
        setState(() => _isAdmin = true);
        _loadStripeRevenue();
      }
    } catch (_) {}
  }

  Future<void> _loadStripeRevenue() async {
    if (!_isAdmin) return;
    setState(() { _revenueLoading = true; _revenueError = null; });
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('getStripeRevenue')
          .call();
      if (mounted) {
        setState(() {
          _stripeRevenue = (result.data['totalDollars'] as num).toDouble();
          _chargeCount   = (result.data['chargeCount']   as num).toInt();
          _revenueUpdatedAt = DateTime.now();
          _revenueLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _revenueLoading = false;
          _revenueError = 'Could not load revenue';
        });
      }
    }
  }

  // ── Aggregates ───────────────────────────────────────────────

  int get _totalRsvps => _events.fold(0, (s, e) =>
      s +
      ((e['yes']   as num?)?.toInt() ?? 0) +
      ((e['maybe'] as num?)?.toInt() ?? 0) +
      ((e['no']    as num?)?.toInt() ?? 0));

  double get _avgAttendanceRate {
    final withGuests = _events.where((e) {
      final t = ((e['yes']   as num?)?.toInt() ?? 0) +
                ((e['maybe'] as num?)?.toInt() ?? 0) +
                ((e['no']    as num?)?.toInt() ?? 0);
      return t > 0;
    }).toList();
    if (withGuests.isEmpty) return 0;
    final sum = withGuests.fold<double>(0, (s, e) {
      final yes   = (e['yes']   as num?)?.toDouble() ?? 0;
      final total = yes +
                    ((e['maybe'] as num?)?.toDouble() ?? 0) +
                    ((e['no']    as num?)?.toDouble() ?? 0);
      return s + (total > 0 ? yes / total : 0);
    });
    return sum / withGuests.length;
  }

  String get _mostPopularType {
    final counts = <String, int>{};
    for (final e in _events) {
      final type = (e['eventType'] as String?)?.isNotEmpty == true
          ? e['eventType'] as String
          : 'Custom';
      counts[type] = (counts[type] ?? 0) + 1;
    }
    if (counts.isEmpty) return '—';
    return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  String get _mostPopularEmoji {
    final name = _mostPopularType;
    return eventTypes
        .firstWhere((t) => t.name == name, orElse: () => eventTypes.last)
        .emoji;
  }

  int get _totalPhotos => _events.fold(
      0, (s, e) => s + ((e['photoCount'] as num?)?.toInt() ?? 0));

  double get _totalWishlistAmount {
    double total = 0;
    for (final e in _events) {
      for (final item in (e['wishlist'] as List<dynamic>? ?? [])) {
        if (item is Map) {
          total += (item['contributed'] as num?)?.toDouble() ?? 0;
        }
      }
    }
    return total;
  }

  Map<String, dynamic>? get _bestEvent {
    if (_events.isEmpty) return null;
    return _events.reduce((a, b) =>
        ((a['yes'] as num?)?.toInt() ?? 0) >= ((b['yes'] as num?)?.toInt() ?? 0)
            ? a
            : b);
  }

  // Last 10 by date descending, then reversed for left→right chart
  List<Map<String, dynamic>> get _chartEvents {
    final sorted = List<Map<String, dynamic>>.from(_events)
      ..sort((a, b) {
        final aDate = (a['date'] as Timestamp?)?.toDate() ?? DateTime(1970);
        final bDate = (b['date'] as Timestamp?)?.toDate() ?? DateTime(1970);
        return bDate.compareTo(aDate);
      });
    return sorted.take(10).toList().reversed.toList();
  }

  // ── Build ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final fg = _isDark ? Colors.white : AppColors.dark;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: fg),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Analytics',
          style: TextStyle(fontFamily: 'FredokaOne', fontSize: 22, color: fg),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh, color: fg),
            onPressed: () { _loadEvents(); if (_isAdmin) _loadStripeRevenue(); },
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _purple))
          : _error != null
              ? _buildError()
              : _events.isEmpty
                  ? _buildEmpty()
                  : _buildContent(),
    );
  }

  Widget _buildEmpty() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Text('📊', style: TextStyle(fontSize: 56)),
      const SizedBox(height: 16),
      Text('No event data yet',
          style: TextStyle(fontFamily: 'FredokaOne', fontSize: 24, color: _isDark ? Colors.white : AppColors.dark)),
      const SizedBox(height: 8),
      Text('Create your first event to see analytics here.',
          style: TextStyle(fontFamily: 'Nunito', fontSize: 14, color: _muted)),
    ]),
  );

  Widget _buildError() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
      const SizedBox(height: 12),
      Text('Failed to load analytics',
          style: TextStyle(color: _isDark ? Colors.white : AppColors.dark, fontSize: 16, fontFamily: 'Nunito')),
      const SizedBox(height: 8),
      TextButton(
        onPressed: _loadEvents,
        child: const Text('Retry', style: TextStyle(color: _purple)),
      ),
    ]),
  );

  Widget _buildContent() {
    final best = _bestEvent;
    final chartData = _chartEvents;
    return RefreshIndicator(
      onRefresh: () async {
        await _loadEvents();
        if (_isAdmin) {
          await _loadStripeRevenue();
          await _websiteKey.currentState?.refresh(force: true);
        }
      },
      color: _purple,
      backgroundColor: _card,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [

          // ── Admin revenue gauge ───────────────────────────────
          if (_isAdmin) ...[
            _sectionHeader('Revenue', 'admin only'),
            const SizedBox(height: 10),
            _revenueGaugeCard(),
            const SizedBox(height: 24),
            // GA4 traffic. Self-managed loading + caching; pull-to-refresh
            // forces cache bypass via the GlobalKey above.
            WebsiteAnalyticsSection(key: _websiteKey),
            const SizedBox(height: 24),
            // Manual fulfillment center — orders awaiting Vistaprint push,
            // status pills, copy-address-to-clipboard, profit math, etc.
            _sectionHeader('Order Fulfillment', 'admin only'),
            const SizedBox(height: 10),
            const AdminOrderTable(),
            const SizedBox(height: 24),
          ],

          // ── Overview ─────────────────────────────────────────
          _sectionHeader('Overview', '${_events.length} events total'),
          const SizedBox(height: 10),
          Row(children: [
            _statTile(
              icon: Icons.people_outline,
              iconColor: _purple,
              value: '$_totalRsvps',
              label: 'Total RSVPs',
            ),
            const SizedBox(width: 10),
            _statTile(
              icon: Icons.thumb_up_alt_outlined,
              iconColor: AppColors.green,
              value: '${(_avgAttendanceRate * 100).toStringAsFixed(0)}%',
              label: 'Avg Attendance',
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            _statTile(
              emoji: _mostPopularEmoji,
              iconColor: _gold,
              value: _mostPopularType,
              label: 'Top Event Type',
            ),
            const SizedBox(width: 10),
            _statTile(
              icon: Icons.photo_camera_outlined,
              iconColor: _purple,
              value: '$_totalPhotos',
              label: 'Photo Uploads',
            ),
          ]),
          const SizedBox(height: 10),
          _wishlistTile(),
          const SizedBox(height: 24),

          // ── Best event ───────────────────────────────────────
          if (best != null) ...[
            _sectionHeader('Best Performing Event', ''),
            const SizedBox(height: 10),
            _bestEventCard(best),
            const SizedBox(height: 24),
          ],

          // ── Bar chart ────────────────────────────────────────
          if (chartData.isNotEmpty) ...[
            _sectionHeader('RSVPs Per Event', 'last ${chartData.length}'),
            const SizedBox(height: 10),
            _barChartCard(chartData),
          ],
        ],
      ),
    );
  }

  // ── Widgets ──────────────────────────────────────────────────

  Widget _sectionHeader(String title, String sub) => Row(
    crossAxisAlignment: CrossAxisAlignment.baseline,
    textBaseline: TextBaseline.alphabetic,
    children: [
      Text(title,
          style: TextStyle(
              fontFamily: 'FredokaOne', fontSize: 18, color: _isDark ? Colors.white : AppColors.dark)),
      if (sub.isNotEmpty) ...[
        const SizedBox(width: 8),
        Text(sub,
            style: TextStyle(
                fontFamily: 'Nunito', fontSize: 12, color: _muted)),
      ],
    ],
  );

  Widget _statTile({
    IconData? icon,
    String? emoji,
    required Color iconColor,
    required String value,
    required String label,
  }) =>
      Expanded(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (icon != null)
              Icon(icon, color: iconColor, size: 20)
            else
              Text(emoji ?? '✨', style: const TextStyle(fontSize: 20)),
            const SizedBox(height: 10),
            Text(
              value,
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: iconColor,
                  fontFamily: 'Nunito'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    fontSize: 12, color: _muted, fontFamily: 'Nunito')),
          ]),
        ),
      );

  Widget _wishlistTile() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border)),
    child: Row(children: [
      Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
            color: _gold.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12)),
        child: const Center(
            child: Icon(Icons.card_giftcard_outlined, color: _gold, size: 22)),
      ),
      const SizedBox(width: 14),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          '\$${_totalWishlistAmount.toStringAsFixed(2)}',
          style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: _gold,
              fontFamily: 'Nunito'),
        ),
        Text('Total wishlist contributions',
            style:
                TextStyle(fontSize: 12, color: _muted, fontFamily: 'Nunito')),
      ]),
    ]),
  );

  Widget _bestEventCard(Map<String, dynamic> event) {
    final yes   = (event['yes']   as num?)?.toInt() ?? 0;
    final maybe = (event['maybe'] as num?)?.toInt() ?? 0;
    final no    = (event['no']    as num?)?.toInt() ?? 0;
    final total = yes + maybe + no;
    final ts    = event['date'] as Timestamp?;
    final date  = ts?.toDate();
    const months = [
      'Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec'
    ];
    final dateStr = date != null
        ? '${months[date.month - 1]} ${date.day}, ${date.year}'
        : '';
    final attendancePct =
        total > 0 ? (yes / total * 100).toStringAsFixed(0) : '0';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _gold.withValues(alpha: 0.45), width: 1.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text((event['eventEmoji'] as String?) ?? '🎉',
              style: const TextStyle(fontSize: 26)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                (event['title'] as String?) ?? 'Untitled',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: _isDark ? Colors.white : AppColors.dark,
                    fontFamily: 'Nunito'),
              ),
              if (dateStr.isNotEmpty)
                Text(dateStr,
                    style: TextStyle(
                        fontSize: 12, color: _muted, fontFamily: 'Nunito')),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8)),
            child: const Text('⭐ Best',
                style: TextStyle(
                    fontSize: 11,
                    color: _gold,
                    fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          _miniStat('$yes',            'Going',      AppColors.green),
          const SizedBox(width: 20),
          _miniStat('$maybe',          'Maybe',      _purple),
          const SizedBox(width: 20),
          _miniStat('$no',             "Can't go",   _muted),
          const SizedBox(width: 20),
          _miniStat('$attendancePct%', 'Attendance', _gold),
        ]),
      ]),
    );
  }

  Widget _miniStat(String value, String label, Color color) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(value,
          style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: color,
              fontFamily: 'Nunito')),
      Text(label,
          style: TextStyle(
              fontSize: 11, color: _muted, fontFamily: 'Nunito')),
    ],
  );

  // ── Admin revenue gauge ──────────────────────────────────────

  Widget _revenueGaugeCard() {
    const maxRevenue = 2000.0;
    final revenue = _stripeRevenue ?? 0.0;
    final fraction = (revenue / maxRevenue).clamp(0.0, 1.0);
    final Color gaugeColor = fraction < 0.33
        ? AppColors.green
        : fraction < 0.66
            ? _gold
            : Colors.redAccent;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.30)),
      ),
      child: Column(children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.redAccent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text('ADMIN',
                style: TextStyle(
                    fontSize: 10,
                    color: Colors.redAccent,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1)),
          ),
          const Spacer(),
          if (_revenueUpdatedAt != null)
            Text(
              'Updated ${_timeAgo(_revenueUpdatedAt!)}',
              style: TextStyle(fontSize: 11, color: _muted, fontFamily: 'Nunito'),
            ),
          if (_revenueLoading) ...[
            const SizedBox(width: 8),
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(color: _purple, strokeWidth: 2),
            ),
          ] else ...[
            const SizedBox(width: 6),
            GestureDetector(
              onTap: _loadStripeRevenue,
              child: Icon(Icons.refresh, size: 16, color: _muted),
            ),
          ],
        ]),
        const SizedBox(height: 16),
        SizedBox(
          height: 150,
          width: double.infinity,
          child: _revenueLoading && _stripeRevenue == null
              ? const Center(child: CircularProgressIndicator(color: _purple))
              : _revenueError != null && _stripeRevenue == null
                  ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Text(_revenueError!,
                          style: TextStyle(
                              color: _muted, fontSize: 13, fontFamily: 'Nunito')),
                      TextButton(
                        onPressed: _loadStripeRevenue,
                        child: const Text('Retry',
                            style: TextStyle(color: _purple)),
                      ),
                    ])
                  : CustomPaint(
                      painter: _HeatGaugePainter(
                          fraction: fraction,
                          color: gaugeColor,
                          trackColor: _border,
                          labelColor: _muted),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            '\$${revenue.toStringAsFixed(2)}',
                            style: TextStyle(
                                fontSize: 34,
                                fontWeight: FontWeight.w900,
                                color: gaugeColor,
                                fontFamily: 'Nunito'),
                          ),
                          Text(
                            'of \$${maxRevenue.toStringAsFixed(0)} goal',
                            style: TextStyle(
                                fontSize: 13,
                                color: _muted,
                                fontFamily: 'Nunito'),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
        ),
        if (_chargeCount != null) ...[
          const SizedBox(height: 6),
          Text(
            '$_chargeCount successful payment${_chargeCount == 1 ? '' : 's'}',
            style: TextStyle(fontSize: 12, color: _muted, fontFamily: 'Nunito'),
          ),
        ],
      ]),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Widget _barChartCard(List<Map<String, dynamic>> events) {
    final maxYes = events.fold<int>(
        1,
        (m, e) =>
            ((e['yes'] as num?)?.toInt() ?? 0) > m
                ? (e['yes'] as num).toInt()
                : m);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Y-axis max label
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 4),
            child: Text('$maxYes',
                style: TextStyle(
                    fontSize: 10, color: _muted, fontFamily: 'Nunito')),
          ),

          // Bars
          SizedBox(
            height: 120,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: events.map((e) {
                final yes  = (e['yes'] as num?)?.toInt() ?? 0;
                final frac = yes / maxYes;
                // Bar max 106 (not 108) leaves ~2px of breathing room under
                // the count label so the column doesn't overflow 120px.
                final barH = (frac * 106).clamp(3.0, 106.0);
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (yes > 0)
                          Text('$yes',
                              style: TextStyle(
                                  fontSize: 8,
                                  color: _muted,
                                  fontFamily: 'Nunito')),
                        const SizedBox(height: 2),
                        Container(
                          height: barH,
                          decoration: BoxDecoration(
                            color: _purple,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),

          // Baseline divider
          Container(
              height: 1,
              color: _border,
              margin: const EdgeInsets.symmetric(vertical: 6)),

          // Emoji x-axis labels
          Row(
            children: events
                .map((e) => Expanded(
                      child: Center(
                        child: Text(
                          (e['eventEmoji'] as String?) ?? '🎉',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }
}
