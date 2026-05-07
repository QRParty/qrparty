import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../utils.dart';
import '../widgets/rsvp_live_counts.dart';
import 'create_event_screen.dart';
import 'edit_event_screen.dart';
import 'guest_event_screen.dart';
import 'host_notifications_screen.dart';
import 'generate_qr_screen.dart';
import 'business_qr_screen.dart';
import 'analytics_screen.dart';
import 'settings_screen.dart';
import 'create_template_screen.dart';
import 'organization_screen.dart';
import '../services/empty_events_cleanup.dart';
import '../services/event_delete_helper.dart';

// ── Theme palette ───────────────────────────────────────────────
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

class BusinessHomeFeedScreen extends StatefulWidget {
  const BusinessHomeFeedScreen({super.key});
  @override
  State<BusinessHomeFeedScreen> createState() => _BusinessHomeFeedScreenState();
}

class _BusinessHomeFeedScreenState extends State<BusinessHomeFeedScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<Map<String, dynamic>> _events = [];
  bool _loading = true;
  // Auto-cleanup is a once-per-session prompt — flipping true after the
  // first load means subsequent stream rebuilds won't re-prompt.
  bool _emptyEventsCleanupChecked = false;
  StreamSubscription<QuerySnapshot>? _hostEventsSub;
  StreamSubscription<QuerySnapshot>? _coHostEventsSub;
  Map<String, Map<String, dynamic>> _hostRaw = {};
  Map<String, Map<String, dynamic>> _coHostRaw = {};

  // Contacts tab — one rsvps subscription per host event, reconciled
  // whenever _hostRaw changes. Inner map is keyed by lowercased email
  // so the same person who RSVPed via both web and app collapses to
  // one contact entry across the whole tab.
  final Map<String, StreamSubscription<QuerySnapshot>> _rsvpSubs = {};
  final Map<String, Map<String, Map<String, dynamic>>> _rsvpsByEvent = {};
  String _contactsSearch = '';
  final TextEditingController _contactsSearchCtrl = TextEditingController();

  // Organization banner state — businessPlus owners see their org card; business
  // accounts see an upgrade nudge; only fetched once per session.
  StreamSubscription<DocumentSnapshot>? _userSub;
  StreamSubscription<QuerySnapshot>? _orgSub;
  String? _accountType;
  String? _userName;
  String? _orgId;
  Map<String, dynamic>? _org;

  // Pending HQ→Business link invite. Subscription is reconciled when
  // _orgId changes; banner only shows when status==pending AND the
  // Business isn't already linked to a parent HQ.
  StreamSubscription<QuerySnapshot>? _invitesSub;
  String? _invitesSubscribedFor;
  Map<String, dynamic>? _pendingInvite;
  bool _processingInvite = false;

  // Theme-aware colors — resolve light vs dark variant from the current Theme.
  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(_onTabChanged);
    _subscribeToEvents();
    _subscribeToOrg();
  }

  void _onTabChanged() {
    // Rebuild when the selected tab settles so the Templates-only FAB appears/disappears.
    if (!_tabController.indexIsChanging && mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _hostEventsSub?.cancel();
    _coHostEventsSub?.cancel();
    _userSub?.cancel();
    _orgSub?.cancel();
    _invitesSub?.cancel();
    for (final sub in _rsvpSubs.values) { sub.cancel(); }
    _rsvpSubs.clear();
    _contactsSearchCtrl.dispose();
    super.dispose();
  }

  void _subscribeToOrg() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    _userSub = FirebaseFirestore.instance.collection('users').doc(user.uid).snapshots().listen((snap) {
      if (!mounted) return;
      setState(() {
        _accountType = snap.data()?['accountType'] as String?;
        _userName    = snap.data()?['name']        as String?;
      });
    });
    _orgSub = FirebaseFirestore.instance
        .collection('organizations')
        .where('ownerId', isEqualTo: user.uid)
        .limit(1)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      if (snap.docs.isEmpty) {
        setState(() { _orgId = null; _org = null; });
      } else {
        setState(() { _orgId = snap.docs.first.id; _org = snap.docs.first.data(); });
      }
      _reconcileInvitesSub();
    });
  }

  // Swap the invites listener when the user's org doc id changes
  // (org created → id assigned, or org cleared on signout). Idempotent
  // when called with the same orgId — early-returns without resubscribing.
  void _reconcileInvitesSub() {
    if (_orgId == _invitesSubscribedFor) return;
    _invitesSub?.cancel();
    _invitesSub = null;
    _invitesSubscribedFor = _orgId;
    if (_orgId == null) {
      if (_pendingInvite != null && mounted) {
        setState(() => _pendingInvite = null);
      }
      return;
    }
    _invitesSub = FirebaseFirestore.instance
        .collection('organizations').doc(_orgId)
        .collection('invites')
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      if (snap.docs.isEmpty) {
        setState(() => _pendingInvite = null);
        return;
      }
      // Phase 1 schema keys the invite doc by hqOrgId, so the doc id
      // IS the HQ org id. Stash it under '_id' for the action handlers.
      final doc = snap.docs.first;
      final data = Map<String, dynamic>.from(doc.data() as Map);
      data['_id'] = doc.id;
      setState(() => _pendingInvite = data);
    }, onError: (_) {});
  }

  Future<void> _acceptInvite(String hqOrgId, String hqName) async {
    if (_processingInvite) return;
    setState(() => _processingInvite = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('acceptOrgInvite');
      await callable.call({'hqOrgId': hqOrgId});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Linked to $hqName'),
        backgroundColor: AppColors.green,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
      ));
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.message ?? 'Could not accept invite.'),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not accept invite: $e'),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
      ));
    } finally {
      if (mounted) setState(() => _processingInvite = false);
    }
  }

  Future<void> _declineInvite(String hqOrgId) async {
    if (_processingInvite || _orgId == null) return;
    setState(() => _processingInvite = true);
    try {
      await FirebaseFirestore.instance
          .collection('organizations').doc(_orgId)
          .collection('invites').doc(hqOrgId)
          .update({
        'status':      'declined',
        'respondedAt': FieldValue.serverTimestamp(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Invite declined'),
        backgroundColor: AppColors.green,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not decline: $e'),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
      ));
    } finally {
      if (mounted) setState(() => _processingInvite = false);
    }
  }

  Widget _buildInviteBanner() {
    // Already linked to a parent HQ → don't show new invites; the user
    // must unlink first via a future flow before linking elsewhere.
    if (_org?['parentOrgId'] != null) return const SizedBox.shrink();
    final invite = _pendingInvite;
    if (invite == null) return const SizedBox.shrink();
    final fg = _isDark ? Colors.white : AppColors.dark;
    final hqOrgId = invite['_id'] as String;
    final hqNameRaw = (invite['hqOrgName'] as String?)?.trim();
    final hqName = (hqNameRaw != null && hqNameRaw.isNotEmpty) ? hqNameRaw : 'a Headquarters';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _purple.withValues(alpha: 0.55), width: 1.5),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(color: _purple.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(10)),
              child: const Center(child: Text('🤝', style: TextStyle(fontSize: 18))),
            ),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                'Invited to link under $hqName',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: fg),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                "Your events will appear on their Headquarters' org page.",
                style: TextStyle(fontSize: 12, color: _muted, height: 1.35),
              ),
            ])),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _processingInvite ? null : () => _declineInvite(hqOrgId),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _muted,
                  side: BorderSide(color: _border),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('Decline', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton(
                onPressed: _processingInvite ? null : () => _acceptInvite(hqOrgId, hqName),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _purple,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: _processingInvite
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Accept', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  void _subscribeToEvents() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) { setState(() => _loading = false); return; }

    // No .orderBy('date') — drafts created without a date field would be
    // dropped from query results (Firestore excludes docs missing the
    // ordered-by field). Client-side sort happens in _rebuild() below
    // using a DateTime(2099) sentinel for null/missing dates.
    _hostEventsSub = FirebaseFirestore.instance
        .collection('events')
        .where('hostId', isEqualTo: user.uid)
        .snapshots()
        .listen((snap) {
      _hostRaw = { for (final doc in snap.docs) doc.id: doc.data() };
      _reconcileRsvpSubs();
      _rebuild(hostLoaded: true);
    }, onError: (_) { if (mounted) setState(() => _loading = false); });

    _coHostEventsSub = FirebaseFirestore.instance
        .collection('events')
        .where('coHosts', arrayContains: user.uid)
        .snapshots()
        .listen((snap) {
      _coHostRaw = { for (final doc in snap.docs) doc.id: doc.data() };
      _rebuild();
    }, onError: (_) {});
  }

  // Tear down rsvp subscriptions for events the host no longer owns
  // (deleted, ownership transferred), and start subscriptions for any
  // newly-host events. Idempotent — can be called on every host-events
  // snapshot without leaking or duplicating listeners.
  void _reconcileRsvpSubs() {
    final wanted = _hostRaw.keys.toSet();
    final existing = _rsvpSubs.keys.toSet();
    for (final id in existing.difference(wanted)) {
      _rsvpSubs[id]?.cancel();
      _rsvpSubs.remove(id);
      _rsvpsByEvent.remove(id);
    }
    for (final id in wanted.difference(existing)) {
      _rsvpSubs[id] = FirebaseFirestore.instance
          .collection('events').doc(id).collection('rsvps')
          .snapshots()
          .listen((snap) {
        if (!mounted) return;
        final byEmail = <String, Map<String, dynamic>>{};
        for (final d in snap.docs) {
          final data = d.data();
          final emailRaw = data['email'] as String?;
          if (emailRaw == null) continue;
          final email = emailRaw.trim().toLowerCase();
          if (email.isEmpty) continue;
          // Last-write-wins within an event (web vs app for same email)
          // — outer dedupe across events happens in _contacts getter.
          byEmail[email] = data;
        }
        setState(() => _rsvpsByEvent[id] = byEmail);
      }, onError: (_) {});
    }
  }

  /// Combines the `date` Timestamp (midnight on the picked calendar
  /// date) with the `time` string ("HH:MM") into a single DateTime
  /// representing the actual event start. Used by the upcoming/past
  /// classifier so an event scheduled for today doesn't get treated
  /// as already-past at 00:00:01. Mirrors the helper in
  /// home_feed_screen.dart.
  DateTime _resolveEventStart(DateTime? calendarDate, String? timeStr) {
    if (calendarDate == null) return DateTime(2099);
    if (timeStr != null) {
      final parts = timeStr.split(':');
      if (parts.length == 2) {
        final h = int.tryParse(parts[0]);
        final m = int.tryParse(parts[1]);
        if (h != null && m != null) {
          return DateTime(calendarDate.year, calendarDate.month, calendarDate.day, h, m);
        }
      }
    }
    // No usable time — fall back to end-of-day so a same-day event
    // without a specific start time still counts as upcoming until
    // midnight rolls over.
    return DateTime(calendarDate.year, calendarDate.month, calendarDate.day, 23, 59, 59);
  }

  void _rebuild({ bool hostLoaded = false }) {
    if (!mounted) return;
    // coHostRaw entries not already owned by this user come first so hostRaw wins on overlap
    final merged = <String, Map<String, dynamic>>{..._coHostRaw, ..._hostRaw};
    final now = DateTime.now();
    // No accountType filter — the user's own events should always
    // appear on the feed they're currently viewing. Filtering by
    // accountType caused freshly-created events to disappear when the
    // event's tag and the feed the user is on disagreed (e.g. legacy
    // 'personal' events lingering on a business user's account, or
    // 'business' events created during a window that routed the user
    // to the personal feed).
    final events = merged.entries.map((entry) {
      final docId = entry.key;
      final data = entry.value;
      final ts = data['date'] as Timestamp?;
      final calendarDate = ts?.toDate();
      // Combine date + time into the actual event-start DateTime so
      // an event picked for today doesn't get classified as past at
      // 00:00:01. End-of-day fallback when no time is set.
      final eventStart = _resolveEventStart(calendarDate, data['time'] as String?);
      final sortDate = calendarDate ?? DateTime(2099);
      final isDraft = (data['isDraft'] as bool?) ?? false;
      final isPast = !isDraft && eventStart.isBefore(now);
      final typeName = migrateEventTypeName(data['eventType'] as String?);
      final matchedType = eventTypes.firstWhere((t) => t.name == typeName, orElse: () => eventTypes.last);
      final wishlist = (data['wishlist'] as List<dynamic>? ?? []);
      final wishlistTotal = wishlist.fold<double>(0.0, (s, item) =>
          s + ((item is Map ? (item['contributed'] as num?)?.toDouble() : null) ?? 0.0));
      return {
        'rawData': data,
        'id': docId,
        'title': (data['title'] as String?) ?? 'Untitled',
        'date': sortDate,
        'eventStart': eventStart,
        'location': (data['location'] as String?) ?? '',
        'emoji': (data['eventEmoji'] as String?) ?? '🎉',
        'color': matchedType.primary,
        'yes': (data['yes'] as num?)?.toInt() ?? 0,
        'maybe': (data['maybe'] as num?)?.toInt() ?? 0,
        'no': (data['no'] as num?)?.toInt() ?? 0,
        'isPast': isPast,
        'isArchived': (data['isArchived'] as bool?) ?? false,
        'isDraft': isDraft,
        'wishlistTotal': wishlistTotal,
        'coHosts': (data['coHosts'] as List<dynamic>? ?? []).length,
        'isCoHosted': _coHostRaw.containsKey(docId) && !_hostRaw.containsKey(docId),
        'isRecurring': (data['isRecurring'] as bool?) ?? false,
      };
    }).toList()..sort((a, b) => (a['date'] as DateTime).compareTo(b['date'] as DateTime));
    setState(() {
      if (hostLoaded) _loading = false;
      _events = events;
    });

    // Once per app session, after the host's events first land, sweep for
    // empty business events older than 24h. Silent when nothing matches —
    // we only surface the dialog when there's something to clean up.
    if (hostLoaded && !_emptyEventsCleanupChecked) {
      _emptyEventsCleanupChecked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        EmptyEventsCleanup.run(context, silentIfNone: true);
      });
    }
  }

  List<Map<String, dynamic>> get _upcoming => _events
      .where((e) => !(e['isPast'] as bool) && !(e['isArchived'] as bool) && !(e['isDraft'] as bool))
      .toList();
  List<Map<String, dynamic>> get _past => _events
      .where((e) => (e['isPast'] as bool) && !(e['isDraft'] as bool))
      .toList();
  List<Map<String, dynamic>> get _drafts => _events
      .where((e) => e['isDraft'] as bool)
      .toList();

  int get _rsvpsThisMonth {
    final now = DateTime.now();
    return _events
        .where((e) { final d = e['date'] as DateTime; return d.year == now.year && d.month == now.month; })
        .fold<int>(0, (s, e) => s + (e['yes'] as int) + (e['maybe'] as int) + (e['no'] as int));
  }
  int get _activeGuests => _upcoming.fold<int>(0, (s, e) => s + (e['yes'] as int) + (e['maybe'] as int));

  String get _orgName {
    final n = (_org?['name'] as String?)?.trim();
    if (n != null && n.isNotEmpty) return n;
    final un = _userName?.trim();
    if (un != null && un.isNotEmpty) return un;
    return _accountType == 'businessPlus' ? 'Your Headquarters' : 'Your Business';
  }

  // Unique contacts across every host event, deduped by lowercased
  // email and filtered by the current search query. Re-derived on
  // every build — cheap for typical event counts and keeps the data
  // path stateless.
  List<Map<String, dynamic>> get _contacts {
    final byEmail = <String, Map<String, dynamic>>{};
    for (final entry in _rsvpsByEvent.entries) {
      final eventId = entry.key;
      for (final emailEntry in entry.value.entries) {
        final email = emailEntry.key;
        final data  = emailEntry.value;
        final rawName = (data['name'] as String?)?.trim() ?? '';
        final name = rawName.isNotEmpty ? rawName : 'Guest';
        final existing = byEmail[email];
        if (existing == null) {
          byEmail[email] = {'name': name, 'email': email, 'eventIds': <String>{eventId}};
        } else {
          (existing['eventIds'] as Set<String>).add(eventId);
          if (existing['name'] == 'Guest' && name != 'Guest') existing['name'] = name;
        }
      }
    }
    final query = _contactsSearch.trim().toLowerCase();
    final filtered = byEmail.values.where((c) {
      if (query.isEmpty) return true;
      final n = (c['name']  as String).toLowerCase();
      final e = (c['email'] as String).toLowerCase();
      return n.contains(query) || e.contains(query);
    }).toList();
    filtered.sort((a, b) =>
        (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final fg = _isDark ? Colors.white : AppColors.dark;
    final isHeadquarters = _accountType == 'businessPlus';
    final wordmark = _orgName;
    final badgeText = isHeadquarters ? 'HEADQUARTERS' : 'PRO';
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Row(children: [
          Flexible(
            child: Text(
              wordmark,
              style: TextStyle(fontFamily: 'FredokaOne', fontSize: 20, color: fg),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(color: _gold, borderRadius: BorderRadius.circular(7)),
            child: Text(
              badgeText,
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 0.5),
            ),
          ),
        ]),
        actions: [
          IconButton(
            icon: Icon(Icons.bar_chart_outlined, color: fg),
            tooltip: 'Analytics',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AnalyticsScreen())),
          ),
          IconButton(
            icon: Icon(Icons.notifications_outlined, color: fg),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HostNotificationsScreen())),
          ),
          IconButton(
            icon: Icon(Icons.settings_outlined, color: fg),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Stack(
        children: [
          Column(children: [
            _buildInviteBanner(),
            _buildStatsRow(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(children: [
                _buildOrgBanner(),
                _buildBusinessQrCard(),
              ]),
            ),
            Container(
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: _border))),
              child: TabBar(
                controller: _tabController,
                indicatorColor: _purple,
                indicatorWeight: 2,
                labelColor: fg,
                unselectedLabelColor: _muted,
                labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                unselectedLabelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                tabs: const [Tab(text: 'Upcoming'), Tab(text: 'Past'), Tab(text: 'Templates'), Tab(text: 'Contacts')],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [_buildUpcomingTab(), _buildPastTab(), _buildTemplatesTab(), _buildContactsTab()],
              ),
            ),
          ]),
          // Templates-tab only: gold "Create Template" FAB in the bottom-LEFT corner.
          if (_tabController.index == 2)
            Positioned(
              left: 16,
              bottom: 16,
              child: FloatingActionButton.extended(
                heroTag: 'fab_create_template',
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateTemplateScreen())),
                backgroundColor: _gold,
                foregroundColor: Colors.white,
                icon: const Icon(Icons.add),
                label: const Text('Create Template', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'fab_new_event',
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateEventScreen())),
        backgroundColor: _purple,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('New Event', style: TextStyle(fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _buildStatsRow() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
    child: Row(children: [
      _statCard('Upcoming', '${_upcoming.length}', _purple),
      const SizedBox(width: 10),
      _statCard('RSVPs / Month', '$_rsvpsThisMonth', _gold),
      const SizedBox(width: 10),
      _statCard('Active Guests', '$_activeGuests', AppColors.green),
    ]),
  );

  Widget _statCard(String label, String value, Color valueColor) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: valueColor)),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 11, color: _muted, fontWeight: FontWeight.w500)),
      ]),
    ),
  );

  Widget _buildUpcomingTab() {
    if (_loading) return const Center(child: CircularProgressIndicator(color: _purple));
    final fg = _isDark ? Colors.white : AppColors.dark;
    final drafts   = _drafts;
    final upcoming = _upcoming;
    final hasNoEvents = drafts.isEmpty && upcoming.isEmpty;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
      children: [
        if (hasNoEvents)
          Padding(
            padding: const EdgeInsets.only(top: 48),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('📅', style: TextStyle(fontSize: 48)),
              const SizedBox(height: 12),
              Text('No upcoming events', textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: fg)),
              const SizedBox(height: 6),
              Text('Tap + to create your first business event', textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: _muted)),
            ]),
          ),
        if (drafts.isNotEmpty) ...[
          _draftsSectionHeader(drafts.length),
          ...drafts.map(_buildDraftCard),
          const SizedBox(height: 8),
        ],
        if (upcoming.isNotEmpty && drafts.isNotEmpty)
          _upcomingSectionHeader(upcoming.length),
        ...upcoming.map(_buildUpcomingCard),
      ],
    );
  }

  Widget _buildOrgBanner() {
    if (_accountType == null) return const SizedBox.shrink();
    final fg = _isDark ? Colors.white : AppColors.dark;
    final canCreateOrg = _accountType == 'business' || _accountType == 'businessPlus';
    final hasOrg = _orgId != null;

    if (!canCreateOrg) return const SizedBox.shrink();

    // Business and Headquarters: either show the org card or a "Create Organization" CTA.
    if (!hasOrg) {
      return Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _purple.withValues(alpha: 0.45), width: 1.5),
        ),
        child: Row(children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(color: _purple.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(12)),
            child: const Center(child: Text('🏢', style: TextStyle(fontSize: 24))),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Create your organization', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: fg)),
            const SizedBox(height: 2),
            Text('Get a branded org page and a single QR for every event.',
                style: TextStyle(fontSize: 12, color: _muted, height: 1.35)),
          ])),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const OrganizationScreen())),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Create', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
            style: ElevatedButton.styleFrom(
              backgroundColor: _purple, foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ]),
      );
    }

    final name = (_org?['name'] as String?) ?? 'Organization';
    final logoUrl = (_org?['logoUrl'] as String?) ?? '';
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const OrganizationScreen())),
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF3B2F68), Color(0xFF2B2A4E)],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _purple.withValues(alpha: 0.45)),
          boxShadow: [BoxShadow(color: _purple.withValues(alpha: 0.18), blurRadius: 16, offset: const Offset(0, 6))],
        ),
        child: Row(children: [
          Container(
            width: 52, height: 52,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            ),
            clipBehavior: Clip.antiAlias,
            child: logoUrl.isNotEmpty
                ? Image.network(logoUrl, fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Center(child: Text('🏢', style: TextStyle(fontSize: 24))))
                : const Center(child: Text('🏢', style: TextStyle(fontSize: 24))),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: _gold, borderRadius: BorderRadius.circular(5)),
                child: const Text('ORG', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 0.6)),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: 'FredokaOne', fontSize: 17, color: Colors.white)),
              ),
            ]),
            const SizedBox(height: 4),
            Text('Manage page, QR & event listing →',
                style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.72))),
          ])),
          const SizedBox(width: 8),
          const Icon(Icons.qr_code_2, color: Colors.white, size: 22),
        ]),
      ),
    );
  }

  /// Permanent business QR card — taps through to [BusinessQRScreen]
  /// which provisions the slug on first visit. The slug + URL are then
  /// cached on the user doc so subsequent visits open instantly.
  /// Sits above the events list so a brand-new business account sees
  /// "share your QR" before "create your first event" — the QR is the
  /// thing that drives every later RSVP.
  Widget _buildBusinessQrCard() {
    return GestureDetector(
      onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => const BusinessQRScreen())),
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [_purple.withValues(alpha: 0.16), _purple.withValues(alpha: 0.06)],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _purple.withValues(alpha: 0.45)),
        ),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: _purple,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color: _purple.withValues(alpha: 0.35), blurRadius: 10, offset: const Offset(0, 4))],
            ),
            child: const Icon(Icons.qr_code_2, color: Colors.white, size: 26),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Business QR Code',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: _isDark ? Colors.white : AppColors.dark)),
            const SizedBox(height: 2),
            Text('One QR for every event you host — share once, scan forever.',
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: _muted, height: 1.35)),
          ])),
          const SizedBox(width: 6),
          Icon(Icons.chevron_right, color: _purple, size: 22),
        ]),
      ),
    );
  }

  Widget _draftsSectionHeader(int count) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 10, left: 2),
        child: Row(children: [
          const Icon(Icons.edit_note_outlined, size: 16, color: _gold),
          const SizedBox(width: 6),
          Text(
            'DRAFTS · $count',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _gold, letterSpacing: 1.2),
          ),
        ]),
      );

  Widget _upcomingSectionHeader(int count) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 10, left: 2),
        child: Text(
          'UPCOMING · $count',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _muted, letterSpacing: 1.2),
        ),
      );

  /// True when the current user can delete this event. Mirrors the
  /// firestore.rules: the host can always delete, and the org owner can
  /// delete events linked to their org. We expose the check at the UI
  /// layer so the Delete option only appears for users who can actually
  /// perform it (not just signed-in users tapping a button that would
  /// then 403).
  bool _canDeleteEvent(Map<String, dynamic> event) {
    final raw = (event['rawData'] as Map?)?.cast<String, dynamic>() ?? const {};
    return EventDeleteHelper.canDelete(
      hostId: raw['hostId'] as String?,
      eventOrgId: raw['orgId'] as String?,
      myUid: FirebaseAuth.instance.currentUser?.uid,
      myOwnedOrgId: _orgId, // populated for the org owner; null otherwise
    );
  }

  /// Opens a popup menu near [position] with at-minimum a Delete entry.
  /// Used both by the long-press gesture (passes the touch position) and
  /// by the 3-dot icon button (passes its own widget rect's top-left).
  Future<void> _openEventMenu(
    Map<String, dynamic> event,
    Offset position,
  ) async {
    if (!_canDeleteEvent(event)) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final eventTitle = (event['title'] as String?) ?? 'this event';
    final eventId = event['id'] as String;
    final picked = await showMenu<String>(
      context: context,
      color: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(children: [
            Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
            SizedBox(width: 10),
            Text('Delete event',
                style: TextStyle(
                  fontFamily: 'Nunito', color: Colors.redAccent,
                  fontWeight: FontWeight.w800, fontSize: 14,
                )),
          ]),
        ),
      ],
    );
    if (picked == 'delete' && mounted) {
      await EventDeleteHelper.confirmAndDelete(
        context, eventId: eventId, eventTitle: eventTitle,
      );
      // Subscriptions auto-rebuild the feed; no manual refresh needed.
    }
  }

  /// Compact 3-dot icon button used in the top-left of every card so
  /// the overflow menu is always reachable, even when long-press isn't
  /// discoverable. Hidden when the user can't delete.
  Widget _buildOverflowMenuButton(Map<String, dynamic> event) {
    if (!_canDeleteEvent(event)) return const SizedBox.shrink();
    return Builder(builder: (ctx) => Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          final box = ctx.findRenderObject() as RenderBox?;
          final origin = box?.localToGlobal(Offset.zero) ?? Offset.zero;
          _openEventMenu(event, origin + const Offset(20, 30));
        },
        child: Container(
          width: 32, height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _card.withValues(alpha: 0.85),
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 6, offset: const Offset(0, 2))],
          ),
          child: Icon(Icons.more_vert, color: _muted, size: 18),
        ),
      ),
    ));
  }

  Widget _buildDraftCard(Map<String, dynamic> event) {
    final fg = _isDark ? Colors.white : AppColors.dark;
    final title = event['title'] as String;
    final emoji = event['emoji'] as String;
    return Stack(children: [
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressStart: (d) => _openEventMenu(event, d.globalPosition),
        child: Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _gold.withValues(alpha: 0.4)),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: _gold.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(child: Text(emoji, style: const TextStyle(fontSize: 20))),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: fg), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              const Text('Draft — tap to continue editing', style: TextStyle(fontSize: 11, color: _gold, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton.icon(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CreateEventScreen(
            draftId: event['id'] as String,
            draftData: Map<String, dynamic>.from(event['rawData'] as Map),
          ))),
          icon: const Icon(Icons.edit_outlined, size: 14),
          label: const Text('Edit & Publish', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
          style: ElevatedButton.styleFrom(
            backgroundColor: _gold,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ]),
    ),
      ),
      // Top-left 3-dot overflow — same menu the long-press opens.
      Positioned(top: 4, left: 4, child: _buildOverflowMenuButton(event)),
    ]);
  }

  Widget _buildUpcomingCard(Map<String, dynamic> event) {
    // The cached event['yes']/['maybe']/['no'] counters are passed only
    // as RsvpLiveCounts.initial (avoids a 0-flash before the snapshot
    // resolves). The summary text + progress bar below are driven by
    // the live subcollection sum so children + plus-ones are reflected.
    final initialYes   = event['yes']   as int? ?? 0;
    final initialMaybe = event['maybe'] as int? ?? 0;
    final initialNo    = event['no']    as int? ?? 0;
    final date = event['date'] as DateTime;
    final months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final dateStr = '${months[date.month - 1]} ${date.day}, ${date.year}';
    final location = event['location'] as String;
    final coHosts = event['coHosts'] as int;
    final fg = _isDark ? Colors.white : AppColors.dark;

    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (d) => _openEventMenu(event, d.globalPosition),
          child: Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(event['emoji'] as String, style: const TextStyle(fontSize: 24)),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(
                    event['title'] as String,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: fg),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (event['isRecurring'] == true) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: _purple.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: _purple.withValues(alpha: 0.45)),
                    ),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('🔄', style: TextStyle(fontSize: 10)),
                      SizedBox(width: 3),
                      Text('Recurring', style: TextStyle(fontSize: 10, color: _purple, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
                    ]),
                  ),
                ],
              ]),
              Text(dateStr, style: TextStyle(fontSize: 12, color: _muted)),
            ])),
          ]),
          if (location.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(children: [
              Icon(Icons.location_on_outlined, size: 12, color: _muted),
              const SizedBox(width: 4),
              Expanded(child: Text(location, style: TextStyle(fontSize: 12, color: _muted), maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
          ],
          const SizedBox(height: 12),
          // Live counts from the rsvps subcollection. Sums adults +
          // children + plusOnes per RSVP doc so a family-of-4 RSVP
          // contributes 4 here, not 1. Cached parent counters are used
          // only to seed the initial render.
          RsvpLiveCounts(
            eventId: event['id'] as String,
            initial: (yes: initialYes, maybe: initialMaybe, no: initialNo),
            builder: (ctx, yes, maybe, no) {
              final total = yes + maybe + no;
              final progress = total > 0 ? yes / total : 0.0;
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('$yes going · $maybe maybe · $no can\'t', style: TextStyle(fontSize: 11, color: _muted)),
                  Text('$total total', style: const TextStyle(fontSize: 11, color: _purple, fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress, minHeight: 5,
                    backgroundColor: _border,
                    valueColor: const AlwaysStoppedAnimation<Color>(_purple),
                  ),
                ),
              ]);
            },
          ),
          if (coHosts > 0) ...[
            const SizedBox(height: 8),
            Row(children: [
              const Icon(Icons.group_outlined, size: 13, color: _gold),
              const SizedBox(width: 4),
              Text('$coHosts co-host${coHosts == 1 ? '' : 's'}', style: const TextStyle(fontSize: 12, color: _gold)),
            ]),
          ],
          const SizedBox(height: 12),
          Row(children: [
            _actionBtn('Edit', Icons.edit_outlined, _purple, () => Navigator.push(context, MaterialPageRoute(builder: (_) => EditEventScreen(eventId: event['id'] as String, eventData: Map<String, dynamic>.from(event['rawData'] as Map))))),
            const SizedBox(width: 8),
            _actionBtn('Notify', Icons.campaign_outlined, _gold, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HostNotificationsScreen()))),
            const SizedBox(width: 8),
            _actionBtn('View', Icons.visibility_outlined, AppColors.green,
                () => Navigator.push(context, MaterialPageRoute(builder: (_) => GuestEventScreen(eventId: event['id'] as String)))),
            const SizedBox(width: 8),
            _actionBtn('Template', Icons.bookmark_add_outlined, _gold, () => _saveAsTemplate(event)),
          ]),
        ]),
      ),
    ),
        ),
        // Top-right QR shortcut — only shown here since this method renders
        // upcoming events only (past/drafts use different cards and queries).
        Positioned(
          top: 8, right: 8,
          child: _buildQrIconButton(event['id'] as String, event['title'] as String),
        ),
        // Top-left 3-dot overflow menu — same menu the long-press opens.
        Positioned(
          top: 8, left: 8,
          child: _buildOverflowMenuButton(event),
        ),
      ],
    );
  }

  Widget _buildQrIconButton(String eventId, String eventTitle) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => GenerateQRCodeScreen(eventId: eventId, eventTitle: eventTitle)),
        ),
        child: Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: _purple,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: _purple.withValues(alpha: 0.3), blurRadius: 6, offset: const Offset(0, 2))],
          ),
          child: const Icon(Icons.qr_code_2, color: Colors.white, size: 18),
        ),
      ),
    );
  }

  Widget _actionBtn(String label, IconData icon, Color color, VoidCallback onTap) => Expanded(
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.30), width: 1),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        ]),
      ),
    ),
  );

  Widget _buildPastTab() {
    if (_loading) return const Center(child: CircularProgressIndicator(color: _purple));
    final fg = _isDark ? Colors.white : AppColors.dark;
    if (_past.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('📁', style: TextStyle(fontSize: 48)),
        const SizedBox(height: 12),
        Text('No past events yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: fg)),
      ]));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      itemCount: _past.length,
      itemBuilder: (_, i) => _buildPastCard(_past[i]),
    );
  }

  Widget _buildPastCard(Map<String, dynamic> event) {
    // Cached counters seed the initial render; the live RsvpLiveCounts
    // listener below recomputes the totals from the rsvps subcollection
    // (correctly summing adults + children + plus-ones).
    final initialYes   = event['yes']   as int? ?? 0;
    final initialMaybe = event['maybe'] as int? ?? 0;
    final initialNo    = event['no']    as int? ?? 0;
    final date = event['date'] as DateTime;
    final months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final dateStr = '${months[date.month - 1]} ${date.day}, ${date.year}';
    final wishlistTotal = event['wishlistTotal'] as double;

    return Stack(children: [
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressStart: (d) => _openEventMenu(event, d.globalPosition),
        child: Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(event['emoji'] as String, style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(event['title'] as String, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _muted)),
              Text(dateStr, style: const TextStyle(fontSize: 12, color: Color(0xFF6B6880))),
            ])),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: _border, borderRadius: BorderRadius.circular(8)),
              child: Text('Past', style: TextStyle(fontSize: 11, color: _muted, fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 10),
          RsvpLiveCounts(
            eventId: event['id'] as String,
            initial: (yes: initialYes, maybe: initialMaybe, no: initialNo),
            builder: (ctx, yes, maybe, no) {
              final total = yes + maybe + no;
              return Row(children: [
                _miniStat('$total', 'Total RSVPs', _purple),
                const SizedBox(width: 16),
                _miniStat('$yes', 'Yes RSVPs', AppColors.green),
                // Wishlist total stat hidden behind kWishlistEnabled.
                // The cached value on the card stays correct for when
                // the beta gate re-opens.
                if (kWishlistEnabled && wishlistTotal > 0) ...[
                  const SizedBox(width: 16),
                  _miniStat('\$${wishlistTotal.toStringAsFixed(2)}', 'Wishlist', _gold),
                ],
              ]);
            },
          ),
        ]),
      ),
    ),
      ),
      // Top-left 3-dot overflow — same menu the long-press opens.
      Positioned(top: 4, left: 4, child: _buildOverflowMenuButton(event)),
    ]);
  }

  Widget _miniStat(String value, String label, Color color) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color)),
      Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF6B6880))),
    ],
  );

  // ── Templates tab ────────────────────────────────────────────

  Widget _buildTemplatesTab() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const SizedBox.shrink();
    final fg = _isDark ? Colors.white : AppColors.dark;
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users').doc(uid).collection('templates')
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
              const Text('📋', style: TextStyle(fontSize: 56)),
              const SizedBox(height: 16),
              Text('No templates yet', style: TextStyle(fontFamily: 'FredokaOne', fontSize: 26, color: fg)),
              const SizedBox(height: 10),
              Text(
                'Tap "Template" on any upcoming event card to save it as a reusable template.',
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'Nunito', fontSize: 14, color: _muted, height: 1.5),
              ),
            ]),
          ));
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
          itemCount: docs.length,
          itemBuilder: (_, i) {
            final data = docs[i].data() as Map<String, dynamic>;
            return _buildTemplateCard(data, docs[i].id, uid);
          },
        );
      },
    );
  }

  Widget _buildTemplateCard(Map<String, dynamic> t, String templateId, String uid) {
    final typeName = migrateEventTypeName(t['eventType'] as String?);
    final matchedType = eventTypes.firstWhere((e) => e.name == typeName, orElse: () => eventTypes.last);
    final listType = (t['listType'] as String?) ?? 'No List';
    final offsetDays = (t['rsvpDeadlineOffsetDays'] as int?) ?? 0;
    final coHostCount = (t['coHosts'] as List?)?.length ?? 0;
    final fg = _isDark ? Colors.white : AppColors.dark;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: matchedType.primary.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(child: Text(
                (t['eventEmoji'] as String?) ?? matchedType.emoji,
                style: const TextStyle(fontSize: 20),
              )),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                (t['title'] as String?) ?? 'Untitled Template',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: fg),
              ),
              Text(matchedType.name, style: TextStyle(fontSize: 12, color: _muted)),
            ])),
            GestureDetector(
              onTap: () => _confirmDeleteTemplate(templateId, uid),
              child: const Icon(Icons.delete_outline, color: Color(0xFF6B6880), size: 20),
            ),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 6, children: [
            _templateChip(listType, Icons.list_outlined),
            if (offsetDays > 0) _templateChip('RSVP ${offsetDays}d before', Icons.event_busy_outlined),
            if (t['isPublic'] == true) _templateChip('Public', Icons.public),
            if (coHostCount > 0) _templateChip('$coHostCount co-host${coHostCount == 1 ? '' : 's'}', Icons.group_outlined),
          ]),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => CreateEventScreen(templateData: t),
              )),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Use This Template', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              style: ElevatedButton.styleFrom(
                backgroundColor: _purple,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                elevation: 0,
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _templateChip(String label, IconData icon) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: _bg,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _border),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 11, color: _muted),
      const SizedBox(width: 4),
      Text(label, style: TextStyle(fontSize: 11, color: _muted, fontWeight: FontWeight.w500)),
    ]),
  );

  Future<void> _confirmDeleteTemplate(String templateId, String uid) async {
    final fg = _isDark ? Colors.white : AppColors.dark;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Delete template?', style: TextStyle(fontFamily: 'FredokaOne', fontSize: 20, color: fg)),
        content: Text('This cannot be undone.', style: TextStyle(fontSize: 14, color: _muted)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: TextStyle(color: _muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await FirebaseFirestore.instance
          .collection('users').doc(uid).collection('templates').doc(templateId).delete();
    }
  }

  Future<void> _saveAsTemplate(Map<String, dynamic> event) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final raw = event['rawData'] as Map<String, dynamic>;

    // Calculate RSVP deadline offset in days
    int offsetDays = 0;
    final eventDate = event['date'] as DateTime;
    final rsvpTs = raw['rsvpDeadline'] as Timestamp?;
    if (rsvpTs != null) {
      final diff = eventDate.difference(rsvpTs.toDate()).inDays;
      if (diff > 0) offsetDays = diff;
    }

    // Fetch co-host emails in parallel
    final coHostUids = List<String>.from(raw['coHosts'] as List? ?? []);
    final coHosts = <Map<String, String>>[];
    if (coHostUids.isNotEmpty) {
      final userDocs = await Future.wait(
        coHostUids.map((id) => FirebaseFirestore.instance.collection('users').doc(id).get()),
      );
      for (int i = 0; i < coHostUids.length; i++) {
        final email = ((userDocs[i].data() ?? {})['email'] as String?) ?? '';
        if (email.isNotEmpty) coHosts.add({'uid': coHostUids[i], 'email': email});
      }
    }

    try {
      await FirebaseFirestore.instance
          .collection('users').doc(uid).collection('templates').add({
        'title': (raw['title'] as String?) ?? '',
        'description': (raw['description'] as String?) ?? '',
        'listType': (raw['listType'] as String?) ?? 'No List',
        'isPublic': (raw['isPublic'] as bool?) ?? false,
        'eventType': (raw['eventType'] as String?) ?? '',
        'eventEmoji': (raw['eventEmoji'] as String?) ?? '🎉',
        'rsvpDeadlineOffsetDays': offsetDays,
        'coHosts': coHosts,
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('📋 Saved as template!'), backgroundColor: AppColors.green),
        );
        _tabController.animateTo(2);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save template: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  void _showNotifySheet() {
    final count = _contacts.length;
    if (count == 0) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _NotifyAllSheet(recipientCount: count),
    );
  }

  Widget _buildContactsTab() {
    if (_loading) return const Center(child: CircularProgressIndicator(color: _purple));
    final fg = _isDark ? Colors.white : AppColors.dark;
    final contacts = _contacts;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _contactsSearchCtrl,
              onChanged: (v) => setState(() => _contactsSearch = v),
              style: TextStyle(color: fg, fontSize: 14),
              cursorColor: _purple,
              decoration: InputDecoration(
                hintText: 'Search by name or email',
                hintStyle: TextStyle(color: _muted, fontSize: 14),
                prefixIcon: Icon(Icons.search, color: _muted, size: 20),
                isDense: true,
                filled: true,
                fillColor: _card,
                border:        OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _purple, width: 1.5)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Notify-all CTA — disabled until at least one contact has
          // accumulated, so we never push the modal with a "Send to 0
          // guests" button. Tapping fans out to every guest who's
          // RSVPed to ANY of the host's events (web RSVPs without a
          // uid are skipped server-side — no FCM token to target).
          SizedBox(
            height: 44,
            child: ElevatedButton.icon(
              onPressed: contacts.isEmpty ? null : _showNotifySheet,
              icon: const Icon(Icons.campaign_outlined, size: 16),
              label: const Text('Notify All', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
              style: ElevatedButton.styleFrom(
                backgroundColor: _purple,
                foregroundColor: Colors.white,
                disabledBackgroundColor: _border,
                disabledForegroundColor: _muted,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ]),
      ),
      Expanded(
        child: contacts.isEmpty
            ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('👥', style: TextStyle(fontSize: 48)),
                const SizedBox(height: 12),
                Text(
                  _contactsSearch.trim().isEmpty ? 'No contacts yet' : 'No matches',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: fg),
                ),
              ]))
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                itemCount: contacts.length,
                itemBuilder: (_, i) => _buildContactRow(contacts[i]),
              ),
      ),
    ]);
  }

  // ── _NotifyAllSheet wrapper widget defined at end of file ────
  // (extracted as a StatefulWidget so its TextEditingControllers /
  //  FocusNodes can dispose in State.dispose() — the
  //  showModalBottomSheet + StatefulBuilder + whenComplete pattern
  //  triggered the _dependents.isEmpty assertion earlier in the
  //  Headquarters invite flow; this avoids the same trap.)

  Widget _buildContactRow(Map<String, dynamic> contact) {
    final fg = _isDark ? Colors.white : AppColors.dark;
    final name  = contact['name']  as String;
    final email = contact['email'] as String;
    final eventCount = (contact['eventIds'] as Set<String>).length;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Row(children: [
        Container(
          width: 38, height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _purple.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            name.isNotEmpty ? name.substring(0, 1).toUpperCase() : '?',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _purple),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name,  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: fg), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(email, style: TextStyle(fontSize: 12, color: _muted),                          maxLines: 1, overflow: TextOverflow.ellipsis),
        ])),
        const SizedBox(width: 8),
        Text(
          '$eventCount ${eventCount == 1 ? 'event' : 'events'}',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _muted),
        ),
      ]),
    );
  }
}

