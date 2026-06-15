import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:gal/gal.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils.dart';
import '../widgets/rsvp_live_counts.dart';
import 'create_event_screen.dart';
import 'host_notifications_screen.dart';
import 'settings_screen.dart';
import 'guest_event_screen.dart';
import 'business_qr_screen.dart';
import 'organization_screen.dart';
import '../services/event_delete_helper.dart';

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
  String? _userName;

  // Linked Business orgs (Phase 4 fan-out). Populated by a `where
  // documentId in linkedBusinessOrgIds` listener that re-subscribes
  // whenever the HQ org doc's array changes. Used to render per-
  // location entries in [_locations] and to map event.hostId →
  // location id via [_uidToOrgId].
  StreamSubscription<QuerySnapshot>? _linkedOrgsSub;
  Map<String, Map<String, dynamic>> _linkedOrgs = {};

  // Reconciliation guards — track which uid/orgId set each subscription
  // is currently filtering on, so we don't tear down + re-listen on
  // unrelated org-doc updates (e.g. logo change).
  List<String> _eventsSubscribedFor = const [];
  List<String> _linkedOrgsSubscribedFor = const [];
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
    _linkedOrgsSub?.cancel();
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
    // User doc stream serves two purposes: a tier flip flushes us out
    // of this screen via HomeRouter without a manual reload, AND we
    // capture `name` here so the AppBar wordmark falls back to the
    // user's signup name (e.g. "PGMS PTA") when no org doc exists yet.
    _userSub = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() => _userName = snap.data()?['name'] as String?);
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
        final doc = snap.docs.first;
        setState(() { _orgId = doc.id; _org = doc.data(); });
      }
      // Re-evaluate both fan-out subscriptions whenever the HQ org doc
      // changes — the linked arrays may have grown (new accept) or
      // shrunk (future unlink). Idempotent when nothing material moved.
      _reconcileEventsSub();
      _reconcileLinkedOrgsSub();
    });
    // Initial events subscription before the org doc lands — covers
    // just the HQ owner's own events. Reconcile fires again when the
    // org doc arrives and may widen the query to include linked uids.
    _reconcileEventsSub();
  }

  // Same set of strings, ignoring order. Used to skip no-op
  // resubscribes when an unrelated org-doc field changes.
  bool _sameSet(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    return a.toSet().containsAll(b);
  }

  void _reconcileEventsSub() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final linkedUids = (_org?['linkedBusinessOwnerUids'] as List?)?.cast<String>() ?? const [];
    // HQ owner is always slot 0. Phase 1 caps linked uids at 29 so
    // allUids.length stays ≤ 30 — Firestore whereIn's hard limit.
    final allUids = [user.uid, ...linkedUids];
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
      debugPrint('[Headquarters] events stream error: $e');
    });
  }

  void _reconcileLinkedOrgsSub() {
    final orgIds = (_org?['linkedBusinessOrgIds'] as List?)?.cast<String>() ?? const [];
    if (_sameSet(orgIds, _linkedOrgsSubscribedFor)) return;
    _linkedOrgsSub?.cancel();
    _linkedOrgsSubscribedFor = orgIds;
    if (orgIds.isEmpty) {
      if (_linkedOrgs.isNotEmpty && mounted) {
        setState(() => _linkedOrgs = {});
      }
      return;
    }
    // documentId-based whereIn — same 30-value cap as the events query.
    _linkedOrgsSub = FirebaseFirestore.instance
        .collection('organizations')
        .where(FieldPath.documentId, whereIn: orgIds)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _linkedOrgs = {
          for (final d in snap.docs) d.id: Map<String, dynamic>.from(d.data() as Map),
        };
      });
    }, onError: (Object e) {
      debugPrint('[Headquarters] linked orgs stream error: $e');
    });
  }

  // ── Derived stats ─────────────────────────────────────────────
  /// Total locations under this Headquarters. The HQ itself counts as
  /// slot 0; linked Businesses populate the rest of the list once
  /// their org docs land.
  int get _totalLocations => _locations.length;

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
      // resolveEventEnd reads endDate/endTime when set, otherwise
      // falls back to end-of-day on the start date — same shared
      // logic as the personal and business feeds. The _events list
      // here is the raw Firestore data (see _eventsSub), so passing
      // `e` directly works.
      if (resolveEventEnd(e).isBefore(now)) continue;
      final yes   = (e['yes']   as num?)?.toInt() ?? 0;
      final maybe = (e['maybe'] as num?)?.toInt() ?? 0;
      final no    = (e['no']    as num?)?.toInt() ?? 0;
      if (yes + maybe + no == 0) return e;
    }
    return null;
  }

  String get _orgName {
    final n = (_org?['name'] as String?)?.trim();
    if (n != null && n.isNotEmpty) return n;
    final un = _userName?.trim();
    if (un != null && un.isNotEmpty) return un;
    return 'Your Organization';
  }

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
      // Mirror the _zeroRsvpUpcoming change above — route through
      // the shared resolveEventEnd so in-progress events stay in
      // the Hosted Events upcoming list until they finish, not
      // until they start.
      return !resolveEventEnd(e).isBefore(now);
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

  /// True when the current user can delete this event. Mirrors the
  /// firestore.rules: the host can always delete, and the org owner
  /// can delete events linked to their org. Linked-Business events
  /// shown on the HQ feed have `hostId == businessOwnerUid` and
  /// `orgId == businessOrgId`, neither of which match the HQ owner —
  /// so the affordance is hidden for those rows. The Business owner
  /// deletes their own events from BusinessHomeFeedScreen instead.
  bool _canDeleteEvent(Map<String, dynamic> event) {
    return EventDeleteHelper.canDelete(
      hostId:        event['hostId']  as String?,
      eventOrgId:    event['orgId']   as String?,
      myUid:         FirebaseAuth.instance.currentUser?.uid,
      myOwnedOrgId:  _orgId,
    );
  }

  /// Opens a popup menu near [position] with a single Delete entry.
  /// Used both by the long-press gesture (passes the touch position)
  /// and by the 3-dot icon button (passes its own widget rect's
  /// top-left). Early-returns when the user can't delete this event,
  /// so the menu never appears for linked-Business rows.
  Future<void> _openEventMenu(Map<String, dynamic> event, Offset position) async {
    if (!_canDeleteEvent(event)) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final eventTitle = (event['title'] as String?) ?? 'this event';
    final eventId = event['_id'] as String;
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
      // _eventsSub auto-rebuilds the feed; no manual refresh needed.
    }
  }

  /// Compact 3-dot icon button shown in the top-left of every card
  /// the user can delete. Hidden completely when the user can't —
  /// no inert affordance, no permission-denied 403s.
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

  /// Per-event card — same chrome as business_home_feed_screen.dart's
  /// `_buildUpcomingCard`: 16-radius `_card` background, emoji tile +
  /// title + date stack, optional location row, live RSVP totals via
  /// [RsvpLiveCounts] with a progress bar. Tap opens GuestEventScreen.
  /// Long-press (and the top-left 3-dot icon) opens the delete menu
  /// for events the current user can delete.
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

    return Stack(children: [
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => GuestEventScreen(
              eventId: eventId,
              eventData: Map<String, dynamic>.from(event),
            ),
          ),
        ),
        onLongPressStart: (d) => _openEventMenu(event, d.globalPosition),
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
            // Inline trash button — only on cards the current user can
            // actually delete. Linked-Business events shown on the HQ
            // feed have hostId == businessOwnerUid; _canDeleteEvent
            // returns false for them so the affordance stays hidden.
            // Routes through EventDeleteHelper.confirmAndDelete (same
            // hold-to-delete dialog + CF-cascade machinery as the
            // long-press and 3-dot menu paths).
            if (_canDeleteEvent(event)) ...[
              const SizedBox(height: 12),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                OutlinedButton(
                  onPressed: () => EventDeleteHelper.confirmAndDelete(
                    context,
                    eventId: eventId,
                    eventTitle: title,
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.redAccent),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                  ),
                  child: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 16),
                ),
              ]),
            ],
          ],
        ),
      ),
      ),
      Positioned(top: 4, left: 4, child: _buildOverflowMenuButton(event)),
    ]);
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
            _orgName,
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
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const OrganizationScreen())),
      child: Container(
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
            const SizedBox(height: 14),
            Row(children: [
              Text(
                _org == null ? 'Set up your organization' : 'Manage Organization',
                style: const TextStyle(
                  fontFamily: 'Nunito', fontSize: 12, fontWeight: FontWeight.w700,
                  color: Colors.white, letterSpacing: 0.3,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, size: 16, color: Colors.white),
            ]),
          ],
        ),
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
          onPressed: () => _showSendInviteSheet(),
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

  /// Modal bottom sheet for sending a link invite to a Business
  /// account. Single-stage form: email field + Send button. Error
  /// messages appear inline below the field; success closes the
  /// sheet and surfaces a snackbar on the host scaffold.
  ///
  /// All Firestore work is done in [_sendInvite] which throws a
  /// human-readable [String] for any validation failure (caught
  /// here and shown in the inline slot). The actual write target
  /// is `/organizations/{businessOrgId}/invites/{hqOrgId}` keyed by
  /// the sender's HQ orgId so re-sends overwrite a prior pending
  /// invite (idempotent — see Phase 1 schema decision).
  void _showSendInviteSheet() {
    if (_orgId == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Set up your Headquarters organization first.'),
        backgroundColor: Colors.redAccent,
      ));
      return;
    }
    showModalBottomSheet<String>(
      context: context,
      backgroundColor: _card,
      isScrollControlled: true, // keyboard pushes the sheet up cleanly
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _InviteSheet(onSubmit: _sendInvite),
    ).then((targetName) {
      // Sheet dismissed via Cancel / swipe → null. Successful send →
      // the sheet pops with the target org name. Snackbar fires on
      // the parent scaffold context, NOT the sheet's (the sheet is
      // already torn down). The mounted check guards against the
      // user backing out of the HQ screen mid-flight.
      if (targetName == null || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Invite sent to $targetName'),
        backgroundColor: AppColors.green,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        duration: const Duration(seconds: 4),
      ));
    });
  }

  /// Walks the 8-step validation pipeline from Phase 3 sub-item 2,
  /// then writes the invite doc. Returns the target Business org's
  /// display name for the success snackbar. Throws a human-readable
  /// `String` on any validation failure (caller shows it inline).
  ///
  /// Email lookup assumes user docs store email lowercased — verified
  /// against welcome_screen.dart's signup writer. Trims + lowercases
  /// the input before querying.
  Future<String> _sendInvite(String rawEmail) async {
    final email = rawEmail.trim().toLowerCase();
    final emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
    if (email.isEmpty || !emailRegex.hasMatch(email)) {
      throw 'Enter a valid email address.';
    }

    final myUid = FirebaseAuth.instance.currentUser?.uid;
    final myEmail = FirebaseAuth.instance.currentUser?.email?.trim().toLowerCase();
    final hqOrgId = _orgId;
    if (myUid == null || hqOrgId == null) {
      throw 'Set up your Headquarters organization first.';
    }
    if (myEmail != null && myEmail == email) {
      throw "That's your own email — you can't invite yourself.";
    }

    // Step 4 — locate the target user by email.
    final userQuery = await FirebaseFirestore.instance
        .collection('users')
        .where('email', isEqualTo: email)
        .limit(1)
        .get();
    if (userQuery.docs.isEmpty) {
      throw 'No Business account found for this email.';
    }
    final targetUserDoc = userQuery.docs.first;
    final targetUid = targetUserDoc.id;
    final targetAcct = targetUserDoc.data()['accountType'] as String?;

    // Step 5 — verify accountType is exactly 'business' (not 'businessPlus'
    // or 'personal'). HQ-under-HQ links aren't supported.
    if (targetAcct != 'business') {
      throw 'That account is not on the Business tier.';
    }

    // Step 6 — find their Business org doc.
    final orgQuery = await FirebaseFirestore.instance
        .collection('organizations')
        .where('ownerId', isEqualTo: targetUid)
        .limit(1)
        .get();
    if (orgQuery.docs.isEmpty) {
      throw "That account doesn't have an organization set up yet — ask them to create one first.";
    }
    final targetOrgDoc = orgQuery.docs.first;
    final targetOrgId = targetOrgDoc.id;
    final targetOrgData = targetOrgDoc.data();
    final targetOrgName = (targetOrgData['name'] as String?)?.trim().isNotEmpty == true
        ? targetOrgData['name'] as String
        : 'Business';

    // Step 7 — pre-existing-link check. Distinguish "already linked to
    // YOU" (idempotent / friendly) from "linked to someone else".
    final existingParent = targetOrgData['parentOrgId'] as String?;
    if (existingParent == hqOrgId) {
      throw 'That Business is already linked to your Headquarters.';
    }
    if (existingParent != null && existingParent.isNotEmpty) {
      throw 'That Business is already linked to a different Headquarters.';
    }

    // Step 8 — write the invite. set() (not add()) so re-sends
    // overwrite a prior pending invite from the same HQ.
    await FirebaseFirestore.instance
        .collection('organizations').doc(targetOrgId)
        .collection('invites').doc(hqOrgId)
        .set({
      'hqOrgId':    hqOrgId,
      'hqOwnerUid': myUid,
      'hqOrgName':  _orgName,
      'status':     'pending',
      'sentAt':     FieldValue.serverTimestamp(),
      'sentByUid':  myUid,
    });

    return targetOrgName;
  }

  /// Per-linked-Business row list. Each row is a name + QR chip + view
  /// chip. Loading state shows a shimmer; empty state shows a muted
  /// "no linked locations" message pointing at the header Add button.
  Widget _buildLocationsList() {
    if (_org == null) return _buildLocationsShimmer();
    final orgIds = (_org?['linkedBusinessOrgIds'] as List?)?.cast<String>() ?? const [];
    final cards = <Widget>[];
    for (final id in orgIds) {
      final data = _linkedOrgs[id];
      if (data == null) continue; // doc not yet loaded — skip until it lands
      if (cards.isNotEmpty) cards.add(const SizedBox(height: 8));
      cards.add(_buildLinkedBusinessRow(id, data));
    }
    if (cards.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _border),
        ),
        child: Center(
          child: Text(
            'No linked locations yet — tap Add Location to invite a Business',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Nunito', fontSize: 13, color: _muted, height: 1.4,
            ),
          ),
        ),
      );
    }
    return Column(children: cards);
  }

  Widget _buildLinkedBusinessRow(String orgId, Map<String, dynamic> data) {
    final raw = (data['name'] as String?)?.trim() ?? '';
    final name = raw.isNotEmpty ? raw : 'Linked location';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Row(children: [
        Expanded(
          child: Text(
            name,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Nunito', fontSize: 15, fontWeight: FontWeight.w800, color: _fg,
            ),
          ),
        ),
        const SizedBox(width: 10),
        _locationActionChip(
          bg: _purple,
          icon: Icons.qr_code_2,
          onTap: () => _showLinkedQrDialog(orgId, name),
        ),
        const SizedBox(width: 8),
        _locationActionChip(
          bg: _gold,
          icon: Icons.visibility_outlined,
          onTap: () => _openLinkedUrl(orgId),
        ),
      ]),
    );
  }

  Widget _locationActionChip({required Color bg, required IconData icon, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 38, height: 38,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          boxShadow: [BoxShadow(color: bg.withValues(alpha: 0.30), blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }

  Future<void> _openLinkedUrl(String orgId) async {
    final url = Uri.parse(orgPageUrl(orgId));
    try {
      final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not open the link.'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Open failed: $e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  // Fullscreen QR modal — mirrors the OrganizationScreen QR card
  // styling (purple-bordered white plate + brand label inside) and
  // adds a Download CTA that captures the RepaintBoundary and saves
  // via Gal. The GlobalKey is captured by the StatefulBuilder
  // closure; busy state lives on the closure too so we can disable
  // the button mid-save.
  Future<void> _showLinkedQrDialog(String orgId, String name) async {
    final qrKey = GlobalKey();
    final url = orgPageUrl(orgId);
    bool busy = false;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => Dialog(
          backgroundColor: _card,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 22),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.close, color: _muted),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ]),
              RepaintBoundary(
                key: qrKey,
                child: Container(
                  width: 240, height: 240,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: _purple, width: 3),
                    boxShadow: [BoxShadow(color: _purple.withValues(alpha: 0.18), blurRadius: 36, spreadRadius: 4)],
                  ),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    QrImageView(
                      data: url,
                      version: QrVersions.auto,
                      size: 184,
                      backgroundColor: Colors.white,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        name,
                        textAlign: TextAlign.center,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: _mutedLight, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                name,
                textAlign: TextAlign.center,
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: 'FredokaOne', fontSize: 18, color: _fg),
              ),
              const SizedBox(height: 4),
              Text(
                url,
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'Nunito', fontSize: 11.5, color: _muted),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: busy ? null : () async {
                    setLocal(() => busy = true);
                    try {
                      final boundary = qrKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
                      if (boundary == null) throw Exception('Could not capture QR');
                      final image = await boundary.toImage(pixelRatio: 3.0);
                      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
                      final bytes = byteData?.buffer.asUint8List();
                      if (bytes == null) throw Exception('Could not capture QR');
                      final hasAccess = await Gal.hasAccess();
                      if (!hasAccess) {
                        final granted = await Gal.requestAccess();
                        if (!granted) throw Exception('Gallery access denied');
                      }
                      final safeName = name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_').toLowerCase();
                      await Gal.putImageBytes(bytes, name: 'qrparty_org_$safeName');
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('📸 QR saved to your photos'),
                          backgroundColor: AppColors.green,
                          behavior: SnackBarBehavior.floating,
                        ));
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('Save failed: $e'),
                          backgroundColor: Colors.redAccent,
                          behavior: SnackBarBehavior.floating,
                        ));
                      }
                    } finally {
                      if (ctx.mounted) setLocal(() => busy = false);
                    }
                  },
                  icon: busy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.download_outlined, size: 18),
                  label: const Text('Download', style: TextStyle(fontWeight: FontWeight.w700)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold, foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ]),
          ),
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
        // Business QR Code — primary action. Provisions a permanent
        // org-level QR on first tap and opens the dedicated screen
        // with download/share options.
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
        const SizedBox(height: 10),
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
      ],
    );
  }

  // ── Locations model ───────────────────────────────────────────
  /// Logical locations under this Headquarters. Slot 0 is always the
  /// HQ itself; subsequent entries are the linked Business orgs in the
  /// order they appear in `linkedBusinessOrgIds`. Each gets a distinct
  /// palette accent (wraps when more than [_locationPalette.length]).
  List<({String id, String name, Color accent})> get _locations {
    final list = <({String id, String name, Color accent})>[
      (
        id: _orgId ?? 'primary',
        name: _orgName,
        accent: _locationPalette[0],
      ),
    ];
    final orgIds = (_org?['linkedBusinessOrgIds'] as List?)?.cast<String>() ?? const [];
    for (var i = 0; i < orgIds.length; i++) {
      final id = orgIds[i];
      final data = _linkedOrgs[id];
      if (data == null) continue; // doc not loaded yet — skip until it lands
      final raw = (data['name'] as String?)?.trim() ?? '';
      final name = raw.isNotEmpty ? raw : 'Linked location';
      list.add((
        id: id,
        name: name,
        accent: _locationPalette[(i + 1) % _locationPalette.length],
      ));
    }
    return list;
  }

  /// uid → location id (= orgId). Built fresh on each call from the
  /// HQ owner + each loaded linked-org's `ownerId`. Used to slot an
  /// event into its location for analytics/calendar tabs.
  Map<String, String> get _uidToOrgId {
    final m = <String, String>{};
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid != null && _orgId != null) m[myUid] = _orgId!;
    for (final entry in _linkedOrgs.entries) {
      final ownerId = entry.value['ownerId'] as String?;
      if (ownerId != null && ownerId.isNotEmpty) m[ownerId] = entry.key;
    }
    return m;
  }

  /// Maps an event to its location id by looking up the host's uid in
  /// [_uidToOrgId]. Falls back to the HQ's own orgId if the event's
  /// hostId isn't recognized (defensive — shouldn't happen since the
  /// events query already restricts to known uids).
  String _eventLocationId(Map<String, dynamic> e) {
    final hostId = e['hostId'] as String?;
    if (hostId == null) return _orgId ?? 'primary';
    return _uidToOrgId[hostId] ?? _orgId ?? 'primary';
  }

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

