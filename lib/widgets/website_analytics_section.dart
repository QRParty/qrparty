import 'package:flutter/material.dart';
import '../services/analytics_service.dart';
import '../utils.dart';

const _cardDark    = Color(0xFF383B56);
const _cardLight   = Colors.white;
const _borderDark  = Color(0xFF4A4E6B);
const _borderLight = Color(0xFFE0E8E0);
const _mutedDark   = Color(0xFFA9A6B8);
const _mutedLight  = Color(0xFF8892A4);
const _purple      = Color(0xFF9C7FD4);
const _gold        = Color(0xFFC8922A);

const _ranges = ['7d', '30d', '90d'];

class WebsiteAnalyticsSection extends StatefulWidget {
  const WebsiteAnalyticsSection({super.key});
  @override
  State<WebsiteAnalyticsSection> createState() => WebsiteAnalyticsSectionState();
}

class WebsiteAnalyticsSectionState extends State<WebsiteAnalyticsSection> {
  String _range = '30d';
  bool _loading = true;
  WebsiteAnalytics? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Public — parent screen calls this from its pull-to-refresh handler.
  Future<void> refresh({bool force = false}) => _load(force: force);

  Future<void> _load({bool force = false}) async {
    setState(() { _loading = true; _error = null; });
    try {
      final d = await WebsiteAnalyticsService.fetch(dateRange: _range, force: force);
      if (!mounted) return;
      setState(() { _data = d; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      // Map raw exception strings to a friendly tag so the empty-state UI
      // can show "Analytics unavailable" instead of the
      // `[firebase_functions/not-found]` red-banner message that means
      // nothing to a non-engineer. The full exception is logged so the
      // root cause is still recoverable from console output.
      debugPrint('[WebsiteAnalytics] fetch failed: $e');
      final raw = e.toString();
      String friendly;
      if (raw.contains('not-found')) {
        friendly = 'unavailable';
      } else if (raw.contains('failed-precondition')) {
        friendly = 'not-configured';
      } else if (raw.contains('permission-denied') || raw.contains('unauthenticated')) {
        friendly = 'permission-denied';
      } else if (raw.contains('unavailable') || raw.contains('SocketException')) {
        friendly = 'offline';
      } else {
        friendly = 'unavailable';
      }
      setState(() { _error = friendly; _loading = false; });
    }
  }

  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;
  Color get _fg     => _isDark ? Colors.white : AppColors.dark;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        const SizedBox(height: 12),
        _rangeToggle(),
        const SizedBox(height: 12),
        if (_loading && _data == null) ..._shimmerScaffold()
        else if (_data == null) _emptyAll()
        else _renderData(_data!),
      ],
    );
  }

  Widget _header() {
    final age = _data?.cacheAgeSeconds ?? 0;
    final stale = _data?.stale == true;
    final cacheNote = _data?.fromCache == true && age > 0
        ? 'Cached ${_formatAge(age)} ago${stale ? ' · stale' : ''}'
        : null;
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(
            'Website Traffic',
            style: TextStyle(fontFamily: 'FredokaOne', fontSize: 22, color: _gold),
          ),
          if (cacheNote != null) ...[
            const SizedBox(height: 2),
            Text(cacheNote, style: TextStyle(fontSize: 11, color: _muted, fontWeight: FontWeight.w600)),
          ],
        ]),
      ),
      IconButton(
        tooltip: 'Refresh',
        onPressed: _loading ? null : () => _load(force: true),
        icon: Icon(Icons.refresh, color: _muted, size: 20),
      ),
    ]);
  }

  Widget _rangeToggle() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Row(children: [
        for (final r in _ranges)
          Expanded(
            child: GestureDetector(
              onTap: _loading
                  ? null
                  : () { setState(() => _range = r); _load(); },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: _range == r ? _purple : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Center(
                  child: Text(r.toUpperCase(),
                      style: TextStyle(
                        color: _range == r ? Colors.white : _muted,
                        fontWeight: FontWeight.w800, fontSize: 12,
                      )),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _renderData(WebsiteAnalytics d) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: _statCard('Page Views', d.pageViews, _purple)),
        const SizedBox(width: 10),
        Expanded(child: _statCard('Sessions', d.sessions, _gold)),
        const SizedBox(width: 10),
        Expanded(child: _statCard('New Users', d.newUsers, AppColors.green)),
      ]),
      const SizedBox(height: 12),
      _sparklineCard(d.timeSeries),
      const SizedBox(height: 12),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: _topListCard('Top Pages',  d.topPages,  emptyHint: 'No page data yet')),
        const SizedBox(width: 10),
        Expanded(child: _topListCard('Top Sources', d.topSources, emptyHint: 'No referrers yet')),
      ]),
      const SizedBox(height: 12),
      _keyEventsCard(d.eventCounts),
    ]);
  }

  Widget _statCard(String label, int value, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: _card, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_formatBigNumber(value),
            style: TextStyle(fontFamily: 'FredokaOne', fontSize: 26, color: accent, height: 1.0)),
        const SizedBox(height: 6),
        Text(label.toUpperCase(),
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: _muted, letterSpacing: 1.4)),
      ]),
    );
  }

  Widget _sparklineCard(List<({String date, int count})> series) {
    return Container(
      height: 110,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: _card, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('PAGE VIEWS / DAY',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: _muted, letterSpacing: 1.4)),
        const SizedBox(height: 8),
        Expanded(
          child: series.isEmpty
              ? Center(child: Text('No data in this range', style: TextStyle(color: _muted, fontSize: 12)))
              : LayoutBuilder(builder: (ctx, c) => CustomPaint(
                    size: Size(c.maxWidth, c.maxHeight),
                    painter: _SparklinePainter(
                      values: series.map((p) => p.count).toList(),
                      lineColor: _purple,
                      fillColor: _purple.withValues(alpha: 0.18),
                    ),
                  )),
        ),
      ]),
    );
  }

  Widget _topListCard(String title, List<({String key, int count})> items, {required String emptyHint}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: BoxDecoration(
        color: _card, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title.toUpperCase(),
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: _muted, letterSpacing: 1.4)),
        const SizedBox(height: 8),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(emptyHint, style: TextStyle(fontSize: 12, color: _muted)),
          )
        else
          ...items.map((row) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  Expanded(
                    child: Text(
                      row.key.isEmpty ? '—' : row.key,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: _fg, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(_formatBigNumber(row.count),
                      style: const TextStyle(fontSize: 12.5, color: _purple, fontWeight: FontWeight.w800)),
                ]),
              )),
      ]),
    );
  }

  Widget _keyEventsCard(Map<String, int> counts) {
    final rows = <(String, int, IconData, Color)>[
      ('App downloads',           counts['download_clicked']         ?? 0, Icons.download_outlined,         AppColors.green),
      ('Business page interest',  counts['business_teaser_clicked']  ?? 0, Icons.business_outlined,         _purple),
      ('Trial signups initiated', counts['business_trial_clicked']   ?? 0, Icons.workspace_premium_outlined, _gold),
      ('RSVPs from web',          counts['rsvp_button_clicked']      ?? 0, Icons.thumb_up_outlined,         AppColors.green),
      ('Calendar adds',           counts['add_to_calendar_clicked']  ?? 0, Icons.calendar_today_outlined,   _purple),
      ('Event page views',        counts['event_page_loaded']        ?? 0, Icons.celebration_outlined,      _gold),
      ('Org page views',          counts['org_page_loaded']          ?? 0, Icons.apartment_outlined,        _purple),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
      decoration: BoxDecoration(
        color: _card, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('KEY EVENTS',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: _muted, letterSpacing: 1.4)),
        const SizedBox(height: 6),
        for (final (label, count, icon, color) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(children: [
              Container(
                width: 28, height: 28,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 16, color: color),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(label,
                  style: TextStyle(fontSize: 13, color: _fg, fontWeight: FontWeight.w600))),
              Text(_formatBigNumber(count),
                  style: TextStyle(fontSize: 14, color: color, fontWeight: FontWeight.w800)),
            ]),
          ),
      ]),
    );
  }

  Widget _emptyAll() {
    String headline;
    String? subtitle;
    if (_error == null) {
      headline = 'No data yet';
    } else {
      headline = 'Analytics unavailable';
      switch (_error) {
        case 'not-configured':
          subtitle = 'GA4 property isn\'t configured for this project yet.';
        case 'permission-denied':
          subtitle = 'You don\'t have access to this dashboard.';
        case 'offline':
          subtitle = 'Couldn\'t reach the analytics server. Check your connection.';
        case 'unavailable':
        default:
          subtitle = 'Try again in a moment — if this keeps happening, contact support.';
      }
    }
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _card, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(children: [
        Icon(
          _error == null ? Icons.bar_chart_outlined : Icons.cloud_off_outlined,
          size: 32, color: _muted,
        ),
        const SizedBox(height: 8),
        Text(headline,
            style: TextStyle(color: _fg, fontWeight: FontWeight.w800, fontSize: 14)),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(subtitle, textAlign: TextAlign.center,
              style: TextStyle(color: _muted, fontSize: 12, height: 1.4)),
        ],
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: () => _load(force: true),
          icon: const Icon(Icons.refresh, size: 16, color: _purple),
          label: const Text('Retry', style: TextStyle(color: _purple, fontWeight: FontWeight.w800)),
        ),
      ]),
    );
  }

  // ── Loading skeletons ─────────────────────────────────────────
  List<Widget> _shimmerScaffold() => [
    Row(children: [
      Expanded(child: _shimmerBox(72)),
      const SizedBox(width: 10),
      Expanded(child: _shimmerBox(72)),
      const SizedBox(width: 10),
      Expanded(child: _shimmerBox(72)),
    ]),
    const SizedBox(height: 12),
    _shimmerBox(110),
    const SizedBox(height: 12),
    Row(children: [
      Expanded(child: _shimmerBox(150)),
      const SizedBox(width: 10),
      Expanded(child: _shimmerBox(150)),
    ]),
    const SizedBox(height: 12),
    _shimmerBox(280),
  ];

  Widget _shimmerBox(double h) {
    return _Shimmer(
      child: Container(
        height: h,
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _border),
        ),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────
  String _formatAge(int seconds) {
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${(seconds / 60).floor()}m';
    return '${(seconds / 3600).floor()}h';
  }

  String _formatBigNumber(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000)    return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }
}

// Tiny shimmer — animates opacity on a child to suggest loading without
// pulling in the `shimmer` package.
class _Shimmer extends StatefulWidget {
  final Widget child;
  const _Shimmer({required this.child});
  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => Opacity(opacity: 0.55 + 0.25 * _c.value, child: child),
      child: widget.child,
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<int> values;
  final Color lineColor;
  final Color fillColor;
  _SparklinePainter({required this.values, required this.lineColor, required this.fillColor});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxV = values.reduce((a, b) => a > b ? a : b).toDouble();
    final span = maxV == 0 ? 1.0 : maxV;
    final stepX = values.length == 1 ? size.width : size.width / (values.length - 1);

    final path = Path();
    final fill = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i * stepX;
      final y = size.height - (values[i] / span) * (size.height - 4) - 2;
      if (i == 0) {
        path.moveTo(x, y);
        fill.moveTo(x, size.height);
        fill.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fill.lineTo(x, y);
      }
    }
    fill.lineTo(size.width, size.height);
    fill.close();

    canvas.drawPath(fill, Paint()..color = fillColor..style = PaintingStyle.fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.values != values || old.lineColor != lineColor || old.fillColor != fillColor;
}