/// Bottom-sheet body for the Contacts tab's "Notify All" CTA.
/// Extracted as a StatefulWidget so its controllers + focus nodes
/// dispose in State.dispose() instead of `whenComplete` on the modal
/// — the latter races the widget-tree teardown and trips the
/// `_dependents.isEmpty` assertion (same fix pattern as the
/// Headquarters invite sheet earlier in this codebase).
class _NotifyAllSheet extends StatefulWidget {
  final int recipientCount;
  const _NotifyAllSheet({required this.recipientCount});

  @override
  State<_NotifyAllSheet> createState() => _NotifyAllSheetState();
}

class _NotifyAllSheetState extends State<_NotifyAllSheet> {
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _bodyCtrl  = TextEditingController();
  final FocusNode _titleFocus = FocusNode();
  final FocusNode _bodyFocus  = FocusNode();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _titleFocus.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;
  Color get _fg     => _isDark ? Colors.white : AppColors.dark;

  Future<void> _send() async {
    final title = _titleCtrl.text.trim();
    final body  = _bodyCtrl.text.trim();
    if (title.isEmpty) { setState(() => _error = 'Title is required');   return; }
    if (body.isEmpty)  { setState(() => _error = 'Message is required'); return; }
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null)   { setState(() => _error = 'Sign in to send notifications'); return; }
    setState(() { _busy = true; _error = null; });
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('sendMassNotification');
      final res = await callable.call({
        'title':   title,
        'body':    body,
        'hostUid': uid,
      });
      final data = res.data as Map?;
      final sent = (data?['sent'] as num?)?.toInt() ?? 0;
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('🔔 Notification sent to $sent guest${sent == 1 ? '' : 's'}'),
        backgroundColor: AppColors.green,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
      ));
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message ?? 'Could not send notification.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Send failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(color: _border, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Row(children: [
              Expanded(
                child: Text('Send Notification',
                    style: TextStyle(fontFamily: 'FredokaOne', fontSize: 22, color: _fg)),
              ),
              GestureDetector(
                onTap: _busy ? null : () => Navigator.of(context).pop(),
                child: Icon(Icons.close, size: 22, color: _muted),
              ),
            ]),
            const SizedBox(height: 4),
            Text(
              'Sending to ${widget.recipientCount} contact${widget.recipientCount == 1 ? '' : 's'} via push.',
              style: TextStyle(fontSize: 12.5, color: _muted),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('TITLE',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _muted, letterSpacing: 1.2)),
            ),
            TextField(
              controller: _titleCtrl,
              focusNode: _titleFocus,
              enabled: !_busy,
              maxLength: 60,
              maxLines: 1,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _bodyFocus.requestFocus(),
              onChanged: (_) => setState(() {}),
              style: TextStyle(color: _fg, fontSize: 15),
              cursorColor: _purple,
              decoration: InputDecoration(
                hintText: 'e.g. Reminder: tomorrow at 6pm',
                hintStyle: TextStyle(color: _muted, fontSize: 14),
                filled: true,
                fillColor: _bg,
                counterStyle: TextStyle(color: _muted, fontSize: 11),
                border:        OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _purple, width: 1.5)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('MESSAGE',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _muted, letterSpacing: 1.2)),
            ),
            TextField(
              controller: _bodyCtrl,
              focusNode: _bodyFocus,
              enabled: !_busy,
              maxLength: 160,
              maxLines: 4,
              minLines: 3,
              onChanged: (_) => setState(() {}),
              style: TextStyle(color: _fg, fontSize: 15),
              cursorColor: _purple,
              decoration: InputDecoration(
                hintText: 'What do you want to tell them?',
                hintStyle: TextStyle(color: _muted, fontSize: 14),
                filled: true,
                fillColor: _bg,
                counterStyle: TextStyle(color: _muted, fontSize: 11),
                border:        OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _purple, width: 1.5)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 4),
              Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
            ],
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _busy ? null : _send,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _purple,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: _border,
                  disabledForegroundColor: _muted,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : Text(
                        'Send to ${widget.recipientCount} guest${widget.recipientCount == 1 ? '' : 's'}',
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Center(
              child: TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: Text('Cancel', style: TextStyle(color: _muted, fontSize: 13)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
