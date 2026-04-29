import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils.dart';
import '../widgets/rsvp_live_counts.dart';
import 'create_event_screen.dart';
import 'host_notifications_screen.dart';
import 'settings_screen.dart';
import 'guest_event_screen.dart';
import 'business_qr_screen.dart';

// ── Theme palette ───────────────────────────────────────────────
// Same const palette as the Business / Personal feeds; centralised
// here so this screen renders correctly even before Theme.of(context)
// resolves (e.g. shimmer state).
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

/// Headquarters-tier home feed. Different shape from
/// [BusinessHomeFeedScreen] — this one is a "command center" view for
/// Headquarters owners managing multiple Business locations under one
/// organization, not the per-event upcoming/past feed a single host
/// works in.
///
/// Sections (top to bottom):
///   1. AppBar — wordmark + green HEADQUARTERS badge + actions
///   2. Org overview card — gradient summary of org name, locations,
///      cumulative RSVPs, events this month
///   3. Smart alert — gold banner if any upcoming event has zero RSVPs
///   4. Your Locations — header + Add Location + per-location cards
///   5. Organization Page banner — slim coming-soon strip
///   6. Quick Actions — Create New Event tile
///
/// Linked Business accounts are not yet implemented — the locations
/// list renders an empty/placeholder state for now. The overview card
/// + smart alert + create-event tile are fully live.
class HeadquartersHomeFeedScreen extends StatefulWidget {
  const HeadquartersHomeFeedScreen({super.key});
  @override
  State<HeadquartersHomeFeedScreen> createState() => _HeadquartersHomeFeedScreenState();
}

class _HeadquartersHomeFeedScreenState extends State<HeadquartersHomeFeedScreen> {
  StreamSubscription<DocumentSnapshot>? _userSub;
  StreamSubscription<QuerySnapshot>? _orgSub;
  StreamSubscription<QuerySnapshot>? _eventsSub;
  StreamSubscription<QuerySnapshot>? _publicEventsSub;

  Map<String, dynamic>? _org;
  String? _orgId;
  // Raw event docs hosted by the current user. Used to compute the
  // overview stats (RSVPs total, events this month) and to detect
  // upcoming events with zero RSVPs for the smart alert.
  List<Map<String, dynamic>> _events = [];
  bool _eventsLoaded = false;

  // Public events feed for the Explore tab. Loaded lazily — first
  // subscribed when the user actually selects the tab, so a HQ owner
  // who never visits Explore doesn't pay the read cost.
  List<Map<String, dynamic>> _publicEvents = [];
  bool _publicLoaded = false;
  bool _publicSubscribed = false;

  // Currently selected bottom-nav tab. 0=Home, 1=Analytics, 2=Calendar,
  // 3=Explore. Plain int rather than an enum so it round-trips through
  // BottomNavigationBar's currentIndex without a translation layer.
  int _tab = 0;

