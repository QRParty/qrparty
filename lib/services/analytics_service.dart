import 'package:cloud_functions/cloud_functions.dart';

class WebsiteAnalytics {
  final int pageViews;
  final int sessions;
  final int newUsers;
  final List<({String key, int count})> topPages;
  final List<({String key, int count})> topSources;
  final Map<String, int> eventCounts;
  final List<({String date, int count})> timeSeries;
  final bool fromCache;
  final bool stale;
  final int cacheAgeSeconds;
  final String? error;
  final String dateRange;

  const WebsiteAnalytics({
    required this.pageViews,
    required this.sessions,
    required this.newUsers,
    required this.topPages,
    required this.topSources,
    required this.eventCounts,
    required this.timeSeries,
    required this.fromCache,
    required this.stale,
    required this.cacheAgeSeconds,
    required this.dateRange,
    this.error,
  });

  static WebsiteAnalytics fromMap(Map<String, dynamic> m) {
    final totals = (m['totals'] as Map?)?.cast<String, dynamic>() ?? const {};
    List<({String key, int count})> parseList(dynamic raw) {
      final l = (raw as List?) ?? const [];
      return l.map((e) {
        final em = (e as Map).cast<String, dynamic>();
        return (
          key: (em['key'] as String?) ?? '',
          count: (em['count'] as num?)?.toInt() ?? 0,
        );
      }).toList();
    }
    final ts = ((m['timeSeries'] as List?) ?? const []).map((e) {
      final em = (e as Map).cast<String, dynamic>();
      return (
        date: (em['date'] as String?) ?? '',
        count: (em['count'] as num?)?.toInt() ?? 0,
      );
    }).toList();
    return WebsiteAnalytics(
      pageViews: (totals['pageViews'] as num?)?.toInt() ?? 0,
      sessions:  (totals['sessions']  as num?)?.toInt() ?? 0,
      newUsers:  (totals['newUsers']  as num?)?.toInt() ?? 0,
      topPages:    parseList(m['topPages']),
      topSources:  parseList(m['topSources']),
      eventCounts: ((m['eventCounts'] as Map?) ?? const {})
          .map((k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 0)),
      timeSeries:  ts,
      fromCache:        m['fromCache']        == true,
      stale:            m['stale']            == true,
      cacheAgeSeconds:  (m['cacheAgeSeconds'] as num?)?.toInt() ?? 0,
      error:            m['error']            as String?,
      dateRange:        (m['dateRange']       as String?) ?? '30d',
    );
  }
}

class WebsiteAnalyticsService {
  /// dateRange: '7d' | '30d' | '90d' | 'all'. force=true bypasses the
  /// 15-minute server cache (used by pull-to-refresh).
  static Future<WebsiteAnalytics> fetch({String dateRange = '30d', bool force = false}) async {
    final res = await FirebaseFunctions.instance
        .httpsCallable('getWebsiteAnalytics')
        .call({'dateRange': dateRange, 'force': force});
    final data = (res.data as Map).cast<String, dynamic>();
    return WebsiteAnalytics.fromMap(data);
  }
}
