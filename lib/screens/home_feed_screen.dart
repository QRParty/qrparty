import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../utils.dart';
import '../widgets/rsvp_live_counts.dart';
import 'create_event_screen.dart';
import 'guest_event_screen.dart';
import 'settings_screen.dart';
import 'qr_scanner_screen.dart';
import 'analytics_screen.dart';
import 'picture_wall_screen.dart';
import 'edit_event_screen.dart';
import 'thank_you_screen.dart';
import 'generate_qr_screen.dart';
import 'host_notifications_screen.dart';

class HomeFeedScreen extends StatefulWidget {
  const HomeFeedScreen({super.key});
  @override
  State<HomeFeedScreen> createState() => _HomeFeedScreenState();
}

class _HomeFeedScreenState extends State<HomeFeedScreen> {
  int selectedTab = 0;
  String selectedFilter = 'All';

  List<Map<String, dynamic>> _events = [];
  bool _loading = true;
  StreamSubscription<QuerySnapshot>? _eventsSub;

  bool _selectMode = false;
  Set<String> _selectedIds = {};

  List<Map<String, dynamic>> _publicEvents = [];
  bool _exploreLoading = true;
  StreamSubscription<QuerySnapshot>? _publicEventsSub;
  String _exploreSearch = '';
  final TextEditingController _exploreSearchController = TextEditingController();

  // Events the current user has RSVP'd to as a guest, regardless of
  // status (Yes/Maybe/No). Driven by a collectionGroup('rsvps') stream
  // on uid==me; the parent event docs are fetched lazily when the
  // stream fires. _attendingLoaded flips true after the first snapshot
  // arrives so we can distinguish "still loading" from "no invites".
  List<Map<String, dynamic>> _attendingEvents = [];
  bool _attendingLoaded = false;
  StreamSubscription<QuerySnapshot>? _attendingSub;

  @override
  void initState() {
    super.initState();
    print('[HomeFeed] initState — calling _subscribeToPublicEvents()');
    _subscribeToEvents();
    _subscribeToPublicEvents();
    _subscribeToAttendingEvents();
    // FCM token registration moved to main.dart's auth listener so
    // deep-link-only users (who never visit this screen) also register.
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    _publicEventsSub?.cancel();
    _attendingSub?.cancel();
    _exploreSearchController.dispose();
    super.dispose();
  }

