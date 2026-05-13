import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils.dart';
import 'guest_event_screen.dart';

// ── Theme palette ──────────────────────────────────────────────
const _bgDark      = Color(0xFF2D3047);
const _bgLight     = Color(0xFFF8F7FC);
const _cardDark    = Color(0xFF383B56);
const _cardLight   = Colors.white;
const _borderDark  = Color(0xFF4A4E6B);
const _borderLight = Color(0xFFE0E8E0);
const _mutedDark   = Color(0xFFA9A6B8);
const _mutedLight  = Color(0xFF8892A4);
const _purple      = Color(0xFF9C7FD4);

/// Public-facing org page reached via the `/org/{orgId}` deep link
/// (org QR sticker on a storefront, business card, etc.). Renders the
/// org's name, logo, description, and a list of upcoming events from
/// the org owner + every linked Business — same `whereIn` fan-out
/// shape the HQ home feed uses post-Phase-4. Tapping an event pushes
/// [GuestEventScreen] for the guest RSVP flow.
///
/// Different surface from [OrganizationScreen]: that one is the org
/// owner's MANAGEMENT screen (logo upload, edit name/description,
/// publish toggles). This one is read-only and orgId-keyed — anyone
/// signed in can view any org's public events.
class PublicOrgScreen extends StatefulWidget {
  final String orgId;
  const PublicOrgScreen({super.key, required this.orgId});

  @override
  State<PublicOrgScreen> createState() => _PublicOrgScreenState();
}

class _PublicOrgScreenState extends State<PublicOrgScreen> {
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _orgSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _eventsSub;

  Map<String, dynamic>? _org;
  bool _orgLoaded = false;
  bool _orgMissing = false;
  List<Map<String, dynamic>> _events = [];
  bool _eventsLoaded = false;

  // Track the uid set the events listener is currently filtering on
  // so we don't tear down + re-listen on unrelated org-doc updates
  // (e.g. logo change). Mirrors the reconciliation pattern used by
  // [HeadquartersHomeFeedScreen].
  List<String> _eventsSubscribedFor = const [];