// ─── INVITE SHEET ────────────────────────────────────────────
// Bottom-sheet body for sending a Headquarters→Business link invite.
// Lives as a StatefulWidget (rather than an inline StatefulBuilder
// inside the parent's _showSendInviteSheet) so the controllers it
// owns get disposed at the correct lifecycle point — State.dispose()
// fires AFTER every dependent (TextField, FocusScope) has
// unregistered, satisfying the framework's `_dependents.isEmpty`
// invariant. The earlier whenComplete-based disposal ran while the
// sheet's widget tree was mid-teardown and tripped that assertion.
//
// Pattern matches share_to_wishlist_sheet.dart's _SheetBody —
// canonical for any modal sheet that owns disposable resources.
//
// All validation + Firestore writes happen in [onSubmit] (the parent's
// _sendInvite method), which throws a human-readable String on any
// validation failure. This sheet is purely presentation + state for
// the form; it doesn't know anything about org/invite schema.
class _InviteSheet extends StatefulWidget {
  /// Runs the validation pipeline and writes the invite. Returns
  /// the target Business org's display name on success (used by the
  /// parent's success snackbar). Throws a `String` (caught here and
  /// shown in the inline error slot) on any validation failure.
  final Future<String> Function(String email) onSubmit;

  const _InviteSheet({required this.onSubmit});