  /// Listens to RSVP docs across every event subcollection where the
  /// current user is `uid` (any status). Each matching RSVP is joined
  /// back to its parent event doc so the guest sees every event they've
  /// been invited to — not just the ones they accepted — and can change
  /// their answer later.
  ///
  /// Notes:
  ///   • Status field is PascalCase ('Yes'/'Maybe'/'No') in Firestore,
  ///     set by guest_event_screen.dart's _saveRsvp. The per-card pill
  ///     reads this to render "Attending" (Yes) vs "Invited to" (else).
  ///   • Events the user hosts themselves are filtered out so a host
  ///     who RSVP'd to their own event doesn't double up in both
  ///     sections.
  ///   • Past / archived / draft events are filtered client-side.
  ///   • collectionGroup query on a single field (uid) — Firestore
  ///     auto-creates this index, no console-link error on first run.
  void _subscribeToAttendingEvents() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => _attendingLoaded = true);
      return;
    }
    debugPrint('[HomeFeed] subscribing to attending RSVPs for uid=${user.uid}');
    _attendingSub = FirebaseFirestore.instance
        .collectionGroup('rsvps')
        .where('uid', isEqualTo: user.uid)
        .snapshots()
        .listen((snap) async {
      if (!mounted) return;
      debugPrint('[HomeFeed] attending stream — ${snap.docs.length} RSVP(s)');
      // Each rsvp doc lives at events/{eventId}/rsvps/{uid}. Walk up
      // to the parent event doc id, capturing the RSVP status so the
      // per-card pill can render Attending vs Invited to. Skip
      // self-hosted events to avoid the duplicate hosting/attending
      // card. Skip docs without a status field (legacy data).
      final statusByEventId = <String, String>{};
      for (final rsvpDoc in snap.docs) {
        final parent = rsvpDoc.reference.parent.parent;
        if (parent == null) continue;
        final status = (rsvpDoc.data() as Map<String, dynamic>?)?['status'] as String?;
        if (status == null || status.isEmpty) continue;
        statusByEventId[parent.id] = status;
      }
      final eventIds = statusByEventId.keys.toList();
      if (eventIds.isEmpty) {
        setState(() {
          _attendingEvents = [];
          _attendingLoaded = true;
        });
        return;
      }
      try {
        final eventDocs = await Future.wait(eventIds.map(
          (id) => FirebaseFirestore.instance.collection('events').doc(id).get(),
        ));
        if (!mounted) return;
        final now = DateTime.now();
        final results = <Map<String, dynamic>>[];
        for (final eventSnap in eventDocs) {
          if (!eventSnap.exists) continue;
          final data = eventSnap.data() as Map<String, dynamic>;
          if (data['hostId'] == user.uid) continue;
          if ((data['isDraft']    as bool?) ?? false) continue;
          if ((data['isArchived'] as bool?) ?? false) continue;
          final ts = data['date'] as Timestamp?;
          final calendarDate = ts?.toDate();
          final eventStart = _resolveEventStart(calendarDate, data['time'] as String?);
          if (eventStart.isBefore(now)) continue;
          final typeName = (data['eventType'] as String?) ?? '';
          final matchedType = eventTypes.firstWhere(
            (t) => t.name == typeName,
            orElse: () => eventTypes.last,
          );
          results.add({
            'id': eventSnap.id,
            'title': (data['title'] as String?) ?? 'Untitled',
            'date': calendarDate ?? DateTime(2099),
            'eventStart': eventStart,
            'host': (data['hostName'] as String?) ?? 'Host',
            'emoji': (data['eventEmoji'] as String?) ?? '🎉',
            'color': matchedType.primary,
            'rsvpStatus': statusByEventId[eventSnap.id] ?? 'Yes',
            'rawData': data,
          });
        }
        results.sort((a, b) =>
            (a['eventStart'] as DateTime).compareTo(b['eventStart'] as DateTime));
        setState(() {
          _attendingEvents = results;
          _attendingLoaded = true;
        });
      } catch (e) {
        debugPrint('[HomeFeed] attending event-doc fetch failed: $e');
        if (mounted) setState(() => _attendingLoaded = true);
      }
    }, onError: (Object e) {
      debugPrint('[HomeFeed] attending stream ERROR: $e');
      if (mounted) setState(() => _attendingLoaded = true);
    });
  }

  void _subscribeToEvents() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => _loading = false);
      return;
    }
    debugPrint('[HomeFeed] subscribing to events for uid=${user.uid}');
    // No .orderBy('date') here — Firestore would silently drop any draft
    // doc that hasn't had a date field stamped on it yet (which used to
    // hide drafts from this feed for ~600ms after creation, sometimes
    // permanently if the host quit before the auto-save debounce fired).
    // Sorted client-side below where DateTime(2099) is used as the
    // sentinel for missing/null dates.
    _eventsSub = FirebaseFirestore.instance
        .collection('events')
        .where('hostId', isEqualTo: user.uid)
        .snapshots()
        .listen((snap) {
      debugPrint('[HomeFeed] stream received ${snap.docs.length} event(s) for hostId=${user.uid}');
      final now = DateTime.now();
      setState(() {
        _loading = false;
        // No accountType filter here. The query is already scoped by
        // hostId == user.uid so this is exclusively the user's own
        // events; dropping any of them based on accountType caused
        // trialing business users (whom HomeRouter pins to this feed)
        // to see a blank list because their newly-created events were
        // stamped 'business'/'businessPlus' and silently filtered out.
        _events = snap.docs.map((doc) {
          final data = doc.data() as Map<String, dynamic>;
          final ts = data['date'] as Timestamp?;
          final calendarDate = ts?.toDate();
          // Combine `date` (midnight Timestamp) with `time` ("HH:MM"
          // string) into the actual event-start DateTime. Without
          // this, an event picked for TODAY had date=00:00 and was
          // classified as `past` the moment it was created (because
          // now > 00:00) — silently disappearing from Upcoming. If no
          // time was set, end-of-day is used so today's events stay
          // in Upcoming until midnight passes.
          final eventStart = _resolveEventStart(calendarDate, data['time'] as String?);
          // Sortable date keeps the prior contract: drafts and
          // date-less events sort last via the DateTime(2099) sentinel.
          final sortDate = calendarDate ?? DateTime(2099);
          final isDraft = (data['isDraft'] as bool?) ?? false;
          final isPast = !isDraft && eventStart.isBefore(now);
          debugPrint('[HomeFeed]   doc=${doc.id} title="${data['title']}" date=$calendarDate time=${data['time']} eventStart=$eventStart isPast=$isPast isDraft=$isDraft accountType=${data['accountType']}');
          final typeName = (data['eventType'] as String?) ?? '';
          final matchedType = eventTypes.firstWhere((t) => t.name == typeName, orElse: () => eventTypes.last);
          return {
            'id': doc.id,
            'title': (data['title'] as String?) ?? 'Untitled',
            'date': sortDate,
            'eventStart': eventStart,
            'host': (data['hostName'] as String?) ?? 'You',
            'isPast': isPast,
            'yes': (data['yes'] as num?)?.toInt() ?? 0,
            'maybe': (data['maybe'] as num?)?.toInt() ?? 0,
            'no': (data['no'] as num?)?.toInt() ?? 0,
            'type': typeName,
            'emoji': (data['eventEmoji'] as String?) ?? '🎉',
            'color': matchedType.primary,
            'isDraft': isDraft,
            'isPublic': (data['isPublic'] as bool?) ?? false,
            'isArchived': (data['isArchived'] as bool?) ?? false,
            'rawData': data,
          };
        }).toList()..sort((a, b) {
          return (a['date'] as DateTime).compareTo(b['date'] as DateTime);
        });
      });
      _autoArchivePastEvents();
    }, onError: (Object e) {
      debugPrint('[HomeFeed] stream ERROR: $e');
      if (mounted) setState(() => _loading = false);
    });
  }

  /// Combines the `date` Timestamp (midnight on the picked calendar
  /// date) with the `time` string ("HH:MM") into a single DateTime
  /// representing the actual event start. Used by the upcoming/past
  /// classifier so an event scheduled for today doesn't get treated
  /// as already-past at 00:00:01.
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

  void _subscribeToPublicEvents() {
    print('[Explore] *** starting public events subscription ***');
    // Diagnostic: fetch first 5 events regardless of isPublic to see raw field values
    FirebaseFirestore.instance.collection('events').limit(5).get().then((snap) {
      print('[Explore] diagnostic — ${snap.docs.length} total event(s) in collection (unfiltered):');
      for (final doc in snap.docs) {
        final d = doc.data();
        print('[Explore]   ${doc.id}: isPublic=${d['isPublic']} isDraft=${d['isDraft']} isArchived=${d['isArchived']} title="${d['title']}"');
      }
    });
    // Only filter by isPublic in Firestore — isArchived and isDraft are handled
    // client-side because older docs may not have those fields, and Firestore
    // excludes documents where a field is missing when using isEqualTo: false.
    _publicEventsSub = FirebaseFirestore.instance
        .collection('events')
        .where('isPublic', isEqualTo: true)
        .orderBy('date')
        .snapshots()
        .listen((snap) {
      print('[Explore] *** received ${snap.docs.length} public events (before client filter) ***');

      if (!mounted) return;
      final now = DateTime.now();

      setState(() {
        _exploreLoading = false;
        _publicEvents = snap.docs.map((doc) {
          final data = doc.data() as Map<String, dynamic>;
          final ts = data['date'] as Timestamp?;
          final date = ts?.toDate() ?? DateTime(2099);
          final typeName = (data['eventType'] as String?) ?? '';
          final matchedType = eventTypes.firstWhere((t) => t.name == typeName, orElse: () => eventTypes.last);
          return {
            'id': doc.id,
            'title': (data['title'] as String?) ?? 'Untitled',
            'date': date,
            'host': (data['hostName'] as String?) ?? 'Unknown',
            'location': (data['location'] as String?) ?? '',
            'emoji': (data['eventEmoji'] as String?) ?? '🎉',
            'color': matchedType.primary,
            'yes': (data['yes'] as num?)?.toInt() ?? 0,
            'maybe': (data['maybe'] as num?)?.toInt() ?? 0,
            'no': (data['no'] as num?)?.toInt() ?? 0,
            'rawData': data,
          };
        }).where((e) {
          final data = e['rawData'] as Map<String, dynamic>;
          final isArchived = (data['isArchived'] as bool?) ?? false;
          final isDraft = (data['isDraft'] as bool?) ?? false;
          // Combine date + time so today's events stay visible until
          // their actual start time (not midnight). Same fix as the
          // host's own-events stream above.
          final calendarDate = (data['date'] as Timestamp?)?.toDate();
          final eventStart = _resolveEventStart(calendarDate, data['time'] as String?);
          return !isArchived && !isDraft && !eventStart.isBefore(now);
        }).toList();

        print('[Explore] *** ${_publicEvents.length} event(s) after client-side filter ***');
      });
    }, onError: (Object e) {
      print('[Explore] stream ERROR: $e');
      if (mounted) setState(() => _exploreLoading = false);
    });
  }

  List<Map<String, dynamic>> get _filteredPublicEvents {
    if (_exploreSearch.isEmpty) return _publicEvents;
    final q = _exploreSearch.toLowerCase();
    return _publicEvents.where((e) {
      return (e['title'] as String).toLowerCase().contains(q) ||
          (e['location'] as String).toLowerCase().contains(q);
    }).toList();
  }

  // Upcoming/past classification reads the precomputed `isPast` field,
  // which compares against `eventStart` (date+time combined) instead
  // of `date` (midnight). Without this, an event scheduled for today
  // gets classified as "past" the moment it's created.
  int get _pastCount => _events.where((e) => !(e['isDraft'] as bool) && (e['isPast'] as bool)).length;

  List<Map<String, dynamic>> get _drafts => _events.where((e) => e['isDraft'] as bool).toList();

  List<Map<String, dynamic>> get filteredEvents {
    if (selectedTab == 0) return _events.where((e) => !(e['isDraft'] as bool) && !(e['isPast'] as bool)).toList();
    if (selectedTab == 1) return _events.where((e) => !(e['isDraft'] as bool) &&  (e['isPast'] as bool)).toList();
    return _events;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chromeColor = isDark ? const Color(0xFF383B56) : Colors.white;
    final brandColor  = isDark ? Colors.white : AppColors.dark;
    // Theme-aware default for AppBar icons that don't carry their own
    // semantic color (notifications, settings). The previous hardcoded
    // AppColors.dark made them invisible against the dark chrome bar
    // — both icon and chrome are nearly the same navy.
    final iconColor = isDark ? Colors.white : AppColors.dark;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: chromeColor,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: RichText(
          text: TextSpan(
            children: [
              TextSpan(text: 'QR', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: brandColor)),
              const TextSpan(text: 'Party', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w300, color: AppColors.purple)),
            ],
          ),
        ),
        actions: [
          // TEMP: Admin access - remove before launch
          IconButton(
            icon: const Icon(Icons.admin_panel_settings_outlined, color: Colors.redAccent),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AnalyticsScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.qr_code_scanner, color: AppColors.green),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const QRScannerScreen())),
          ),
          IconButton(
            icon: Icon(Icons.storage_outlined, color: _pastCount >= 19 ? Colors.redAccent : _pastCount >= 15 ? AppColors.gold : AppColors.green),
            onPressed: () => _showStorageBottomSheet(_pastCount),
          ),
          IconButton(
            icon: Icon(Icons.notifications_outlined, color: iconColor),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HostNotificationsScreen())),
          ),
          IconButton(
            icon: Icon(Icons.settings_outlined, color: iconColor),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Container(
            color: chromeColor,
            child: Row(children: [
              _buildTab(0, 'Upcoming'),
              _buildPastTab(),
              _buildTab(2, 'Explore'),
            ]),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: selectedTab == 2
                ? _buildExploreTab()
                : _loading
                    ? const Center(child: CircularProgressIndicator(color: AppColors.green))
                    : Column(
                        children: [
                          if (selectedTab == 1)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('Past Events', style: TextStyle(fontSize: 13, color: AppColors.muted, fontWeight: FontWeight.w500)),
                                  GestureDetector(
                                    onTap: () => setState(() {
                                      _selectMode = !_selectMode;
                                      if (!_selectMode) _selectedIds.clear();
                                    }),
                                    child: Text(
                                      _selectMode ? 'Cancel' : 'Select',
                                      style: const TextStyle(fontSize: 13, color: AppColors.green, fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          Expanded(
                            child: Builder(builder: (_) {
                              // Upcoming tab section order: Attending (events
                              // I'm a guest at) → Upcoming (events I host) →
                              // Drafts. Empty-state only fires when ALL three
                              // lists are empty — otherwise the sections that
                              // DO have content render normally.
                              if (selectedTab == 0) {
                                final drafts = _drafts;
                                final attending = _attendingEvents;
                                if (drafts.isEmpty
                                    && filteredEvents.isEmpty
                                    && attending.isEmpty) return _buildEmptyState();
                                return ListView(
                                  padding: EdgeInsets.fromLTRB(16, 8, 16, _selectMode ? 100 : 80),
                                  children: [
                                    if (attending.isNotEmpty) ...[
                                      _attendingSectionHeader(attending.length),
                                      ...attending.map((a) => _buildAttendingCard(context, a)),
                                      const SizedBox(height: 8),
                                    ],
                                    // Show the UPCOMING header only when
                                    // there's an Attending list above it —
                                    // otherwise the hosted-events list IS
                                    // the page and a header is redundant.
                                    if (filteredEvents.isNotEmpty && attending.isNotEmpty)
                                      _upcomingSectionHeader(filteredEvents.length),
                                    ...filteredEvents.map((e) => _buildEventCard(context, e)),
                                    if (filteredEvents.isNotEmpty && drafts.isNotEmpty)
                                      const SizedBox(height: 8),
                                    if (drafts.isNotEmpty) ...[
                                      _draftsSectionHeader(drafts.length),
                                      ...drafts.map((d) => _buildEventCard(context, d)),
                                    ],
                                  ],
                                );
                              }
                              // Past tab — unchanged behaviour.
                              if (filteredEvents.isEmpty) return _buildEmptyState();
                              return ListView.builder(
                                padding: EdgeInsets.fromLTRB(16, 8, 16, _selectMode ? 100 : 80),
                                itemCount: filteredEvents.length,
                                itemBuilder: (context, index) => _buildEventCard(context, filteredEvents[index]),
                              );
                            }),
                          ),
                          if (_selectMode && selectedTab == 1)
                            Container(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 8, offset: const Offset(0, -2))],
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: ElevatedButton(
                                      onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.redAccent,
                                        foregroundColor: Colors.white,
                                        disabledBackgroundColor: Colors.grey.shade200,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                        padding: const EdgeInsets.symmetric(vertical: 13),
                                      ),
                                      child: Text(
                                        _selectedIds.isEmpty
                                            ? 'Delete Selected'
                                            : 'Delete ${_selectedIds.length} Event${_selectedIds.length == 1 ? '' : 's'}',
                                        style: const TextStyle(fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  OutlinedButton(
                                    onPressed: _exitSelectMode,
                                    style: OutlinedButton.styleFrom(
                                      side: BorderSide(color: AppColors.muted.withValues(alpha: 0.5)),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 20),
                                    ),
                                    child: const Text('Cancel', style: TextStyle(color: AppColors.dark)),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
          ),
        ],
      ),
      floatingActionButton: selectedTab != 2
          ? FloatingActionButton.extended(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateEventScreen())),
              backgroundColor: AppColors.green,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: const Text('New Event', style: TextStyle(fontWeight: FontWeight.w600)),
            )
          : null,
      bottomNavigationBar: debugLabel('Screen 2 — Host View'),
    );
  }

  Widget _buildExploreTab() {
    print('[Explore] *** _buildExploreTab called — _exploreLoading=$_exploreLoading _publicEvents=${_publicEvents.length}');
    final events = _filteredPublicEvents;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: TextField(
            controller: _exploreSearchController,
            onChanged: (v) => setState(() => _exploreSearch = v),
            decoration: InputDecoration(
              hintText: 'Search events by name or location...',
              hintStyle: const TextStyle(color: AppColors.muted, fontSize: 14),
              prefixIcon: const Icon(Icons.search, color: AppColors.muted, size: 20),
              suffixIcon: _exploreSearch.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close, color: AppColors.muted, size: 18),
                      onPressed: () { _exploreSearchController.clear(); setState(() => _exploreSearch = ''); },
                    )
                  : null,
              filled: true,
              fillColor: const Color(0xFFF4F6F4),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
            ),
          ),
        ),
        if (!_exploreLoading)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
            child: Text(
              events.isEmpty ? 'No public events found' : '${events.length} public event${events.length == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 13, color: AppColors.muted),
            ),
          ),
        Expanded(
          child: _exploreLoading
              ? const Center(child: CircularProgressIndicator(color: AppColors.green))
              : events.isEmpty
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Text('🌐', style: TextStyle(fontSize: 48)),
                        const SizedBox(height: 12),
                        Text(
                          _exploreSearch.isNotEmpty ? 'No events match "$_exploreSearch"' : 'No public events yet',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.dark),
                        ),
                        const SizedBox(height: 6),
                        const Text('Public events created by hosts will appear here', style: TextStyle(fontSize: 13, color: AppColors.muted)),
                      ]),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
                      itemCount: events.length,
                      itemBuilder: (context, index) => _buildExploreCard(context, events[index]),
                    ),
        ),
      ],
    );
  }

  Widget _buildExploreCard(BuildContext context, Map<String, dynamic> event) {
    final Color rawColor = event['color'] as Color;
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    // Mirror _buildEventCard's dark-mode treatment so Explore cards
    // for events whose type primary is dark (Corporate, Holiday, etc.)
    // stay readable on the dark surface.
    final Color color = onDarkSurface(rawColor, isDark: isDark);
    final Color cardBg = isDark ? const Color(0xFF383B56) : Colors.white;
    final Color cardBorder = isDark
        ? const Color(0xFF4A4E6B)
        : Colors.black.withValues(alpha: 0.05);
    final Color titleColor = isDark ? Colors.white : AppColors.dark;
    final DateTime date = event['date'] as DateTime;
    final location = event['location'] as String;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final yes = event['yes'] as int;
    final maybe = event['maybe'] as int;

    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(
        builder: (_) => GuestEventScreen(
          eventId: event['id'] as String,
          eventData: event['rawData'] as Map<String, dynamic>,
        ),
      )),
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: cardBorder),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                decoration: BoxDecoration(color: color.withValues(alpha: isDark ? 0.18 : 0.1), borderRadius: BorderRadius.circular(12)),
                child: Column(children: [
                  Text(months[date.month - 1].toUpperCase(), style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: color)),
                  Text('${date.day}', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: color)),
                ]),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(event['emoji'] as String, style: const TextStyle(fontSize: 15)),
                    const SizedBox(width: 6),
                    Expanded(child: Text(event['title'] as String, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: titleColor), overflow: TextOverflow.ellipsis)),
                  ]),
                  const SizedBox(height: 3),
                  Text('by ${event['host']}', style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                  if (location.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Row(children: [
                      const Icon(Icons.location_on_outlined, size: 12, color: AppColors.muted),
                      const SizedBox(width: 3),
                      Expanded(child: Text(location, style: const TextStyle(fontSize: 12, color: AppColors.muted), overflow: TextOverflow.ellipsis)),
                    ]),
                  ],
                  const SizedBox(height: 6),
                  Row(children: [
                    _buildPill('$yes Yes', AppColors.green),
                    const SizedBox(width: 6),
                    _buildPill('$maybe Maybe', AppColors.gold),
                  ]),
                ]),
              ),
              const Icon(Icons.chevron_right, color: AppColors.muted, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selectedIds.clear();
    });
  }

  Future<void> _deleteSelected() async {
    final count = _selectedIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Events'),
        content: Text('Permanently delete $count event${count == 1 ? '' : 's'}? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final db = FirebaseFirestore.instance;
    final batch = db.batch();
    for (final id in _selectedIds) {
      batch.delete(db.collection('events').doc(id));
    }
    await batch.commit();
    if (mounted) _exitSelectMode();
  }

  Widget _buildPastTab() {
    final count = _pastCount;
    final Color pillColor = count >= 19 ? Colors.redAccent : count >= 15 ? AppColors.gold : AppColors.green;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => selectedTab = 1),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: selectedTab == 1 ? AppColors.green : Colors.transparent, width: 2.5)),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text('Past', style: TextStyle(fontWeight: selectedTab == 1 ? FontWeight.w700 : FontWeight.w400, color: selectedTab == 1 ? AppColors.green : AppColors.muted, fontSize: 15)),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: pillColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20), border: Border.all(color: pillColor.withValues(alpha: 0.35))),
              child: Text('$count / 20', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: pillColor)),
            ),
          ]),
        ),
      ),
    );
  }

  void _showStorageBottomSheet(int count) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => Container(
        decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(color: AppColors.greenPale, borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 20),
            const Text('Event Storage', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.dark)),
            const SizedBox(height: 6),
            Text('You have used $count of your 20 free archived events.', style: const TextStyle(fontSize: 14, color: AppColors.muted)),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: (count / 20).clamp(0.0, 1.0),
                minHeight: 8,
                backgroundColor: AppColors.greenPale,
                valueColor: AlwaysStoppedAnimation<Color>(
                  count >= 19 ? Colors.redAccent : count >= 15 ? AppColors.gold : AppColors.green,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text('$count / 20 events used', style: const TextStyle(fontSize: 12, color: AppColors.muted)),
            const SizedBox(height: 24),
            const Text('Upgrade for more storage', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.dark)),
            const SizedBox(height: 12),
            _storageTier(context: context, label: '25 Events', price: '\$4.99', description: 'One-time purchase · 25 archived events', color: AppColors.green),
            const SizedBox(height: 10),
            _storageTier(context: context, label: '50 Events', price: '\$9.99', description: 'One-time purchase · 50 archived events', color: AppColors.purple),
          ],
        ),
      ),
    );
  }

  Widget _storageTier({required BuildContext context, required String label, required String price, required String description, required Color color}) {
    return GestureDetector(
      onTap: () { Navigator.pop(context); showComingSoon(context, 'Upgrade to $label'); },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(14), border: Border.all(color: color.withValues(alpha: 0.25))),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: color)),
            const SizedBox(height: 2),
            Text(description, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
          ])),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
            child: Text(price, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
          ),
        ]),
      ),
    );
  }

  Widget _buildTab(int index, String label) {
    final isSelected = selectedTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => selectedTab = index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: isSelected ? AppColors.green : Colors.transparent, width: 2.5)),
          ),
          child: Center(
            child: Text(label, style: TextStyle(fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400, color: isSelected ? AppColors.green : AppColors.muted, fontSize: 15)),
          ),
        ),
      ),
    );
  }

  Widget _draftsSectionHeader(int count) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 10, left: 2),
        child: Row(children: [
          const Icon(Icons.edit_note_outlined, size: 16, color: AppColors.gold),
          const SizedBox(width: 6),
          Text(
            'DRAFTS · $count',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: AppColors.gold, letterSpacing: 1.2),
          ),
        ]),
      );

  Widget _upcomingSectionHeader(int count) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 10, left: 2),
        child: Text(
          'UPCOMING · $count',
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: AppColors.muted, letterSpacing: 1.2),
        ),
      );

  /// Section header for the Invited list. Purple to distinguish from
  /// the user's own UPCOMING/DRAFTS sections at a glance — the brand
  /// accent for "guest mode" surfaces. Generalised to "INVITED" since
  /// the list now includes Maybe/No RSVPs alongside Yes.
  Widget _attendingSectionHeader(int count) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 10, left: 2),
        child: Row(children: [
          const Icon(Icons.event_available_outlined, size: 16, color: AppColors.purple),
          const SizedBox(width: 6),
          Text(
            'INVITED · $count',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: AppColors.purple, letterSpacing: 1.2),
          ),
        ]),
      );

  /// Compact card for events the user is invited to as a guest. Mirrors
  /// the chrome of [_buildEventCard] — same 20-radius, same Inter/Nunito
  /// hierarchy, same emoji-tile-on-the-left layout — but trims the
  /// host-only affordances (edit/notify, draft state, select mode,
  /// RSVP totals) and adds a status pill ("Attending" for Yes,
  /// "Invited to" for Maybe/No) so the user knows at a glance how they
  /// responded. Tapping opens the same GuestEventScreen the QR scan
  /// flow lands on.
  Widget _buildAttendingCard(BuildContext context, Map<String, dynamic> event) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : AppColors.dark;
    final cardBg = isDark ? const Color(0xFF383B56) : Colors.white;
    final borderColor = isDark
        ? const Color(0xFF4A4E6B)
        : Colors.black.withValues(alpha: 0.05);
    final color = event['color'] as Color;
    final date = event['date'] as DateTime;
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final dateStr = date.year < 2099 ? '${months[date.month - 1]} ${date.day}, ${date.year}' : 'Date TBD';
    final eventId = event['id'] as String;
    final hostName = event['host'] as String;
    final rsvpStatus = (event['rsvpStatus'] as String?) ?? 'Yes';
    final isAttending = rsvpStatus == 'Yes';
    final pillColor = isAttending ? AppColors.green : AppColors.purple;
    final pillIcon = isAttending ? Icons.check_circle_outline : Icons.mail_outline;
    final pillLabel = isAttending ? 'Attending' : 'Invited to';

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GuestEventScreen(
            eventId: eventId,
            eventData: Map<String, dynamic>.from(event['rawData'] as Map),
          ),
        ),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor),
        ),
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: Text(event['emoji'] as String, style: const TextStyle(fontSize: 24)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event['title'] as String,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: fg),
                ),
                const SizedBox(height: 3),
                Text(
                  dateStr,
                  style: const TextStyle(fontSize: 12, color: AppColors.muted, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  'Hosted by $hostName',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: AppColors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: pillColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(pillIcon, size: 12, color: pillColor),
              const SizedBox(width: 4),
              Text(
                pillLabel,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: pillColor, letterSpacing: 0.2),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('🎈', style: TextStyle(fontSize: 56)),
          const SizedBox(height: 16),
          const Text('No events here yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.dark)),
          const SizedBox(height: 8),
          const Text('Tap + to create your first event', style: TextStyle(fontSize: 14, color: AppColors.muted)),
        ],
      ),
    );
  }

  Widget _buildEventCard(BuildContext context, Map<String, dynamic> event) {
    final bool isPast = event['isPast'] as bool;
    final bool isDraft = event['isDraft'] as bool;
    final DateTime date = event['date'] as DateTime;
    final Color rawColor = event['color'] as Color;
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    // Dark-mode-safe accent. Several event-type primaries (Corporate,
    // Graduation, Holiday) are nearly black — on the dark card surface
    // they vanished. `onDarkSurface` lifts those to a readable shade
    // and is a no-op in light mode.
    final Color color = onDarkSurface(rawColor, isDark: isDark);
    final Color cardBg = isDark ? const Color(0xFF383B56) : Colors.white;
    final Color cardBorder = isDark
        ? const Color(0xFF4A4E6B)
        : Colors.black.withValues(alpha: 0.05);
    final Color titleColor = isDark ? Colors.white : AppColors.dark;
    final int rsvpTotal = ((event['yes'] as int? ?? 0) + (event['maybe'] as int? ?? 0) + (event['no'] as int? ?? 0));
    final bool canDelete = isPast || rsvpTotal == 0;
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final String eventId = event['id'] as String;
    final bool inSelectMode = _selectMode && isPast;
    final bool isSelected = _selectedIds.contains(eventId);

    final card = Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(color: cardBg, borderRadius: BorderRadius.circular(20), border: Border.all(color: cardBorder)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: isDraft ? const Color(0xFFFFF3E0) : isPast ? const Color(0xFFF0F0F0) : color.withValues(alpha: isDark ? 0.18 : 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: isDraft
                      ? const Column(children: [
                          Icon(Icons.edit_outlined, size: 14, color: Colors.orange),
                          SizedBox(height: 2),
                          Text('DRAFT', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Colors.orange)),
                        ])
                      : Column(children: [
                          Text(months[date.month - 1].toUpperCase(), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: isPast ? AppColors.muted : color)),
                          Text('${date.day}', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: isPast ? AppColors.muted : color)),
                        ]),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Text(event['emoji'] as String, style: const TextStyle(fontSize: 15)),
                        const SizedBox(width: 6),
                        Expanded(child: Text(event['title'] as String, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: titleColor))),
                      ]),
                      const SizedBox(height: 3),
                      isDraft
                          ? const Text('Draft — tap to continue editing', style: TextStyle(fontSize: 13, color: Colors.orange, fontWeight: FontWeight.w500))
                          : Text('Hosted by ${event['host']}', style: const TextStyle(fontSize: 13, color: AppColors.muted)),
                    ],
                  ),
                ),
                if (isPast && !isDraft)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: (event['isArchived'] as bool) ? AppColors.purple.withValues(alpha: 0.08) : const Color(0xFFF0F0F0),
                      borderRadius: BorderRadius.circular(100),
                      border: (event['isArchived'] as bool) ? Border.all(color: AppColors.purple.withValues(alpha: 0.25)) : null,
                    ),
                    child: Text(
                      (event['isArchived'] as bool) ? 'Archived' : 'Past',
                      style: TextStyle(fontSize: 12, color: (event['isArchived'] as bool) ? AppColors.purple : AppColors.muted, fontWeight: FontWeight.w500),
                    ),
                  ),
              ],
            ),
            if (!isDraft) ...[
              const SizedBox(height: 14),
              // Live counts straight from the rsvps subcollection — sums
              // adults+children+plusOnes per doc so a family-of-4 RSVP
              // shows as 4, not 1. The cached event doc counters
              // (event['yes']/['maybe']/['no']) are passed as the
              // initial render to avoid a 0-flash before the snapshot
              // resolves; once the listener fires the live totals win.
              RsvpLiveCounts(
                eventId: event['id'] as String,
                initial: (
                  yes:   event['yes']   as int? ?? 0,
                  maybe: event['maybe'] as int? ?? 0,
                  no:    event['no']    as int? ?? 0,
                ),
                builder: (ctx, yes, maybe, no) => Row(children: [
                  _buildPill('$yes Yes', AppColors.green),
                  const SizedBox(width: 8),
                  _buildPill('$maybe Maybe', AppColors.gold),
                  const SizedBox(width: 8),
                  _buildPill('$no No', Colors.redAccent),
                ]),
              ),
              if (!isPast) ...[
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: () => _togglePublic(event['id'] as String, event['isPublic'] as bool),
                  child: Row(children: [
                    Icon(
                      (event['isPublic'] as bool) ? Icons.public : Icons.lock_outline,
                      size: 14,
                      color: (event['isPublic'] as bool) ? AppColors.green : AppColors.muted,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      (event['isPublic'] as bool) ? 'Public — visible in Explore' : 'Private — only visible via link',
                      style: TextStyle(fontSize: 12, color: (event['isPublic'] as bool) ? AppColors.green : AppColors.muted, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(width: 6),
                    Text('· tap to change', style: TextStyle(fontSize: 11, color: AppColors.muted.withValues(alpha: 0.6))),
                  ]),
                ),
              ],
            ],
            const SizedBox(height: 14),
            if (isDraft)
              Row(children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CreateEventScreen(
                      draftId: event['id'] as String,
                      draftData: event['rawData'] as Map<String, dynamic>,
                    ))),
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('Edit & Publish', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 11),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => _confirmDelete(context, event['id'] as String, event['title'] as String),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.redAccent),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 12),
                  ),
                  child: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                ),
              ])
            else
              Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => GuestEventScreen(
                      eventId: event['id'] as String,
                      eventData: event['rawData'] as Map<String, dynamic>,
                    ))),
                    style: ElevatedButton.styleFrom(backgroundColor: AppColors.green, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 11)),
                    child: const Text('View Event', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: isPast
                      ? ElevatedButton(
                          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ThankYouScreen(eventId: event['id'] as String, eventTitle: event['title'] as String, eventEmoji: event['emoji'] as String))),
                          style: ElevatedButton.styleFrom(backgroundColor: AppColors.gold, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 11)),
                          child: const Text('Thank You', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        )
                      : OutlinedButton(
                          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => GenerateQRCodeScreen(eventId: event['id'] as String, eventTitle: event['title'] as String))),
                          style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.green), padding: const EdgeInsets.symmetric(vertical: 11)),
                          child: const Text('QR Code', style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w600, fontSize: 13)),
                        ),
                ),
                const SizedBox(width: 8),
                if (isPast)
                  ElevatedButton(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PictureWallScreen(eventId: event['id'] as String, eventTitle: event['title'] as String))),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.purple,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 14),
                    ),
                    child: const Icon(Icons.photo_library_outlined, size: 20),
                  )
                else ...[
                  OutlinedButton(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => EditEventScreen(eventId: event['id'] as String, eventData: event['rawData'] as Map<String, dynamic>))),
                    style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.green), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)), padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 12)),
                    child: const Icon(Icons.edit_outlined, color: AppColors.green, size: 18),
                  ),
                  if (canDelete) ...[
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => _confirmDelete(context, event['id'] as String, event['title'] as String),
                      style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.redAccent), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)), padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 12)),
                      child: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                    ),
                  ],
                ],
                if (isPast) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => _confirmDelete(context, event['id'] as String, event['title'] as String),
                    style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.redAccent), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)), padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 12)),
                    child: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );

    final bool isArchived = (event['isArchived'] as bool?) ?? false;
    final bool isUpcoming = !isPast && !isDraft && !isArchived;

    if (!inSelectMode) {
      if (!isUpcoming) return card;
      // Upcoming events get a top-right QR shortcut that jumps straight to the
      // GenerateQRCodeScreen for this event — so hosts can share the QR without
      // entering the event first.
      return Stack(
        children: [
          card,
          Positioned(
            top: 8, right: 8,
            child: _buildQrIconButton(eventId, event['title'] as String),
          ),
        ],
      );
    }

    return GestureDetector(
      onTap: () => setState(() {
        if (isSelected) {
          _selectedIds.remove(eventId);
        } else {
          _selectedIds.add(eventId);
        }
      }),
      child: Stack(
        children: [
          card,
          Positioned(
            top: 16,
            right: 16,
            child: IgnorePointer(
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isSelected ? Colors.redAccent : Colors.transparent,
                  border: Border.all(
                    color: isSelected ? Colors.redAccent : AppColors.muted,
                    width: 2,
                  ),
                ),
                child: isSelected
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _autoArchivePastEvents() {
    final now = DateTime.now();
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    for (final event in _events) {
      if ((event['isDraft'] as bool) || !(event['isPast'] as bool) || (event['isArchived'] as bool)) continue;
      final id = event['id'] as String;
      final date = event['date'] as DateTime;
      FirebaseFirestore.instance.collection('events').doc(id)
          .update({'isArchived': true}).catchError((_) {});
      final notifyAt = date.add(const Duration(days: 153));
      if (notifyAt.isAfter(now)) {
        FirebaseFirestore.instance.collection('notificationTasks').doc('${id}_photos').set({
          'type': 'photo_expiry_warning',
          'eventId': id,
          'eventTitle': event['title'] as String,
          'message': 'Photos from "${event['title']}" will expire in 30 days. Download them now to keep them forever.',
          'scheduledFor': Timestamp.fromDate(notifyAt),
          'hostId': user.uid,
          'status': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
        }).catchError((_) {});
      }
    }
  }

  Future<void> _togglePublic(String eventId, bool current) async {
    try {
      await FirebaseFirestore.instance
          .collection('events')
          .doc(eventId)
          .update({'isPublic': !current});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not update: $e'), backgroundColor: Colors.redAccent));
    }
  }

  void _confirmDelete(BuildContext context, String eventId, String title) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Delete event?'),
        content: Text('Are you sure you want to delete "$title"? This will permanently remove all RSVPs, photos, and data.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteEvent(eventId, title);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteSubcollection(CollectionReference ref) async {
    const batchSize = 100;
    while (true) {
      final snap = await ref.limit(batchSize).get();
      if (snap.docs.isEmpty) break;
      final batch = FirebaseFirestore.instance.batch();
      for (final doc in snap.docs) batch.delete(doc.reference);
      await batch.commit();
      if (snap.docs.length < batchSize) break;
    }
  }

  Future<void> _deleteEvent(String eventId, String title) async {
    try {
      final eventRef = FirebaseFirestore.instance.collection('events').doc(eventId);

      // Delete subcollections in parallel
      await Future.wait([
        _deleteSubcollection(eventRef.collection('rsvps')),
        _deleteSubcollection(eventRef.collection('photos')),
        _deleteSubcollection(eventRef.collection('wishlist_contributions')),
      ]);

      // Delete top-level notification task doc for this event
      FirebaseFirestore.instance
          .collection('notificationTasks')
          .doc('${eventId}_photos')
          .delete()
          .catchError((_) {});

      // Delete photos from Firebase Storage
      try {
        final listResult = await FirebaseStorage.instance
            .ref('events/$eventId/photos')
            .listAll();
        await Future.wait(listResult.items.map((item) => item.delete()));
      } catch (_) {}

      // Delete the event document itself
      await eventRef.delete();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('"$title" deleted'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to delete: $e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
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
            color: AppColors.purple,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: AppColors.purple.withValues(alpha: 0.3), blurRadius: 6, offset: const Offset(0, 2))],
          ),
          child: const Icon(Icons.qr_code_2, color: Colors.white, size: 18),
        ),
      ),
    );
  }

  Widget _buildPill(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(100)),
        child: Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      );
}