  @override
  void initState() {
    super.initState();
    _orgSub = FirebaseFirestore.instance
        .collection('organizations')
        .doc(widget.orgId)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      if (!snap.exists) {
        setState(() {
          _orgLoaded = true;
          _orgMissing = true;
          _org = null;
        });
        return;
      }
      setState(() {
        _orgLoaded = true;
        _orgMissing = false;
        _org = Map<String, dynamic>.from(snap.data() as Map);
      });
      _reconcileEventsSub();
    }, onError: (Object e) {
      debugPrint('[PublicOrg] org stream error: $e');
      if (!mounted) return;
      setState(() {
        _orgLoaded = true;
        _orgMissing = true;
      });
    });
  }

  @override
  void dispose() {
    _orgSub?.cancel();
    _eventsSub?.cancel();
    super.dispose();
  }

  // Same set of strings, ignoring order — skip no-op resubscribes when
  // an unrelated org-doc field changes.
  bool _sameSet(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    return a.toSet().containsAll(b);
  }

  void _reconcileEventsSub() {
    final org = _org;
    if (org == null) return;
    final ownerId = org['ownerId'] as String?;
    if (ownerId == null) return;
    final linkedUids = (org['linkedBusinessOwnerUids'] as List?)?.cast<String>() ?? const [];
    // Phase 1 caps linkedBusinessOwnerUids at 29 → with the owner uid
    // prepended, allUids stays ≤ 30 (Firestore whereIn's hard limit).
    final allUids = [ownerId, ...linkedUids];
    if (_sameSet(allUids, _eventsSubscribedFor)) return;
    _eventsSub?.cancel();
    _eventsSubscribedFor = allUids;
    _eventsSub = FirebaseFirestore.instance
        .collection('events')
        .where('hostId', whereIn: allUids)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _events = snap.docs.map((d) {
          final m = Map<String, dynamic>.from(d.data() as Map);
          m['_id'] = d.id;
          return m;
        }).toList();
        _eventsLoaded = true;
      });
    }, onError: (Object e) {
      debugPrint('[PublicOrg] events stream error: $e');
      if (!mounted) return;
      setState(() => _eventsLoaded = true);
    });
  }

  // Theme-aware colors — resolve light vs dark variant from the current Theme.
  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;
  Color get _fg     => _isDark ? Colors.white : AppColors.dark;

  String get _orgName {
    final n = (_org?['name'] as String?)?.trim();
    return (n != null && n.isNotEmpty) ? n : 'Organization';
  }

  String get _orgDescription => (_org?['description'] as String?)?.trim() ?? '';
  String get _orgLogoUrl     => (_org?['logoUrl']     as String?)?.trim() ?? '';

  /// Combines `date` (midnight Timestamp) with the optional `time`
  /// string ("HH:MM") into the actual event-start DateTime. Mirrors
  /// the helper in business_home_feed_screen.dart so a same-day event
  /// without a specific start time stays in Upcoming until midnight.
  DateTime _eventStart(DateTime cal, String? timeStr) {
    if (timeStr != null) {
      final parts = timeStr.split(':');
      if (parts.length == 2) {
        final h = int.tryParse(parts[0]);
        final m = int.tryParse(parts[1]);
        if (h != null && m != null) {
          return DateTime(cal.year, cal.month, cal.day, h, m);
        }
      }
    }
    return DateTime(cal.year, cal.month, cal.day, 23, 59, 59);
  }

  List<Map<String, dynamic>> get _upcoming {
    final now = DateTime.now();
    final filtered = _events.where((e) {
      if ((e['isDraft']    as bool?) ?? false) return false;
      if ((e['isArchived'] as bool?) ?? false) return false;
      final ts = e['date'] as Timestamp?;
      if (ts == null) return false;
      return !_eventStart(ts.toDate(), e['time'] as String?).isBefore(now);
    }).toList()
      ..sort((a, b) {
        final ad = (a['date'] as Timestamp).toDate();
        final bd = (b['date'] as Timestamp).toDate();
        return ad.compareTo(bd);
      });
    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Text(
          _orgLoaded ? _orgName : 'Loading…',
          style: TextStyle(fontWeight: FontWeight.w700, color: _fg),
          maxLines: 1, overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (!_orgLoaded) {
      return const Center(child: CircularProgressIndicator(color: _purple));
    }
    if (_orgMissing) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('🏢', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text("Couldn't find that organization",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: _fg)),
            const SizedBox(height: 6),
            Text('The link may be old, or the organization was removed.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: _muted, height: 1.4)),
          ]),
        ),
      );
    }
    final upcoming = _upcoming;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _buildOrgHeader(),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Text(
            'UPCOMING EVENTS',
            style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w800,
              color: _muted, letterSpacing: 1.4,
            ),
          ),
        ),
        if (!_eventsLoaded)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CircularProgressIndicator(color: _purple, strokeWidth: 2)),
          )
        else if (upcoming.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _border),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('📅', style: TextStyle(fontSize: 36)),
              const SizedBox(height: 10),
              Text('No upcoming events',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _fg)),
              const SizedBox(height: 4),
              Text('Check back soon for new events.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: _muted)),
            ]),
          )
        else
          ...upcoming.map(_buildEventCard),
      ],
    );
  }

  Widget _buildOrgHeader() {
    final logoUrl = _orgLogoUrl;
    final desc = _orgDescription;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _border),
      ),
      child: Column(children: [
        Container(
          width: 96, height: 96,
          decoration: BoxDecoration(
            color: _purple.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: _purple.withValues(alpha: 0.4)),
          ),
          clipBehavior: Clip.antiAlias,
          child: logoUrl.isNotEmpty
              ? Image.network(
                  logoUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const Center(child: Text('🏢', style: TextStyle(fontSize: 36))),
                )
              : const Center(child: Text('🏢', style: TextStyle(fontSize: 36))),
        ),
        const SizedBox(height: 12),
        Text(
          _orgName,
          textAlign: TextAlign.center,
          style: TextStyle(fontFamily: 'FredokaOne', fontSize: 24, color: _fg),
        ),
        if (desc.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            desc,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: _muted, height: 1.5),
          ),
        ],
      ]),
    );
  }

  Widget _buildEventCard(Map<String, dynamic> event) {
    final ts = event['date'] as Timestamp;
    final date = ts.toDate();
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final dateStr = '${months[date.month - 1]} ${date.day}, ${date.year}';
    final title = (event['title'] as String?) ?? 'Untitled';
    final emoji = (event['eventEmoji'] as String?) ?? '🎉';
    final location = (event['location'] as String?) ?? '';
    final eventId = event['_id'] as String;

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GuestEventScreen(
            eventId: eventId,
            eventData: Map<String, dynamic>.from(event),
          ),
        ),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _border),
        ),
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Text(emoji, style: const TextStyle(fontSize: 28)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _fg),
                ),
                const SizedBox(height: 2),
                Text(dateStr, style: TextStyle(fontSize: 12, color: _muted)),
                if (location.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(children: [
                    Icon(Icons.location_on_outlined, size: 12, color: _muted),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        location,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: _muted),
                      ),
                    ),
                  ]),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.chevron_right, size: 20, color: _muted),
        ]),
      ),
    );
  }
}