  // Calendar tab — month being viewed. Defaults to the current month;
  // arrows in the calendar header step ±1 month. Day is always 1 to
  // simplify the month-grid math; never read for anything else.
  late DateTime _calMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);

  // Single-location stub. When linked Business accounts ship, this
  // grows to one entry per linked location with a distinct accent
  // color drawn from [_locationPalette]. The Calendar/Analytics tabs
  // already iterate this list, so adding entries is the only change
  // those views will need.
  static const List<Color> _locationPalette = [
    _purple, _gold, AppColors.green,
    Color(0xFF7B5EA7), Color(0xFFE07A5F), Color(0xFF4A8FE7),
  ];

  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;
  Color get _fg     => _isDark ? Colors.white : AppColors.dark;

  @override
  void initState() {
    super.initState();
    _subscribeAll();
  }

  @override
  void dispose() {
    _userSub?.cancel();
    _orgSub?.cancel();
    _eventsSub?.cancel();
    _publicEventsSub?.cancel();
    super.dispose();
  }

  /// Lazy subscriber for the Explore tab. First call wires up the
  /// `events.where('isPublic', '==', true)` listener; subsequent calls
  /// are no-ops. Drafts/archived/past are filtered client-side. Kept
  /// off the boot path so the typical HQ user (who never opens
  /// Explore) doesn't pay the read cost.
  void _ensurePublicSubscribed() {
    if (_publicSubscribed) return;
    _publicSubscribed = true;
    _publicEventsSub = FirebaseFirestore.instance
        .collection('events')
        .where('isPublic', isEqualTo: true)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _publicEvents = snap.docs.map((d) {
          final m = Map<String, dynamic>.from(d.data() as Map);
          m['_id'] = d.id;
          return m;
        }).toList();
        _publicLoaded = true;
      });
    }, onError: (Object e) {
      debugPrint('[Headquarters] public events stream error: $e');
    });
  }

  void _subscribeAll() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    // User doc stream just kept alive so a tier flip flushes us out
    // of this screen via HomeRouter without a manual reload.
    _userSub = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .listen((_) {});
    _orgSub = FirebaseFirestore.instance
        .collection('organizations')
        .where('ownerId', isEqualTo: user.uid)
        .limit(1)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      if (snap.docs.isEmpty) {
        setState(() { _orgId = null; _org = null; });
        return;
      }
      final doc = snap.docs.first;
      setState(() { _orgId = doc.id; _org = doc.data(); });
    });
    _eventsSub = FirebaseFirestore.instance
        .collection('events')
        .where('hostId', isEqualTo: user.uid)
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
      debugPrint('[Headquarters] events stream error: $e');
    });
  }

  // ── Derived stats ─────────────────────────────────────────────
  /// Total locations under this Headquarters. Counts the HQ owner
  /// itself as 1 plus any linked Business accounts (none yet — that
  /// integration is Coming Soon, so the list is always [you]).
  int get _totalLocations => 1;

  /// Sum of yes + maybe + no counters across every event this user
  /// hosts. Reads cached parent-doc counters (kept in sync now that
  /// both the app and event.html use atomic increments) — far cheaper
  /// than a per-event subcollection sum at the home-feed level.
  int get _totalRsvpsAllLocations {
    return _events.fold<int>(
      0,
      (acc, e) =>
          acc +
          ((e['yes']   as num?)?.toInt() ?? 0) +
          ((e['maybe'] as num?)?.toInt() ?? 0) +
          ((e['no']    as num?)?.toInt() ?? 0),
    );
  }

  /// Count of events whose `date` falls within the current calendar
  /// month. Drafts excluded — they count once they're published.
  int get _eventsThisMonth {
    final now = DateTime.now();
    return _events.where((e) {
      if ((e['isDraft'] as bool?) ?? false) return false;
      final ts = e['date'] as Timestamp?;
      if (ts == null) return false;
      final d = ts.toDate();
      return d.year == now.year && d.month == now.month;
    }).length;
  }

  /// Returns the first upcoming event with zero RSVPs across all
  /// statuses, or null if every upcoming event has at least one
  /// response. Drives the smart-alert banner.
  Map<String, dynamic>? get _zeroRsvpUpcoming {
    final now = DateTime.now();
    for (final e in _events) {
      if ((e['isDraft'] as bool?) ?? false) continue;
      final ts = e['date'] as Timestamp?;
      if (ts == null) continue;
      if (ts.toDate().isBefore(now)) continue;
      final yes   = (e['yes']   as num?)?.toInt() ?? 0;
      final maybe = (e['maybe'] as num?)?.toInt() ?? 0;
      final no    = (e['no']    as num?)?.toInt() ?? 0;
      if (yes + maybe + no == 0) return e;
    }
    return null;
  }

  String get _orgName => (_org?['name'] as String?)?.trim().isNotEmpty == true
      ? (_org!['name'] as String)
      : 'Your Organization';

  // ── Build ─────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: _buildAppBar(),
      body: SafeArea(
        top: false,
        child: _buildTabBody(),
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildTabBody() {
    switch (_tab) {
      case 1: return _buildAnalyticsTab();
      case 2: return _buildCalendarTab();
      case 3: return _buildExploreTab();
      case 0:
      default: return _buildHomeTab();
    }
  }

  /// HQ feed body — same six sections the screen had before the bottom
  /// nav was introduced. Renders inside the Home tab.
  Widget _buildHomeTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        const SizedBox(height: 8),
        _buildOrgOverviewCard(),
        const SizedBox(height: 14),
        if (_zeroRsvpUpcoming != null) ...[
          _buildSmartAlert(_zeroRsvpUpcoming!),
          const SizedBox(height: 14),
        ],
        _buildLocationsHeader(),
        const SizedBox(height: 10),
        _buildLocationsList(),
        const SizedBox(height: 18),
        ..._buildHostedEventsSection(),
        _buildOrgPageBanner(),
        const SizedBox(height: 18),
        _buildQuickActions(),
      ],
    );
  }

  // ── Your Events section ───────────────────────────────────────
  /// Sandwich-section between locations and the org banner showing
  /// the HQ owner's own upcoming events. Returns a list of widgets so
  /// it can splat into the parent ListView via the spread operator;
  /// the section is fully suppressed (zero widgets) until the events
  /// stream resolves AND there's at least one upcoming event, so the
  /// home tab doesn't grow an empty container while loading.
  List<Widget> _buildHostedEventsSection() {
    if (!_eventsLoaded) return const [];
    final now = DateTime.now();
    final upcoming = _events.where((e) {
      if ((e['isDraft']    as bool?) ?? false) return false;
      if ((e['isArchived'] as bool?) ?? false) return false;
      final ts = e['date'] as Timestamp?;
      if (ts == null) return false;
      final eventStart = _resolveEventStart(ts.toDate(), e['time'] as String?);
      return !eventStart.isBefore(now);
    }).toList()
      ..sort((a, b) {
        final ad = (a['date'] as Timestamp).toDate();
        final bd = (b['date'] as Timestamp).toDate();
        return ad.compareTo(bd);
      });
    if (upcoming.isEmpty) return const [];
    return [
      _buildEventsSectionHeader(upcoming.length),
      const SizedBox(height: 10),
      ...upcoming.map(_buildHostedEventCard),
      const SizedBox(height: 18),
    ];
  }

  /// Combines `date` (midnight Timestamp) with the `time` string
  /// ("HH:MM") into the actual event-start DateTime. Mirrors the
  /// helper in business_home_feed_screen.dart so a same-day event
  /// without a specific start time stays in Upcoming until midnight.
  DateTime _resolveEventStart(DateTime calendarDate, String? timeStr) {
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
    return DateTime(calendarDate.year, calendarDate.month, calendarDate.day, 23, 59, 59);
  }

  Widget _buildEventsSectionHeader(int count) => Padding(
        padding: const EdgeInsets.only(bottom: 4, left: 2),
        child: Row(children: [
          Text(
            'Your Events',
            style: TextStyle(fontFamily: 'FredokaOne', fontSize: 18, color: _fg),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: _purple.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontFamily: 'Nunito', fontSize: 11, fontWeight: FontWeight.w900,
                color: _purple, letterSpacing: 0.4,
              ),
            ),
          ),
        ]),
      );

  /// Per-event card — same chrome as business_home_feed_screen.dart's
  /// `_buildUpcomingCard`: 16-radius `_card` background, emoji tile +
  /// title + date stack, optional location row, live RSVP totals via
  /// [RsvpLiveCounts] with a progress bar. Tap opens GuestEventScreen.
  Widget _buildHostedEventCard(Map<String, dynamic> event) {
    final ts = event['date'] as Timestamp;
    final date = ts.toDate();
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final dateStr = '${months[date.month - 1]} ${date.day}, ${date.year}';
    final title = (event['title'] as String?) ?? 'Untitled';
    final emoji = (event['eventEmoji'] as String?) ?? '🎉';
    final location = (event['location'] as String?) ?? '';
    final eventId = event['_id'] as String;
    // Cached parent counters seed RsvpLiveCounts so the card doesn't
    // 0-flash before the rsvps subcollection sum resolves. The live
    // builder below replaces them once the snapshot lands.
    final initialYes   = ((event['yes']   as num?)?.toInt()) ?? 0;
    final initialMaybe = ((event['maybe'] as num?)?.toInt()) ?? 0;
    final initialNo    = ((event['no']    as num?)?.toInt()) ?? 0;

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
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text(emoji, style: const TextStyle(fontSize: 24)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _fg),
                    ),
                    Text(dateStr, style: TextStyle(fontSize: 12, color: _muted)),
                  ],
                ),
              ),
            ]),
            if (location.isNotEmpty) ...[
              const SizedBox(height: 6),
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
            const SizedBox(height: 12),
            // Live counts from the rsvps subcollection. Sums adults +
            // children + plus-ones per RSVP doc so a family-of-4
            // contributes 4. Cached parent counters seed only the
            // initial render — same pattern as business_home_feed.
            RsvpLiveCounts(
              eventId: eventId,
              initial: (yes: initialYes, maybe: initialMaybe, no: initialNo),
              builder: (ctx, yes, maybe, no) {
                final total = yes + maybe + no;
                final progress = total > 0 ? yes / total : 0.0;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          "$yes going · $maybe maybe · $no can't",
                          style: TextStyle(fontSize: 11, color: _muted),
                        ),
                        Text(
                          '$total total',
                          style: const TextStyle(
                            fontSize: 11, color: _purple, fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 5,
                        backgroundColor: _border,
                        valueColor: const AlwaysStoppedAnimation<Color>(_purple),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── Bottom nav ────────────────────────────────────────────────
  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: _card,
        border: Border(top: BorderSide(color: _border)),
      ),
      child: SafeArea(
        top: false,
        child: BottomNavigationBar(
          backgroundColor: _card,
          elevation: 0,
          type: BottomNavigationBarType.fixed,
          currentIndex: _tab,
          onTap: (i) {
            // Lazy-subscribe Explore so the read cost only kicks in
            // when the user actually opens that tab.
            if (i == 3) _ensurePublicSubscribed();
            setState(() => _tab = i);
          },
          selectedItemColor: _purple,
          unselectedItemColor: _muted,
          showUnselectedLabels: true,
          selectedLabelStyle: const TextStyle(
            fontFamily: 'Nunito', fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 0.2,
          ),
          unselectedLabelStyle: const TextStyle(
            fontFamily: 'Nunito', fontSize: 11.5, fontWeight: FontWeight.w700,
          ),
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined),
              activeIcon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.bar_chart_outlined),
              activeIcon: Icon(Icons.bar_chart_rounded),
              label: 'Analytics',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.calendar_month_outlined),
              activeIcon: Icon(Icons.calendar_month_rounded),
              label: 'Calendar',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.explore_outlined),
              activeIcon: Icon(Icons.explore_rounded),
              label: 'Explore',
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _bg,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      title: Row(children: [
        Flexible(
          child: Text(
            'QR Party',
            style: TextStyle(fontFamily: 'FredokaOne', fontSize: 20, color: _fg),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        // Headquarters tier badge — green to differentiate from the
        // gold "PRO" pill on the Business tier feed.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: AppColors.green, borderRadius: BorderRadius.circular(7)),
          child: const Text(
            'HEADQUARTERS',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 10, fontWeight: FontWeight.w900,
              color: Colors.white, letterSpacing: 0.7,
            ),
          ),
        ),
      ]),
      actions: [
        IconButton(
          icon: Icon(Icons.notifications_outlined, color: _fg),
          tooltip: 'Notifications',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const HostNotificationsScreen()),
          ),
        ),
        // Account moved to the AppBar (top-right) per the HTML demo —
        // the bottom nav has no Account tab. SettingsScreen still owns
        // every account-level surface (logout, plan, billing, theme).
        IconButton(
          icon: Icon(Icons.person_outline, color: _fg),
          tooltip: 'Account',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  // ── Org overview card ─────────────────────────────────────────
  Widget _buildOrgOverviewCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF3B2F68), Color(0xFF2B2A4E), Color(0xFF252641)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _purple.withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: _purple.withValues(alpha: 0.22),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.green.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.green.withValues(alpha: 0.55)),
              ),
              child: const Text(
                'HEADQUARTERS',
                style: TextStyle(
                  fontFamily: 'Nunito', fontSize: 9, fontWeight: FontWeight.w900,
                  color: AppColors.greenLight, letterSpacing: 1.1,
                ),
              ),
            ),
            const Spacer(),
            const Icon(Icons.business_outlined, size: 18, color: _gold),
          ]),
          const SizedBox(height: 10),
          Text(
            _orgName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'FredokaOne', fontSize: 24,
              color: Colors.white, height: 1.1, letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _orgId == null
                ? 'Your command center for every linked location.'
                : 'partywithqr.com/org/${_orgId!}',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Nunito', fontSize: 12, color: Colors.white70,
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: _statTile('$_totalLocations', 'Locations')),
            Container(width: 1, height: 32, color: Colors.white.withValues(alpha: 0.10)),
            Expanded(child: _statTile('$_totalRsvpsAllLocations', 'Total RSVPs')),
            Container(width: 1, height: 32, color: Colors.white.withValues(alpha: 0.10)),
            Expanded(child: _statTile('$_eventsThisMonth', 'This month')),
          ]),
        ],
      ),
    );
  }

  Widget _statTile(String value, String label) => Column(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Text(value,
          style: const TextStyle(
            fontFamily: 'FredokaOne', fontSize: 22,
            color: Colors.white, height: 1.1,
          )),
      const SizedBox(height: 2),
      Text(label,
          style: const TextStyle(
            fontFamily: 'Nunito', fontSize: 11, fontWeight: FontWeight.w700,
            color: Colors.white60, letterSpacing: 0.4,
          )),
    ],
  );

  // ── Smart alert ───────────────────────────────────────────────
  Widget _buildSmartAlert(Map<String, dynamic> event) {
    final title = (event['title'] as String?) ?? 'an upcoming event';
    final eventId = event['_id'] as String?;
    return GestureDetector(
      onTap: eventId == null
          ? null
          : () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => GuestEventScreen(
                    eventId: eventId,
                    eventData: Map<String, dynamic>.from(event),
                  ),
                ),
              ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: _gold.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _gold.withValues(alpha: 0.55)),
        ),
        child: Row(children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.30),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.priority_high_rounded, color: _gold, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Heads up — no RSVPs yet',
                  style: TextStyle(
                    fontFamily: 'Nunito', fontSize: 13.5, fontWeight: FontWeight.w800,
                    color: _isDark ? Colors.white : AppColors.dark,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '"$title" is coming up with no responses yet. Tap to open.',
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Nunito', fontSize: 12, color: _muted, height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Icon(Icons.chevron_right, size: 20, color: _gold.withValues(alpha: 0.85)),
        ]),
      ),
    );
  }

  // ── Locations section ─────────────────────────────────────────
  Widget _buildLocationsHeader() {
    return Row(
      children: [
        Text(
          'Your Locations',
          style: TextStyle(
            fontFamily: 'FredokaOne', fontSize: 18, color: _fg,
          ),
        ),
        const Spacer(),
        TextButton.icon(
          onPressed: () => _showAddLocationComingSoon(),
          icon: const Icon(Icons.add_circle_outline, size: 16, color: _purple),
          label: const Text(
            'Add Location',
            style: TextStyle(
              fontFamily: 'Nunito', fontSize: 13, fontWeight: FontWeight.w800,
              color: _purple,
            ),
          ),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ],
    );
  }

  void _showAddLocationComingSoon() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(color: _border, borderRadius: BorderRadius.circular(2)),
              )),
              const SizedBox(height: 18),
              Text(
                'Linked Locations · Coming Soon',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'FredokaOne', fontSize: 22, color: _fg,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Soon you\'ll be able to invite Business accounts under your Headquarters and manage every linked location\'s events, RSVPs and stickers from this screen.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Nunito', fontSize: 14, color: _muted, height: 1.5,
                ),
              ),
              const SizedBox(height: 22),
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(sheetCtx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _purple,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                  child: const Text(
                    'Got it',
                    style: TextStyle(fontFamily: 'Nunito', fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Currently a single placeholder card explaining linked Business
  /// accounts are not yet available, plus a dashed "+ Add Location"
  /// tile inviting the user to come back. When the linking feature
  /// ships, this section will render real per-location cards using
  /// the [_buildLocationCard] helper below.
  Widget _buildLocationsList() {
    if (!_eventsLoaded) return _buildLocationsShimmer();

    return Column(children: [
      // Placeholder card for the user's own HQ — shown so the section
      // doesn't feel empty before linked locations roll out. Uses a
      // purple accent border to set the visual pattern that real
      // location cards will follow.
      _buildLocationCard(
        accent: _purple,
        emoji: '🏢',
        name: _orgName,
        address: _org?['description'] as String? ?? 'Your Headquarters',
        statusLabel: 'Active',
        statusColor: AppColors.green,
        rsvps: _totalRsvpsAllLocations,
        events: _events.where((e) => (e['isDraft'] as bool?) != true).length,
        upcoming: _events.where((e) {
          if ((e['isDraft'] as bool?) ?? false) return false;
          final ts = e['date'] as Timestamp?;
          if (ts == null) return false;
          return !ts.toDate().isBefore(DateTime.now());
        }).length,
        nextEvent: _nextUpcoming,
      ),
      const SizedBox(height: 10),
      _buildAddLocationTile(),
    ]);
  }

  Map<String, dynamic>? get _nextUpcoming {
    final now = DateTime.now();
    final upcoming = _events.where((e) {
      if ((e['isDraft'] as bool?) ?? false) return false;
      final ts = e['date'] as Timestamp?;
      if (ts == null) return false;
      return !ts.toDate().isBefore(now);
    }).toList();
    if (upcoming.isEmpty) return null;
    upcoming.sort((a, b) {
      final ad = (a['date'] as Timestamp).toDate();
      final bd = (b['date'] as Timestamp).toDate();
      return ad.compareTo(bd);
    });
    return upcoming.first;
  }

  Widget _buildLocationCard({
    required Color accent,
    required String emoji,
    required String name,
    required String address,
    required String statusLabel,
    required Color statusColor,
    required int rsvps,
    required int events,
    required int upcoming,
    Map<String, dynamic>? nextEvent,
  }) {
    final months = const ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    String? nextLine;
    Map<String, dynamic>? tappable;
    if (nextEvent != null) {
      final title = (nextEvent['title'] as String?) ?? 'Next event';
      final ts = nextEvent['date'] as Timestamp?;
      final d = ts?.toDate();
      final dateStr = d != null ? '${months[d.month - 1]} ${d.day}' : '';
      nextLine = '$title${dateStr.isEmpty ? '' : ' · $dateStr'}';
      tappable = nextEvent;
    }

    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(width: 5, color: accent),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(
                      width: 44, height: 44,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Center(child: Text(emoji, style: const TextStyle(fontSize: 22))),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Nunito', fontSize: 15, fontWeight: FontWeight.w800,
                              color: _fg,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            address,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Nunito', fontSize: 12, color: _muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        statusLabel,
                        style: TextStyle(
                          fontFamily: 'Nunito', fontSize: 10.5, fontWeight: FontWeight.w800,
                          color: statusColor, letterSpacing: 0.4,
                        ),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    _miniMetric('$rsvps', 'RSVPs'),
                    Container(width: 1, height: 24, color: _border),
                    _miniMetric('$events', 'Events'),
                    Container(width: 1, height: 24, color: _border),
                    _miniMetric('$upcoming', 'Upcoming'),
                  ]),
                  if (nextLine != null) ...[
                    const SizedBox(height: 12),
                    InkWell(
                      onTap: tappable == null
                          ? null
                          : () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => GuestEventScreen(
                                    eventId: tappable!['_id'] as String,
                                    eventData: Map<String, dynamic>.from(tappable),
                                  ),
                                ),
                              ),
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                        child: Row(children: [
                          Icon(Icons.event_outlined, size: 14, color: accent),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              nextLine,
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Nunito', fontSize: 12, fontWeight: FontWeight.w700,
                                color: _fg,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'View →',
                            style: TextStyle(
                              fontFamily: 'Nunito', fontSize: 12, fontWeight: FontWeight.w800,
                              color: accent,
                            ),
                          ),
                        ]),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniMetric(String value, String label) => Expanded(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontFamily: 'FredokaOne', fontSize: 16, color: _fg, height: 1.1,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Nunito', fontSize: 10.5, fontWeight: FontWeight.w700,
              color: _muted, letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _buildAddLocationTile() {
    return InkWell(
      onTap: _showAddLocationComingSoon,
      borderRadius: BorderRadius.circular(16),
      child: DottedBorder(
        color: _border,
        radius: 16,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
          child: Row(children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: _purple.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.add, color: _purple, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Link a Business location',
                    style: TextStyle(
                      fontFamily: 'Nunito', fontSize: 14, fontWeight: FontWeight.w800,
                      color: _fg,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Coming Soon — invite a Business account to roll up under this HQ.',
                    style: TextStyle(
                      fontFamily: 'Nunito', fontSize: 12, color: _muted, height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _gold,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'COMING SOON',
                style: TextStyle(
                  fontFamily: 'Nunito', fontSize: 9, fontWeight: FontWeight.w900,
                  color: Colors.white, letterSpacing: 0.6,
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildLocationsShimmer() {
    return Container(
      height: 110,
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      alignment: Alignment.center,
      child: const SizedBox(
        width: 22, height: 22,
        child: CircularProgressIndicator(color: _purple, strokeWidth: 2),
      ),
    );
  }

  // ── Org Page banner ───────────────────────────────────────────
  Widget _buildOrgPageBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _purple.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _purple.withValues(alpha: 0.30)),
      ),
      child: Row(children: [
        const Text('🌐', style: TextStyle(fontSize: 18)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Organization Page',
                style: TextStyle(
                  fontFamily: 'Nunito', fontSize: 13.5, fontWeight: FontWeight.w800,
                  color: _fg,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                'One QR code that lists every linked location\'s events.',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Nunito', fontSize: 11.5, color: _muted,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: _gold,
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Text(
            'COMING SOON',
            style: TextStyle(
              fontFamily: 'Nunito', fontSize: 9, fontWeight: FontWeight.w900,
              color: Colors.white, letterSpacing: 0.6,
            ),
          ),
        ),
      ]),
    );
  }

  // ── Quick Actions ─────────────────────────────────────────────
  Widget _buildQuickActions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Text(
            'Quick Actions',
            style: TextStyle(
              fontFamily: 'FredokaOne', fontSize: 18, color: _fg,
            ),
          ),
        ),
        InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const CreateEventScreen()),
          ),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [AppColors.green, AppColors.greenLight],
                begin: Alignment.topLeft, end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: AppColors.green.withValues(alpha: 0.32),
                  blurRadius: 18, offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.add, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Create New Event',
                      style: TextStyle(
                        fontFamily: 'Nunito', fontSize: 16, fontWeight: FontWeight.w900,
                        color: Colors.white, letterSpacing: 0.2,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'One QR. Every RSVP handled.',
                      style: TextStyle(
                        fontFamily: 'Nunito', fontSize: 12, fontWeight: FontWeight.w600,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white70, size: 22),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        // Permanent business QR — provisions on first tap and opens
        // the dedicated screen with download/share options. Sits in
        // Quick Actions so HQ owners can hand out their location-level
        // QR alongside the create-event affordance.
        InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const BusinessQRScreen()),
          ),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [_purple.withValues(alpha: 0.22), _purple.withValues(alpha: 0.08)],
                begin: Alignment.topLeft, end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
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
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Business QR Code',
                      style: TextStyle(
                        fontFamily: 'Nunito', fontSize: 16, fontWeight: FontWeight.w900,
                        color: _fg, letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'One QR. Every public event you host.',
                      style: TextStyle(
                        fontFamily: 'Nunito', fontSize: 12, fontWeight: FontWeight.w600,
                        color: _muted,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: _purple, size: 22),
            ]),
          ),
        ),
      ],
    );
  }

  // ── Locations model (single-location stub) ────────────────────
  /// Logical locations under this Headquarters. Today the list always
  /// contains exactly one entry — the user's own HQ — colored with the
  /// first palette accent. When linked Business accounts ship, this
  /// grows to one entry per linked location and Calendar/Analytics
  /// pick up the new dimensions automatically.
  List<({String id, String name, Color accent})> get _locations => [(
        id: 'primary',
        name: _orgName,
        accent: _locationPalette[0],
      )];

  /// Maps an event to a location id. While linking is Coming Soon,
  /// every event belongs to 'primary'. Once events carry a `locationId`
  /// field this becomes a one-line read of that field with a
  /// 'primary' fallback for legacy docs.
  String _eventLocationId(Map<String, dynamic> _) => 'primary';

  Color _eventLocationAccent(Map<String, dynamic> e) {
    final id = _eventLocationId(e);
    final match = _locations.where((l) => l.id == id).toList();
    return match.isEmpty ? _purple : match.first.accent;
  }

  int _eventTotalRsvps(Map<String, dynamic> e) =>
      ((e['yes']   as num?)?.toInt() ?? 0) +
      ((e['maybe'] as num?)?.toInt() ?? 0) +
      ((e['no']    as num?)?.toInt() ?? 0);

  bool _isLiveEvent(Map<String, dynamic> e) {
    if ((e['isDraft']    as bool?) ?? false) return false;
    if ((e['isArchived'] as bool?) ?? false) return false;
    return true;
  }

  // ── Analytics tab ─────────────────────────────────────────────
  /// Org-wide summary: 2×2 stat grid, per-location bar chart, top
  /// events list. Reads from cached parent-doc counters — same trade
  /// the home tab makes, so the totals are consistent across tabs.
  Widget _buildAnalyticsTab() {
    if (!_eventsLoaded) {
      return const Center(child: CircularProgressIndicator(color: _purple));
    }
    final liveEvents = _events.where(_isLiveEvent).toList();
    final totalRsvps = liveEvents.fold<int>(0, (s, e) => s + _eventTotalRsvps(e));
    final totalEvents = liveEvents.length;
    final avgAttendance = totalEvents == 0 ? 0 : (totalRsvps / totalEvents).round();
    final activeLocations = _locations.length;

    final perLocation = <String, int>{
      for (final l in _locations) l.id: 0,
    };
    for (final e in liveEvents) {
      final id = _eventLocationId(e);
      perLocation[id] = (perLocation[id] ?? 0) + _eventTotalRsvps(e);
    }
    final maxLocRsvps = perLocation.values.fold<int>(0, (m, v) => v > m ? v : m);

    final topEvents = [...liveEvents]
      ..sort((a, b) => _eventTotalRsvps(b).compareTo(_eventTotalRsvps(a)));
    final top = topEvents.take(5).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text(
          'Analytics',
          style: TextStyle(fontFamily: 'FredokaOne', fontSize: 22, color: _fg),
        ),
        const SizedBox(height: 4),
        Text(
          'Org-wide rollup across every location.',
          style: TextStyle(fontFamily: 'Nunito', fontSize: 12, color: _muted),
        ),
        const SizedBox(height: 16),
        // 2×2 stat grid — same card chrome as the Business home feed
        // stats row, restructured into two rows for the wider screen.
        Row(children: [
          _statTileBox('$totalRsvps', 'Total RSVPs', _purple),
          const SizedBox(width: 10),
          _statTileBox('$totalEvents', 'Total Events', _gold),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          _statTileBox('$avgAttendance', 'Avg / Event', AppColors.green),
          const SizedBox(width: 10),
          _statTileBox('$activeLocations', 'Locations Active', _purple),
        ]),
        const SizedBox(height: 22),
        _buildSectionHeader('RSVPs by Location'),
        const SizedBox(height: 10),
        _buildLocationBarChart(perLocation, maxLocRsvps),
        const SizedBox(height: 22),
        _buildSectionHeader('Top Events'),
        const SizedBox(height: 10),
        if (top.isEmpty)
          _buildEmptyTile('No events yet', 'Once you publish events, your highest-RSVP ones appear here.')
        else
          ...top.map(_buildTopEventTile),
      ],
    );
  }

  Widget _statTileBox(String value, String label, Color valueColor) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: TextStyle(
                fontFamily: 'FredokaOne', fontSize: 26,
                color: valueColor, height: 1.0,
              )),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(
                fontFamily: 'Nunito', fontSize: 11.5, fontWeight: FontWeight.w700,
                color: _muted, letterSpacing: 0.3,
              )),
        ],
      ),
    ),
  );

  Widget _buildSectionHeader(String label) => Padding(
    padding: const EdgeInsets.only(left: 2),
    child: Text(
      label,
      style: TextStyle(fontFamily: 'FredokaOne', fontSize: 16, color: _fg),
    ),
  );

  Widget _buildLocationBarChart(Map<String, int> data, int maxValue) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(
        children: _locations.map((loc) {
          final value = data[loc.id] ?? 0;
          // Bar fill ratio. Guard against /0 — when no location has any
          // RSVPs we render empty tracks so the chart still has shape.
          final ratio = maxValue == 0 ? 0.0 : value / maxValue;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    width: 10, height: 10,
                    decoration: BoxDecoration(
                      color: loc.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      loc.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Nunito', fontSize: 13, fontWeight: FontWeight.w800,
                        color: _fg,
                      ),
                    ),
                  ),
                  Text('$value',
                      style: TextStyle(
                        fontFamily: 'Nunito', fontSize: 13, fontWeight: FontWeight.w800,
                        color: loc.accent,
                      )),
                ]),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LayoutBuilder(builder: (ctx, c) {
                    return Stack(children: [
                      Container(
                        width: c.maxWidth,
                        height: 10,
                        color: _border,
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 240),
                        curve: Curves.easeOutCubic,
                        width: (c.maxWidth * ratio).clamp(0.0, c.maxWidth),
                        height: 10,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [
                            loc.accent,
                            loc.accent.withValues(alpha: 0.65),
                          ]),
                        ),
                      ),
                    ]);
                  }),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildTopEventTile(Map<String, dynamic> event) {
    final accent = _eventLocationAccent(event);
    final total = _eventTotalRsvps(event);
    final title = (event['title'] as String?) ?? 'Untitled';
    final emoji = (event['eventEmoji'] as String?) ?? '🎉';
    final eventId = event['_id'] as String?;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: eventId == null
            ? null
            : () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => GuestEventScreen(
                      eventId: eventId,
                      eventData: Map<String, dynamic>.from(event),
                    ),
                  ),
                ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(width: 4, color: accent),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Row(children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: Text(emoji, style: const TextStyle(fontSize: 18)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Nunito', fontSize: 14, fontWeight: FontWeight.w800,
                      color: _fg,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '$total RSVPs',
                    style: TextStyle(
                      fontFamily: 'Nunito', fontSize: 11.5, fontWeight: FontWeight.w900,
                      color: accent, letterSpacing: 0.3,
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildEmptyTile(String title, String body) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
    decoration: BoxDecoration(
      color: _card,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: _border, style: BorderStyle.solid),
    ),
    alignment: Alignment.center,
    child: Column(children: [
      Text(title,
          style: TextStyle(
            fontFamily: 'Nunito', fontSize: 14, fontWeight: FontWeight.w800, color: _fg,
          )),
      const SizedBox(height: 4),
      Text(body, textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Nunito', fontSize: 12, color: _muted, height: 1.4,
          )),
    ]),
  );

  // ── Calendar tab ──────────────────────────────────────────────
  /// Month grid + upcoming list. Each cell shows the date number with
  /// up to 4 location-colored dots beneath. Below the grid, every
  /// upcoming live event is listed in date order with its location
  /// accent dot.
  Widget _buildCalendarTab() {
    if (!_eventsLoaded) {
      return const Center(child: CircularProgressIndicator(color: _purple));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        _buildLocationLegend(),
        const SizedBox(height: 14),
        _buildMonthHeader(),
        const SizedBox(height: 8),
        _buildWeekdayRow(),
        const SizedBox(height: 6),
        _buildMonthGrid(),
        const SizedBox(height: 22),
        _buildSectionHeader('Upcoming'),
        const SizedBox(height: 10),
        ..._buildUpcomingList(),
      ],
    );
  }

  Widget _buildLocationLegend() {
    // Show the Deadline chip only when at least one event in the
    // current view actually has a deadline set — saves the legend
    // from screaming "DEADLINE" at hosts who haven't used the
    // feature yet, while still appearing automatically the first
    // time they set one.
    final anyDeadline = _events.any((e) =>
        _isLiveEvent(e) && e['rsvpDeadline'] is Timestamp);
    return Wrap(
      spacing: 8, runSpacing: 8,
      children: [
        ..._locations.map((loc) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _card,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _border),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 10, height: 10,
                  decoration: BoxDecoration(color: loc.accent, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(loc.name,
                    style: TextStyle(
                      fontFamily: 'Nunito', fontSize: 12, fontWeight: FontWeight.w800, color: _fg,
                    )),
              ]),
            )),
        if (anyDeadline)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _gold.withValues(alpha: 0.55)),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.alarm_rounded, size: 12, color: _gold),
              SizedBox(width: 6),
              Text('RSVP deadline',
                  style: TextStyle(
                    fontFamily: 'Nunito', fontSize: 12, fontWeight: FontWeight.w800, color: _gold,
                  )),
            ]),
          ),
      ],
    );
  }

  Widget _buildMonthHeader() {
    const months = ['January','February','March','April','May','June',
                    'July','August','September','October','November','December'];
    final label = '${months[_calMonth.month - 1]} ${_calMonth.year}';
    return Row(children: [
      _monthArrow(Icons.chevron_left, () {
        setState(() => _calMonth = DateTime(_calMonth.year, _calMonth.month - 1, 1));
      }),
      Expanded(
        child: Center(
          child: Text(
            label,
            style: TextStyle(fontFamily: 'FredokaOne', fontSize: 18, color: _fg),
          ),
        ),
      ),
      _monthArrow(Icons.chevron_right, () {
        setState(() => _calMonth = DateTime(_calMonth.year, _calMonth.month + 1, 1));
      }),
    ]);
  }

  Widget _monthArrow(IconData icon, VoidCallback onTap) => Material(
    color: Colors.transparent,
    shape: const CircleBorder(),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          color: _card,
          shape: BoxShape.circle,
          border: Border.all(color: _border),
        ),
        alignment: Alignment.center,
        child: Icon(icon, color: _purple, size: 20),
      ),
    ),
  );

  Widget _buildWeekdayRow() {
    const labels = ['S','M','T','W','T','F','S'];
    return Row(
      children: labels.map((l) => Expanded(
        child: Center(
          child: Text(l, style: TextStyle(
            fontFamily: 'Nunito', fontSize: 11, fontWeight: FontWeight.w900,
            color: _muted, letterSpacing: 1.0,
          )),
        ),
      )).toList(),
    );
  }

  /// Months per visible cell — 6 rows × 7 cols of 56-tall cells. The
  /// leading blanks before the 1st use the cell's standard padding so
  /// the grid stays aligned even on a Sunday-start month.
  Widget _buildMonthGrid() {
    final firstOfMonth = DateTime(_calMonth.year, _calMonth.month, 1);
    // weekday: Mon=1..Sun=7 → want Sun=0..Sat=6 for a Sunday-start grid.
    final leadingBlanks = firstOfMonth.weekday % 7;
    final daysInMonth = DateTime(_calMonth.year, _calMonth.month + 1, 0).day;
    final today = DateTime.now();
    final isCurrentMonth = today.year == _calMonth.year && today.month == _calMonth.month;

    final cells = <Widget>[];
    for (var i = 0; i < leadingBlanks; i++) {
      cells.add(_calCell(null, false, [], false));
    }
    for (var day = 1; day <= daysInMonth; day++) {
      final cellDate = DateTime(_calMonth.year, _calMonth.month, day);
      final accents = _eventAccentsOnDate(cellDate);
      final hasDeadline = _hasDeadlineOnDate(cellDate);
      final isToday = isCurrentMonth && today.day == day;
      cells.add(_calCell(day, isToday, accents, hasDeadline));
    }
    // Pad to a 6-row grid so the next/prev month buttons don't shift
    // vertical layout depending on month length.
    while (cells.length % 7 != 0) {
      cells.add(_calCell(null, false, [], false));
    }
    while (cells.length < 42) {
      cells.add(_calCell(null, false, [], false));
    }

    final rows = <Widget>[];
    for (var r = 0; r < 6; r++) {
      rows.add(Row(children: [
        for (var c = 0; c < 7; c++) Expanded(child: cells[r * 7 + c]),
      ]));
    }
    return Column(children: rows);
  }

  Widget _calCell(int? day, bool isToday, List<Color> accents, bool hasDeadline) {
    if (day == null) {
      return const SizedBox(height: 56);
    }
    // Border + background priority: today's purple highlight wins
    // visually, but a deadline on today still earns the gold glyph
    // overlay below. On any non-today day with a deadline, render
    // the gold ring + faint gold tint so the cell reads "due date"
    // at a glance, distinct from the location-dot pattern that
    // marks event dates.
    final Color cellBg;
    final Color cellBorder;
    if (isToday) {
      cellBg = _purple.withValues(alpha: 0.16);
      cellBorder = _purple.withValues(alpha: 0.55);
    } else if (hasDeadline) {
      cellBg = _gold.withValues(alpha: 0.10);
      cellBorder = _gold.withValues(alpha: 0.65);
    } else {
      cellBg = Colors.transparent;
      cellBorder = Colors.transparent;
    }
    return Container(
      height: 56,
      margin: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: cellBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cellBorder, width: hasDeadline && !isToday ? 1.5 : 1),
      ),
      padding: const EdgeInsets.fromLTRB(6, 5, 6, 5),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '$day',
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 12.5,
                  fontWeight: isToday ? FontWeight.w900 : FontWeight.w700,
                  color: isToday ? _purple : _fg,
                ),
              ),
              const Spacer(),
              if (accents.isNotEmpty)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: accents.take(4).map((c) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1.5),
                    child: Container(
                      width: 5, height: 5,
                      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                    ),
                  )).toList(),
                ),
            ],
          ),
          // Deadline glyph in the top-right corner. Small enough to
          // co-exist with the day number on the left. Only shown
          // when at least one event's rsvpDeadline lands on this
          // cell — distinct from the location dots below which
          // mark event start dates.
          if (hasDeadline)
            const Positioned(
              top: 0, right: 0,
              child: Icon(Icons.alarm_rounded, size: 11, color: _gold),
            ),
        ],
      ),
    );
  }

  /// Location-accent colors for every live event whose `date` falls
  /// on [date]. Multiple same-color dots stay distinct because the
  /// caller takes only the first 4 — once linked locations exist,
  /// each dot picks up its location's distinct hue.
  List<Color> _eventAccentsOnDate(DateTime date) {
    final hits = <Color>[];
    for (final e in _events) {
      if (!_isLiveEvent(e)) continue;
      final ts = e['date'] as Timestamp?;
      if (ts == null) continue;
      final d = ts.toDate();
      if (d.year == date.year && d.month == date.month && d.day == date.day) {
        hits.add(_eventLocationAccent(e));
      }
    }
    return hits;
  }

  /// True iff any live event's `rsvpDeadline` lands on this calendar
  /// cell. Drives the gold ring + alarm glyph in [_calCell] so hosts
  /// can see at a glance which days they need to chase late RSVPs on.
  bool _hasDeadlineOnDate(DateTime date) {
    for (final e in _events) {
      if (!_isLiveEvent(e)) continue;
      final ts = e['rsvpDeadline'] as Timestamp?;
      if (ts == null) continue;
      final d = ts.toDate();
      if (d.year == date.year && d.month == date.month && d.day == date.day) {
        return true;
      }
    }
    return false;
  }

  List<Widget> _buildUpcomingList() {
    final now = DateTime.now();
    final upcoming = _events.where((e) {
      if (!_isLiveEvent(e)) return false;
      final ts = e['date'] as Timestamp?;
      if (ts == null) return false;
      return !ts.toDate().isBefore(DateTime(now.year, now.month, now.day));
    }).toList()
      ..sort((a, b) {
        final ad = (a['date'] as Timestamp).toDate();
        final bd = (b['date'] as Timestamp).toDate();
        return ad.compareTo(bd);
      });

    if (upcoming.isEmpty) {
      return [_buildEmptyTile('No upcoming events',
          'Create an event from the Home tab and it\'ll show here.')];
    }
    return upcoming.map(_buildUpcomingRow).toList();
  }

  Widget _buildUpcomingRow(Map<String, dynamic> event) {
    final accent = _eventLocationAccent(event);
    final title = (event['title'] as String?) ?? 'Untitled';
    final ts = event['date'] as Timestamp;
    final d = ts.toDate();
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final dateStr = '${months[d.month - 1]} ${d.day}, ${d.year}';
    final eventId = event['_id'] as String?;
    // Optional "RSVP by …" sub-line. Only renders when a deadline is
    // set, in gold so it ties to the calendar-cell ring/glyph above.
    final deadlineTs = event['rsvpDeadline'] as Timestamp?;
    final deadlineD = deadlineTs?.toDate();
    final deadlineStr = deadlineD == null
        ? null
        : 'RSVP by ${months[deadlineD.month - 1]} ${deadlineD.day}';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: eventId == null
            ? null
            : () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => GuestEventScreen(
                      eventId: eventId,
                      eventData: Map<String, dynamic>.from(event),
                    ),
                  ),
                ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            Container(
              width: 10, height: 10,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Nunito', fontSize: 13.5, fontWeight: FontWeight.w800,
                        color: _fg,
                      )),
                  const SizedBox(height: 2),
                  Text(dateStr,
                      style: TextStyle(
                        fontFamily: 'Nunito', fontSize: 11.5, color: _muted,
                      )),
                  if (deadlineStr != null) ...[
                    const SizedBox(height: 3),
                    Row(children: [
                      const Icon(Icons.alarm_rounded, size: 11, color: _gold),
                      const SizedBox(width: 4),
                      Text(deadlineStr,
                          style: const TextStyle(
                            fontFamily: 'Nunito', fontSize: 11, fontWeight: FontWeight.w800,
                            color: _gold, letterSpacing: 0.2,
                          )),
                    ]),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: _muted),
          ]),
        ),
      ),
    );
  }

  // ── Explore tab ───────────────────────────────────────────────
  /// Public events feed across the whole platform — drafts, archived,
  /// and past events filtered out client-side. Useful for HQ owners
  /// scoping competitive activity in their region.
  Widget _buildExploreTab() {
    if (!_publicLoaded) {
      return const Center(child: CircularProgressIndicator(color: _purple));
    }
    final now = DateTime.now();
    final upcoming = _publicEvents.where((e) {
      if ((e['isDraft']    as bool?) ?? false) return false;
      if ((e['isArchived'] as bool?) ?? false) return false;
      final ts = e['date'] as Timestamp?;
      if (ts == null) return false;
      return !ts.toDate().isBefore(DateTime(now.year, now.month, now.day));
    }).toList()
      ..sort((a, b) {
        final ad = (a['date'] as Timestamp).toDate();
        final bd = (b['date'] as Timestamp).toDate();
        return ad.compareTo(bd);
      });

    if (upcoming.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: _buildEmptyTile('No public events nearby',
              'When other hosts publish public events, they\'ll surface here.'),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text(
          'Explore',
          style: TextStyle(fontFamily: 'FredokaOne', fontSize: 22, color: _fg),
        ),
        const SizedBox(height: 4),
        Text(
          'Public events from every QR Party host.',
          style: TextStyle(fontFamily: 'Nunito', fontSize: 12, color: _muted),
        ),
        const SizedBox(height: 14),
        ...upcoming.map(_buildExploreCard),
      ],
    );
  }

  Widget _buildExploreCard(Map<String, dynamic> event) {
    final title = (event['title'] as String?) ?? 'Untitled';
    final emoji = (event['eventEmoji'] as String?) ?? '🎉';
    final hostName = (event['hostName'] as String?) ?? '';
    final location = (event['location'] as String?) ?? '';
    final ts = event['date'] as Timestamp?;
    final d = ts?.toDate();
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final dateStr = d == null ? '' : '${months[d.month - 1]} ${d.day}, ${d.year}';
    final eventId = event['_id'] as String?;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: eventId == null
            ? null
            : () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => GuestEventScreen(
                      eventId: eventId,
                      eventData: Map<String, dynamic>.from(event),
                    ),
                  ),
                ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: _purple.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Text(emoji, style: const TextStyle(fontSize: 22)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Nunito', fontSize: 14, fontWeight: FontWeight.w800,
                        color: _fg,
                      )),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (dateStr.isNotEmpty) dateStr,
                      if (hostName.isNotEmpty) hostName,
                      if (location.isNotEmpty) location,
                    ].join(' · '),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Nunito', fontSize: 11.5, color: _muted,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: _muted),
          ]),
        ),
      ),
    );
  }
}

/// Lightweight dashed-border wrapper used by the "+ Add Location"
/// tile. Built inline so we don't pull in another package just for
/// one decorative touch.
class DottedBorder extends StatelessWidget {
  final Widget child;
  final Color color;
  final double radius;
  const DottedBorder({super.key, required this.child, required this.color, this.radius = 12});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorderPainter(color: color, radius: radius),
      child: child,
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  final Color color;
  final double radius;
  _DashedBorderPainter({required this.color, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    final dashed = Path();
    const dashLen = 6.0;
    const gapLen = 4.0;
    for (final metric in path.computeMetrics()) {
      double offset = 0;
      while (offset < metric.length) {
        final next = (offset + dashLen).clamp(0.0, metric.length);
        dashed.addPath(metric.extractPath(offset, next), Offset.zero);
        offset = next + gapLen;
      }
    }
    canvas.drawPath(dashed, paint);
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}