  @override
  State<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends State<_InviteSheet> {
  final TextEditingController _emailCtrl = TextEditingController();
  final FocusNode _emailFocus = FocusNode();
  String? _error;
  bool _sending = false;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _emailFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final targetName = await widget.onSubmit(_emailCtrl.text);
      if (!mounted) return;
      // Pop with the target name as the route result. The parent's
      // .then() on showModalBottomSheet receives this and shows the
      // success snackbar from the parent's scaffold context.
      Navigator.of(context).pop(targetName);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = e is String ? e : "Couldn't send invite — please try again.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Re-derive theme-aware colors locally — the parent's `_card` /
    // `_bg` / etc. are instance getters on its State and aren't
    // reachable from here. Mirrors the parent's pattern using the
    // same file-level constants (_bgDark, _cardLight, etc.).
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg     = isDark ? _bgDark     : _bgLight;
    final border = isDark ? _borderDark : _borderLight;
    final muted  = isDark ? _mutedDark  : _mutedLight;
    final fg     = isDark ? Colors.white : AppColors.dark;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          24, 12, 24,
          24 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(color: border, borderRadius: BorderRadius.circular(2)),
            )),
            const SizedBox(height: 18),
            Text(
              'Invite a Business location',
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: 'FredokaOne', fontSize: 22, color: fg),
            ),
            const SizedBox(height: 8),
            Text(
              "Enter the Business account's email — we'll send them an invite to link under your Headquarters.",
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: 'Nunito', fontSize: 14, color: muted, height: 1.5),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _emailCtrl,
              focusNode: _emailFocus,
              autofocus: true,
              enabled: !_sending,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.send,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _submit(),
              style: TextStyle(fontFamily: 'Nunito', fontSize: 15, color: fg),
              decoration: InputDecoration(
                hintText: 'business@example.com',
                hintStyle: TextStyle(color: muted),
                filled: true,
                fillColor: bg,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: border)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: border)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _purple, width: 1.5)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              ),
            ),
            // Inline error slot. Reserves no vertical space when
            // empty so the layout doesn't jump on first error.
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(
                  fontFamily: 'Nunito', fontSize: 12.5,
                  color: Colors.redAccent, fontWeight: FontWeight.w700,
                ),
              ),
            ],
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: TextButton(
                  onPressed: _sending ? null : () => Navigator.pop(context),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text(
                    'Cancel',
                    style: TextStyle(fontFamily: 'Nunito', fontSize: 15, fontWeight: FontWeight.w800, color: muted),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: _sending ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _purple,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: _purple.withValues(alpha: 0.4),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                  child: _sending
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text(
                          'Send Invite',
                          style: TextStyle(fontFamily: 'Nunito', fontSize: 15, fontWeight: FontWeight.w800),
                        ),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
