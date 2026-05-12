import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils.dart';
import 'picture_wall_screen.dart';
import 'thank_you_screen.dart';
import 'host_notifications_screen.dart';
import 'home_feed_screen.dart';

// Flip to false to re-enable real Stripe checkout.
const bool kTestingMode = false;

// ── Theme palette ──────────────────────────────────────────────
// Light + dark variants for the four surface colors; accents stay the same.
// Instance getters inside each State class pick the right variant from
// Theme.of(context) at build time, so the screen follows the ThemeNotifier.
const _bgDark      = Color(0xFF2D3047);
const _bgLight     = Color(0xFFF8F7FC);
const _cardDark    = Color(0xFF383B56);
const _cardLight   = Colors.white;
const _borderDark  = Color(0xFF4A4E6B);
const _borderLight = Color(0xFFE0E8E0);
const _mutedDark   = Color(0xFFA9A6B8);
const _mutedLight  = Color(0xFF8892A4);
const _purple      = Color(0xFF9C7FD4);

class GuestEventScreen extends StatefulWidget {
  final String? eventId;
  final Map<String, dynamic>? eventData;
  final bool isOnboarding;
  const GuestEventScreen({super.key, this.eventId, this.eventData, this.isOnboarding = false});
  @override
  State<GuestEventScreen> createState() => _GuestEventScreenState();
}

class _GuestEventScreenState extends State<GuestEventScreen> with TickerProviderStateMixin {
  late TabController _tabController;

  bool _showWelcome = false;
  late AnimationController _welcomeCtrl;
  late Animation<double> _welcomeAnim;
  String rsvpStatus = 'Not Responded';

  // Rebuild on tab change so [_showDoneBanner] reevaluates — the
  // bottomNavigationBar slot is a sibling of TabBarView, not inside it,
  // so a tab swipe alone doesn't trigger a rebuild of the banner.
  void _onTabChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// Shows the bottom "All Set" banner when the guest has RSVPed AND
  /// is on a Wishlist/Checklist tab — gives them an explicit way out
  /// of the list flow without relying on the back gesture (especially
  /// after the auto-switch to Checklist on RSVP for Checklist-only
  /// events). Hidden on Info tab (auto-pop handles that path) and
  /// during onboarding (the onboarding banner owns the slot).
  bool get _showDoneBanner =>
      !widget.isOnboarding &&
      (rsvpStatus == 'Yes' || rsvpStatus == 'Maybe' || rsvpStatus == 'No') &&
      _tabController.index != 0;
  String _pendingStatus = 'Not Responded';
  int adults = 1;
  int children = 0;
  int plusOnes = 0;
  final TextEditingController _plusOnesController = TextEditingController(text: '0');
  List<String> uploadedPhotos = [];

  bool _allowPlusOnes = false;
  String? _eventTypeName;

  /// Plus-ones is only relevant for Corporate and Wedding events. Even
  /// when the event doc has `allowPlusOnes: true` (carry-over from a
  /// time when the toggle was offered for every type), we hide the
  /// selector for every other event type and for events with no type
  /// set (public web RSVPs especially).
  bool get _supportsPlusOnesType =>
      _eventTypeName == 'Corporate' || _eventTypeName == 'Wedding';
  int? _maxPlusOnes;

  late String eventTitle;
  late String eventDate;
  late String eventLocation;
  late String eventEmoji;
  late Color eventColor;
  late bool eventHasEnded;
  // Free-form host description shown below the date/location card on
  // the Info tab. Empty when the host left the editor's description
  // field blank — the row hides itself in that case.
  String _eventDescription = '';
  bool _isHost = false;
  bool _isCoHost = false;
  bool _isHostMode = false;
  bool _isArchived = false;
  // True when the host marked the event as outdoor — gates the
  // weather widget so indoor events don't surface a forecast pill
  // that's irrelevant to them. Hydrated from `isOutdoor` on the
  // event doc; defaults false for legacy events without the flag.
  bool _isOutdoor = false;
  String? _hostId;
  bool _rsvpClosed = false;
  String _rsvpDeadlineLabel = '';
  late String listType;
  late List<Map<String, dynamic>> wishlistItems;
  bool _savingRsvp = false;

  Map<String, dynamic>? _weatherData;
  bool _weatherLoading = false;

  List<Map<String, dynamic>> _rsvps = [];
  StreamSubscription<QuerySnapshot>? _rsvpsSub;

  /// External gift-registry URLs the host attached on the edit/create
  /// event screens (Zola, Amazon, Babylist, etc.). Hydrated from the
  /// event doc's top-level `registryLinks` field via `_populateFrom
  /// EventData` — clear()+addAll() instead of reassign so the field
  /// stays final. The Registry section in the Info tab self-hides
  /// when this list is empty so events without registries (most
  /// parties) get no extra chrome.
  final List<String> _registryLinks = [];

  /// `_rsvps` with web-source duplicates collapsed against their app
  /// counterparts. The same human can land in `_rsvps` twice when they
  /// RSVP via `event.html` (doc id = email) AND via the app (doc id =
  /// uid) — both rows arrive with different `'uid'` values because we
  /// store `'uid': doc.id`. The visible guest list, avatar scroller,
  /// and group counts all read this getter so a single person renders
  /// once. Mirrors the dedup branch in [_peopleFor].
  List<Map<String, dynamic>> get _dedupedRsvps {
    final byId = <String, Map<String, dynamic>>{};
    for (final g in _rsvps) {
      byId[g['uid'] as String] = g;
    }
    bool looksLikeEmail(String id) => id.contains('@');
    final emails = byId.entries.where((e) => looksLikeEmail(e.key)).toList();
    for (final webEntry in emails) {
      final webName = (webEntry.value['name'] as String?)?.trim().toLowerCase();
      if (webName == null || webName.isEmpty) continue;
      final hasAppDup = byId.values.any((other) {
        final otherUid = other['uid'] as String;
        if (looksLikeEmail(otherUid)) return false;
        final otherName = (other['name'] as String?)?.trim().toLowerCase();
        return otherName == webName;
      });
      if (hasAppDup) byId.remove(webEntry.key);
    }
    return byId.values.toList();
  }

  int? _capacity;
  bool _allowWaitlist = false;
  List<Map<String, dynamic>> _waitlist = [];
  StreamSubscription<QuerySnapshot>? _waitlistSub;
  bool _joiningWaitlist = false;

  Map<String, double> _myContributions = {};
  StreamSubscription<DocumentSnapshot>? _contribSub;

  bool _showChecklistBanner = true;
  final List<Map<String, dynamic>> _cart = [];

  // Theme-aware color getters — resolve light vs dark variant from the current Theme.
  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;


  // ── Registry section ────────────────────────────────────────
  /// Friendly label for a registry URL. Recognised registries get a
  /// branded name; everything else falls back to the bare host (with a
  /// leading `www.` stripped). Mirrors the helper used host-side on
  /// edit_event_screen / create_event_screen so a registry pasted in
  /// either editor renders with the same label here on the guest view.
  String _registryLabel(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('zola.com'))            { return 'Zola'; }
    if (lower.contains('amazon.com'))          { return 'Amazon'; }
    if (lower.contains('target.com'))          { return 'Target'; }
    if (lower.contains('theknot.com'))         { return 'The Knot'; }
    if (lower.contains('babylist.com'))        { return 'Babylist'; }
    if (lower.contains('crateandbarrel.com'))  { return 'Crate & Barrel'; }
    if (lower.contains('williams-sonoma.com') ||
        lower.contains('williamssonoma.com'))  { return 'Williams Sonoma'; }
    final uri = Uri.tryParse(url.startsWith('http') ? url : 'https://$url');
    if (uri == null) return url;
    final host = uri.host.replaceFirst('www.', '');
    return host.isEmpty ? url : host;
  }

  /// Hand off to the OS to open the registry URL in the user's default
  /// browser / retailer app. externalApplication mode (vs. the in-app
  /// browser used elsewhere) is intentional — registries often require
  /// sign-in / persistent cart state, both of which work better in the
  /// user's real browser session than in a one-shot WebView.
  Future<void> _openRegistryUrl(String url) async {
    final uri = Uri.tryParse(url.startsWith('http') ? url : 'https://$url');
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[Registry] launchUrl failed for $url: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open: $url'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  /// Renders the host's registry links as a small list of tappable
  /// rows. Self-hides when [_registryLinks] is empty so events
  /// without registries don't get an empty card.
  Widget _buildRegistrySection() {
    if (_registryLinks.isEmpty) return const SizedBox.shrink();
    final fg = _isDark ? Colors.white : AppColors.dark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.card_giftcard_outlined, size: 18, color: AppColors.purple),
            const SizedBox(width: 8),
            Text(
              'Registry',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: fg),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            'Tap to open in your browser',
            style: TextStyle(fontSize: 12, color: _muted),
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < _registryLinks.length; i++) ...[
            InkWell(
              onTap: () => _openRegistryUrl(_registryLinks[i]),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: _bg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _border),
                ),
                child: Row(children: [
                  Container(
                    width: 32, height: 32,
                    decoration: BoxDecoration(
                      color: AppColors.purple.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.card_giftcard_outlined, size: 16, color: AppColors.purple),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_registryLabel(_registryLinks[i]),
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: fg)),
                        Text(_registryLinks[i],
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: _muted)),
                      ],
                    ),
                  ),
                  Icon(Icons.open_in_new, size: 16, color: _muted),
                ]),
              ),
            ),
            if (i < _registryLinks.length - 1) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Future<void> _addToCalendar() async {
    final data = widget.eventData;
    DateTime? start;
    if (data != null) {
      final ts = data['date'];
      if (ts is Timestamp) {
        start = ts.toDate();
        final timeStr = (data['time'] as String?) ?? '';
        if (timeStr.isNotEmpty) {
          final parts = timeStr.split(':');
          final hour = int.tryParse(parts[0]) ?? 0;
          final minute = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;
          start = DateTime(start.year, start.month, start.day, hour, minute);
        }
      }
    }
    start ??= DateTime.now().add(const Duration(days: 1));
    final end = start.add(const Duration(hours: 2));

    String fmtUtc(DateTime dt) {
      final u = dt.toUtc();
      return '${u.year}'
          '${u.month.toString().padLeft(2, '0')}'
          '${u.day.toString().padLeft(2, '0')}'
          'T${u.hour.toString().padLeft(2, '0')}'
          '${u.minute.toString().padLeft(2, '0')}'
          '${u.second.toString().padLeft(2, '0')}Z';
    }

    final description = (data?['description'] as String?) ?? '';
    final query = [
      'action=TEMPLATE',
      'text=${Uri.encodeQueryComponent(eventTitle)}',
      'dates=${Uri.encodeQueryComponent(fmtUtc(start))}/${Uri.encodeQueryComponent(fmtUtc(end))}',
      'details=${Uri.encodeQueryComponent(description)}',
      'location=${Uri.encodeQueryComponent(eventLocation)}',
    ].join('&');
    final uri = Uri.parse('https://calendar.google.com/calendar/render?$query');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _notifyHost(String title, String body) async {
    if (_hostId == null) return;
    final eventId = widget.eventId;
    // Both gates are required: the firestore.rules rule on
    // notificationQueue requires the eventId field, so silently
    // skipping when it's null is preferable to writing a doc that
    // would just bounce with permission-denied anyway.
    if (eventId == null || eventId.isEmpty) return;
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(_hostId).get();
      final token = doc.data()?['fcmToken'] as String?;
      if (token != null) {
        await NotificationService.sendNotification([token], title, body, eventId: eventId);
      }
    } catch (_) {}
  }

  void _addToCart(String name, double amount) {
    setState(() {
      final idx = _cart.indexWhere((c) => c['name'] == name && c['type'] == 'contribute');
      if (idx >= 0) {
        _cart[idx]['amount'] = (_cart[idx]['amount'] as double) + amount;
      } else {
        _cart.add({'name': name, 'type': 'contribute', 'amount': amount});
      }
    });
  }

  void _removeFromCart(String name) {
    setState(() => _cart.removeWhere((c) => c['name'] == name));
  }

  // Claim input (checklist tab)
  int? _activeClaimIndex;
  bool _savingClaim = false;
  // Selected quantity for the active claim. Replaces the prior
  // free-text TextField — guests pick from preset chips (1–5, 6+) so
  // the saved value is always a clean tally rather than free-form
  // copy like "a couple". Default 1 mirrors the most common case.
  // Stored as a string so the existing claim payload shape (String
  // amount) doesn't change.
  String _activeClaimQty = '1';
  static const List<String> _claimQtyOptions = ['1', '2', '3', '4', '5'];
  // Manual-entry escape hatch for the chip selector — tapping the
  // "or enter amount" link below the chips swaps the chip row for a
  // numeric TextField so a guest can type any number (30 cups, 12
  // chairs, etc.) without being constrained to 1–6+. The controller
  // is preserved across rebuilds while the active claim sheet is
  // open; closing/confirming/saving resets both fields back to chip
  // mode for the next item.
  bool _activeClaimManualMode = false;
  final TextEditingController _claimManualCtrl = TextEditingController();

  /// Numeric value behind a chip label. '6+' counts as 6 for cap
  /// math; everything else parses straight. Default 1 keeps the
  /// arithmetic safe even on malformed legacy entries.
  int _claimAmountValue(String? amount) {
    if (amount == null) return 1;
    if (amount == '6+') return 6;
    return int.tryParse(amount) ?? 1;
  }

  /// Sum of every guest's claim amount on a checklist item. Drives
  /// the "X/Y claimed" header and the chip-cap math. Skips entries
  /// that have no parseable amount (defaults to 1 each so legacy
  /// claims still register as one person bringing one of the item).
  int _itemTotalClaimed(Map<String, dynamic> item) {
    final claims = (item['claims'] as List?) ?? const [];
    return claims.fold<int>(
      0,
      (sum, c) => sum + _claimAmountValue((c as Map?)?['amount'] as String?),
    );
  }

  /// Host-set quantity needed for a checklist item. Reads
  /// `quantityNeeded` (int) when present; falls back to parsing a
  /// leading integer out of the legacy free-form `quantity` String
  /// (e.g. "12 chairs" → 12). Returns null when neither yields a
  /// usable count — caller should treat that as "no cap".
  ///
  /// Items flagged `unlimited: true` ALWAYS return null here so every
  /// downstream cap check (chip filter, manual-entry max, "Fully
  /// claimed" pill) collapses to no-cap behavior automatically.
  int? _itemQuantityNeeded(Map<String, dynamic> item) {
    if (item['unlimited'] == true) return null;
    final raw = item['quantityNeeded'];
    if (raw is num && raw > 0) return raw.toInt();
    final str = (item['quantity'] as String?) ?? '';
    final m = RegExp(r'\d+').firstMatch(str);
    if (m == null) return null;
    final parsed = int.tryParse(m.group(0)!);
    return (parsed != null && parsed > 0) ? parsed : null;
  }

  // Filter to wishlist-kind items before folding — checklist items
  // have no `price` / `contributed` field, so a Both-mode event with
  // a checklist item used to crash here on `null as double`. Cast
  // through `num?` so int-shaped legacy values also lift cleanly.
  double get totalWishlistValue => wishlistItems
      .where((i) => _itemKind(i) == 'wishlist')
      .fold<double>(0, (sum, i) => sum + ((i['price'] as num?)?.toDouble() ?? 0.0));
  double get totalContributed => wishlistItems
      .where((i) => _itemKind(i) == 'wishlist')
      .fold<double>(0, (sum, i) => sum + ((i['contributed'] as num?)?.toDouble() ?? 0.0));

  /// Whether the middle tab (Checklist/Wishlist) should render. Hidden
  /// when the event has no list at all, OR when the event's list type
  /// is `Wishlist` while the Wishlist beta gate is closed
  /// (`kWishlistEnabled = false`). Existing wishlist data on the event
  /// doc is preserved either way; only the UI surface is suppressed.
  /// Per-kind visibility derived from [listType]. The host editor
  /// writes one of {'No List','Wishlist','Checklist','Both'}; in Both
  /// mode the guest screen renders TWO list tabs (Wishlist AND
  /// Checklist) instead of one. Both flags also gate visibility of
  /// the kWishlistEnabled beta toggle for the wishlist surface.
  bool get _hasWishlist =>
      kWishlistEnabled && (listType == 'Wishlist' || listType == 'Both');
  bool get _hasChecklist =>
      listType == 'Checklist' || listType == 'Both';

  /// Resolves the per-item kind. Items written by the new editor
  /// carry an explicit `kind` field; legacy items (no field) infer
  /// from listType — a 'Wishlist' event's items are wishlist, a
  /// 'Checklist' event's items are checklist. For 'Both' events
  /// without a `kind` field, the price field decides: a positive
  /// price means wishlist (someone meant for it to be gifted /
  /// contributed to), and a missing or zero price means checklist
  /// (potluck/RSVP item where guests claim what they'll bring).
  /// This auto-routes legacy data without a Firestore migration.
  String _itemKind(Map<String, dynamic> item) {
    final stored = item['kind'] as String?;
    if (stored == 'wishlist' || stored == 'checklist') return stored!;
    if (listType == 'Checklist') return 'checklist';
    if (listType == 'Both') {
      final price = (item['price'] as num?)?.toDouble() ?? 0.0;
      return price > 0 ? 'wishlist' : 'checklist';
    }
    return 'wishlist';
  }

  /// Original-array indices of items that match [kind]. Returned
  /// indices reference [wishlistItems] directly so per-item mutations
  /// (claim, contribute, bought toggle) keep working without
  /// translating between filtered and master indexes. In single-mode
  /// events (not 'Both'), this returns every index since all items
  /// implicitly belong to the active kind.
  List<int> _indicesOfKind(String kind) {
    if (listType != 'Both') {
      return List.generate(wishlistItems.length, (i) => i);
    }
    final out = <int>[];
    for (var i = 0; i < wishlistItems.length; i++) {
      if (_itemKind(wishlistItems[i]) == kind) out.add(i);
    }
    return out;
  }

  @override
  void initState() {
    super.initState();
    _initEventData(); // must run first to set listType
    // Tab count = 2 (Info + Photos) + 1 per active list. Both mode
    // gives 4 tabs; single-list mode gives 3; No-List gives 2.
    final listTabs = (_hasWishlist ? 1 : 0) + (_hasChecklist ? 1 : 0);
    _tabController = TabController(length: 2 + listTabs, vsync: this)
      ..addListener(_onTabChanged);
    _welcomeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    _welcomeAnim = CurvedAnimation(parent: _welcomeCtrl, curve: Curves.easeIn);
    if (widget.isOnboarding) {
      _showWelcome = true;
      _welcomeCtrl.forward();
    }
    _loadExistingRsvp();
    _subscribeToRsvps();
    _subscribeToWaitlist();
    _subscribeToMyContributions();
    _fetchWeather();
  }

  void _subscribeToWaitlist() {
    if (widget.eventId == null) return;
    _waitlistSub = FirebaseFirestore.instance
        .collection('events')
        .doc(widget.eventId)
        .collection('waitlist')
        .orderBy('timestamp')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _waitlist = snap.docs.map((doc) {
          final d = doc.data();
          return {
            'uid': doc.id,
            'name':  (d['name']  as String?) ?? 'Guest',
            'email': (d['email'] as String?) ?? '',
          };
        }).toList();
      });
    });
  }

  Future<void> _joinWaitlist() async {
    if (widget.eventId == null) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in to join the waitlist'), backgroundColor: AppColors.muted),
      );
      return;
    }
    setState(() => _joiningWaitlist = true);
    try {
      String? fcmToken;
      try {
        final userDoc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
        fcmToken = userDoc.data()?['fcmToken'] as String?;
      } catch (_) {}
      await FirebaseFirestore.instance
          .collection('events').doc(widget.eventId)
          .collection('waitlist').doc(user.uid)
          .set({
            'uid': user.uid,
            'name': user.displayName ?? 'Guest',
            'email': user.email ?? '',
            'fcmToken': fcmToken,
            'timestamp': FieldValue.serverTimestamp(),
          });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("You're on the waitlist! We'll notify you if a spot opens."), backgroundColor: AppColors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not join waitlist: $e'), backgroundColor: Colors.redAccent),
        );
      }
    } finally {
      if (mounted) setState(() => _joiningWaitlist = false);
    }
  }

  Future<void> _leaveWaitlist() async {
    if (widget.eventId == null) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('events').doc(widget.eventId)
          .collection('waitlist').doc(user.uid)
          .delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Removed from waitlist'), backgroundColor: AppColors.muted),
        );
      }
    } catch (_) {}
  }

  Future<void> _loadExistingRsvp() async {
    if (widget.eventId == null) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('events')
          .doc(widget.eventId)
          .collection('rsvps')
          .doc(user.uid)
          .get();
      if (doc.exists && mounted) {
        final d = doc.data()!;
        setState(() {
          rsvpStatus = (d['status'] as String?) ?? 'Not Responded';
          _pendingStatus = rsvpStatus;
          adults = (d['adults'] as int?) ?? 1;
          children = (d['children'] as int?) ?? 0;
          plusOnes = (d['plusOnes'] as int?) ?? 0;
          _plusOnesController.text = '$plusOnes';
        });
      }
    } catch (_) {}
  }

  void _subscribeToRsvps() {
    if (widget.eventId == null) return;
    _rsvpsSub = FirebaseFirestore.instance
        .collection('events')
        .doc(widget.eventId)
        .collection('rsvps')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      // Raw-doc dump on every snapshot so any host/guest count mismatch
      // can be diagnosed by comparing what each device received from
      // Firestore. Look for `[RSVP] snapshot` lines in flutter logs.
      debugPrint('[RSVP] snapshot eventId=${widget.eventId} docs=${snap.docs.length} fromCache=${snap.metadata.isFromCache} hasPending=${snap.metadata.hasPendingWrites}');
      for (final doc in snap.docs) {
        final d = doc.data();
        debugPrint('[RSVP]   docId=${doc.id} status=${d['status']} adults=${d['adults']} children=${d['children']} plusOnes=${d['plusOnes']} source=${d['source']} email=${d['email']}');
      }
      // Defensive merge: if the snapshot is missing the current
      // user's own RSVP but we DO have an optimistic copy from a
      // recent _saveRsvp call, keep it in the displayed list. The
      // snapshot is normally authoritative, but a brief read-rule
      // hiccup or eventual-consistency window between the write
      // and the listener fire used to wipe the optimistic entry —
      // the counter pill would still reflect the write (the same
      // _rsvps source) for a beat, but a subsequent empty snapshot
      // would leave both empty. Stamping the user's own row back in
      // when it's missing means the avatar row never goes blank
      // for the person who just RSVPed.
      final myUid = FirebaseAuth.instance.currentUser?.uid;
      final fresh = snap.docs.map<Map<String, dynamic>>((doc) {
        final d = doc.data();
        return <String, dynamic>{
          'uid': doc.id,
          'name': (d['name'] as String?) ?? 'Guest',
          'status': (d['status'] as String?) ?? 'Not Responded',
          // Default of 1 preserves legacy behavior: app RSVPs written
          // before the multi-person feature didn't have an `adults`
          // field and represented 1 person. Web RSVPs (which never
          // write the count fields) also count as 1 person, which
          // matches product intent.
          'adults': (d['adults'] as int?) ?? 1,
          'children': (d['children'] as int?) ?? 0,
          'plusOnes': (d['plusOnes'] as int?) ?? 0,
          'source': (d['source'] as String?) ?? 'app',
        };
      }).toList();
      if (myUid != null
          && !fresh.any((r) => r['uid'] == myUid)
          && _rsvps.any((r) => r['uid'] == myUid && r['status'] != 'Not Responded')) {
        final mineLocal = _rsvps.firstWhere((r) => r['uid'] == myUid);
        debugPrint('[RSVP] preserving local entry for myUid=$myUid (snapshot did not include it yet)');
        fresh.add(mineLocal);
      }
      setState(() {
        _rsvps = fresh;
      });
    },
    // Subscriptions previously had no error handler, so a transient
    // listener failure (auth-state churn, brief offline window,
    // rules evaluation error) silently killed the stream and
    // _rsvps was never updated again. Logging the error makes the
    // failure visible in flutter logs; cancelOnError stays at the
    // default false so Firestore's built-in reconnect can resume
    // the stream once the underlying issue clears.
    onError: (err, st) {
      debugPrint('[RSVP] listener error eventId=${widget.eventId}: $err');
    });
  }

  void _subscribeToMyContributions() {
    if (widget.eventId == null) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    _contribSub = FirebaseFirestore.instance
        .collection('events')
        .doc(widget.eventId)
        .collection('wishlist_contributions')
        .doc(user.uid)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final raw = snap.data()?['items'] as Map<String, dynamic>? ?? {};
      setState(() {
        _myContributions = raw.map((k, v) => MapEntry(k, (v as num).toDouble()));
      });
    });
  }

  Future<void> _contributeFirestore(int index, double amount) async {
    if (widget.eventId == null) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final item = wishlistItems[index];
    final itemName = item['name'] as String;
    final price = item['price'] as double;
    final eventRef = FirebaseFirestore.instance.collection('events').doc(widget.eventId);
    final contribRef = eventRef.collection('wishlist_contributions').doc(user.uid);
    await FirebaseFirestore.instance.runTransaction((tx) async {
      final eventSnap = await tx.get(eventRef);
      final rawWishlist = List<Map<String, dynamic>>.from(
        (eventSnap.data()?['wishlist'] as List<dynamic>? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
      );
      final currentTotal = (rawWishlist[index]['contributed'] as num?)?.toDouble() ?? 0.0;
      final remaining = price - currentTotal;
      if (remaining <= 0) return;
      final toAdd = amount > remaining ? remaining : amount;
      rawWishlist[index]['contributed'] = currentTotal + toAdd;
      final contribSnap = await tx.get(contribRef);
      final existingItems = Map<String, dynamic>.from(contribSnap.data()?['items'] as Map? ?? {});
      final myPrev = (existingItems[itemName] as num?)?.toDouble() ?? 0.0;
      existingItems[itemName] = myPrev + toAdd;
      tx.update(eventRef, {'wishlist': rawWishlist});
      tx.set(contribRef, {'items': existingItems}, SetOptions(merge: true));
    });
    // Compute the locally-clamped toAdd ONCE so the optimistic UI
    // update and the host notification agree on the dollar figure
    // they report — without this they were derived twice and could
    // drift after the wholesale state replacement on the next event-
    // doc snapshot.
    final currentTotal = item['contributed'] as double;
    final remaining = price - currentTotal;
    final toAdd = amount > remaining ? remaining : amount;
    setState(() {
      wishlistItems[index]['contributed'] = (currentTotal + toAdd).clamp(0.0, price);
    });
    // Notify the host that a guest contributed to their wishlist.
    // Match the guest-name resolution the RSVP notification uses so
    // a guest who never set displayName falls back to the local-part
    // of their email instead of just "Guest". Whole-dollar amounts
    // render without decimals to match the in-app contribute chips.
    final guestName = user.displayName ?? user.email?.split('@').first ?? 'A guest';
    final amountStr = toAdd == toAdd.roundToDouble()
        ? '\$${toAdd.toInt()}'
        : '\$${toAdd.toStringAsFixed(2)}';
    _notifyHost(
      'New Contribution 💝',
      '$guestName contributed $amountStr toward $itemName on $eventTitle',
    );
  }

  Future<void> _undoContributionFirestore(int index) async {
    if (widget.eventId == null) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final item = wishlistItems[index];
    final itemName = item['name'] as String;
    final eventRef = FirebaseFirestore.instance.collection('events').doc(widget.eventId);
    final contribRef = eventRef.collection('wishlist_contributions').doc(user.uid);
    await FirebaseFirestore.instance.runTransaction((tx) async {
      final eventSnap = await tx.get(eventRef);
      final contribSnap = await tx.get(contribRef);
      final rawWishlist = List<Map<String, dynamic>>.from(
        (eventSnap.data()?['wishlist'] as List<dynamic>? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
      );
      final existingItems = Map<String, dynamic>.from(contribSnap.data()?['items'] as Map? ?? {});
      final myAmount = (existingItems[itemName] as num?)?.toDouble() ?? 0.0;
      if (myAmount <= 0) return;
      final currentTotal = (rawWishlist[index]['contributed'] as num?)?.toDouble() ?? 0.0;
      rawWishlist[index]['contributed'] = (currentTotal - myAmount).clamp(0.0, double.infinity);
      existingItems.remove(itemName);
      tx.update(eventRef, {'wishlist': rawWishlist});
      tx.set(contribRef, {'items': existingItems});
    });
    setState(() {
      final myAmount = _myContributions[itemName] ?? 0.0;
      wishlistItems[index]['contributed'] = ((item['contributed'] as double) - myAmount).clamp(0.0, double.infinity);
      _myContributions.remove(itemName);
    });
  }

  Future<void> _saveRsvp(String newStatus, {bool switchTab = false}) async {
    setState(() { rsvpStatus = newStatus; _pendingStatus = newStatus; });

    if (widget.eventId == null) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in to save your RSVP'), backgroundColor: AppColors.muted),
      );
      return;
    }

    // ── Optimistic local update ──────────────────────────────────
    // Patch _rsvps in-memory so the headcount cards reflect the new
    // status the moment the user taps Yes/Maybe/No, instead of waiting
    // for the Firestore snapshot listener to fire (~150–500ms on a
    // typical network). The listener replaces _rsvps wholesale when
    // the write lands; if the transaction below fails, the next
    // snapshot reverts the local view to whatever the server actually
    // holds.
    final myUid = user.uid;
    // Plus-ones is gated to Corporate / Wedding events even when the host
    // has the flag on — same rule the RSVP form UI uses, applied here so
    // a stale flag on a Birthday/etc. doc can't sneak a count into the
    // saved RSVP.
    final effectivePlusOnes = (_allowPlusOnes && _supportsPlusOnesType) ? plusOnes : 0;
    setState(() {
      final without = _rsvps.where((r) => r['uid'] != myUid).toList();
      _rsvps = [
        ...without,
        {
          'uid': myUid,
          'name': user.displayName ?? 'Guest',
          'status': newStatus,
          'adults': adults,
          'children': children,
          'plusOnes': effectivePlusOnes,
          // Match the schema the snapshot listener parses below so
          // _peopleFor's web/app dedupe sees consistent shapes.
          'source': 'app',
        },
      ];
    });

    setState(() => _savingRsvp = true);

    final eventRef = FirebaseFirestore.instance.collection('events').doc(widget.eventId);
    final rsvpRef = eventRef.collection('rsvps').doc(user.uid);

    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final existing = await tx.get(rsvpRef);
        final existingData = existing.exists ? existing.data() : null;
        final previousStatus = existingData?['status'] as String?;
        final oldHeadcount = ((existingData?['adults'] as int?) ?? 1)
            + ((existingData?['children'] as int?) ?? 0)
            + ((existingData?['plusOnes'] as int?) ?? 0);
        final effectivePlusOnes = (_allowPlusOnes && _supportsPlusOnesType) ? plusOnes : 0;
        final newHeadcount = adults + children + effectivePlusOnes;

        tx.set(rsvpRef, {
          'uid': user.uid,
          'name': user.displayName ?? 'Guest',
          // Explicit email + source so the host can later dedupe an app
          // RSVP against a web RSVP from the same person, and so debug
          // logs say which path wrote each row.
          if (user.email != null) 'email': user.email,
          'source': 'app',
          'status': newStatus,
          'adults': adults,
          'children': children,
          'plusOnes': effectivePlusOnes,
          'timestamp': FieldValue.serverTimestamp(),
        });

        final Map<String, dynamic> counts = {};
        if (previousStatus == newStatus) {
          final delta = newHeadcount - oldHeadcount;
          if (delta != 0) counts[newStatus.toLowerCase()] = FieldValue.increment(delta);
        } else {
          if (previousStatus == 'Yes' || previousStatus == 'Maybe' || previousStatus == 'No') {
            counts[previousStatus!.toLowerCase()] = FieldValue.increment(-oldHeadcount);
          }
          counts[newStatus.toLowerCase()] = FieldValue.increment(newHeadcount);
        }
        if (counts.isNotEmpty) tx.update(eventRef, counts);
      });

      final guestName = user.displayName ?? user.email?.split('@').first ?? 'A guest';
      _notifyHost('New RSVP', '$guestName just RSVPd $newStatus to $eventTitle');
      if (mounted) {
        var msg = newStatus == 'Yes' ? '🎉 RSVP saved — see you there!' : newStatus == 'Maybe' ? '🤔 RSVP saved — hopefully you can make it!' : '😢 RSVP saved — you\'ll be missed!';
        if (_allowPlusOnes && _supportsPlusOnesType && plusOnes > 0 && (newStatus == 'Yes' || newStatus == 'Maybe')) {
          msg = '$msg (+$plusOnes plus ${plusOnes == 1 ? 'one' : 'ones'})';
        }
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: AppColors.green));
        if (switchTab && listType == 'Checklist' && (newStatus == 'Yes' || newStatus == 'Maybe')) {
          // Checklist-only events nudge the guest into the Checklist
          // tab to pick what they're bringing — preserve that flow
          // and skip the auto-dismiss in this case.
          _tabController.animateTo(1);
        } else {
          // Auto-dismiss after the snackbar's read window so the guest
          // lands back on whichever screen they came from. Skipped on
          // root-route entries (deep link / web) where canPop is false.
          Future.delayed(const Duration(seconds: 2), () {
            if (!mounted) return;
            if (Navigator.canPop(context)) Navigator.of(context).pop();
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save RSVP: $e'), backgroundColor: Colors.redAccent),
        );
      }
    } finally {
      if (mounted) setState(() => _savingRsvp = false);
    }
  }

  void _initEventData() {
    final data = widget.eventData;
    if (data != null) {
      _populateFromEventData(data);
      return;
    }
    if (widget.isOnboarding) {
      // Onboarding demo — fully synthetic event so the welcome flow
      // has something to render without requiring a real Firestore
      // doc. Only fires on the demo path; every other caller that
      // lands here without eventData hits the Firestore fetch below.
      eventTitle = "Sarah's Birthday Bash";
      eventDate = "April 25, 2026 · 6:30 PM";
      eventLocation = "123 Celebration Lane, Seaside, CA";
      eventEmoji = "🎂";
      eventColor = const Color(0xFFE91E8C);
      eventHasEnded = false;
      listType = 'Wishlist';
      wishlistItems = [
        {'name': 'Wireless Earbuds', 'price': 129.99, 'contributed': 45.0, 'bought': false},
        {'name': 'Gift Card - Amazon', 'price': 100.0, 'contributed': 100.0, 'bought': true},
        {'name': 'Party Decorations', 'price': 75.0, 'contributed': 0.0, 'bought': false},
      ];
      return;
    }
    // No eventData, not onboarding — caller passed only eventId.
    // Set safe empty defaults so the late-final fields are
    // initialized, then fetch the real doc by id and re-render. We
    // start with `listType = 'No List'` (2 tabs total) and let
    // [_loadEventDocFromFirestore] grow the TabController if needed.
    eventTitle = '';
    eventDate = '';
    eventLocation = '';
    eventEmoji = '🎉';
    eventColor = const Color(0xFF9C7FD4);
    eventHasEnded = false;
    listType = 'No List';
    wishlistItems = [];
    if (widget.eventId != null) {
      // Defer until after the synchronous initState chain finishes
      // — the TabController is created immediately after this call,
      // so kick the fetch onto the next frame to avoid racing it.
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadEventDocFromFirestore());
    }
  }

  /// Hydrates every field that [_initEventData] would normally read
  /// from `widget.eventData`. Extracted so both the constructor-data
  /// path and the lazy Firestore fetch share the same parser.
  void _populateFromEventData(Map<String, dynamic> data) {
    eventTitle = (data['title'] as String?) ?? 'Event';
    eventEmoji = (data['eventEmoji'] as String?) ?? '🎉';
    eventLocation = (data['location'] as String?) ?? 'Location TBD';
    _eventDescription = (data['description'] as String?)?.trim() ?? '';

    final ts = data['date'];
    if (ts is Timestamp) {
      final dt = ts.toDate();
      const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
      final timeStr = (data['time'] as String?) ?? '';
      String formattedTime = '';
      if (timeStr.isNotEmpty) {
        final parts = timeStr.split(':');
        final hour = int.tryParse(parts[0]) ?? 0;
        final minute = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;
        final period = hour >= 12 ? 'PM' : 'AM';
        final h12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
        formattedTime = ' · $h12:${minute.toString().padLeft(2, '0')} $period';
      }
      eventDate = '${months[dt.month - 1]} ${dt.day}, ${dt.year}$formattedTime';
    } else {
      eventDate = 'Date TBD';
    }

    final eventTs = data['date'];
    if (eventTs is Timestamp) {
      eventHasEnded = DateTime.now().isAfter(eventTs.toDate());
    } else {
      eventHasEnded = false;
    }
    debugPrint('[GuestEventScreen] title="$eventTitle" eventHasEnded=$eventHasEnded');
    _isArchived = (data['isArchived'] as bool?) ?? false;
    _isOutdoor  = (data['isOutdoor']  as bool?) ?? false;
    final hostId = data['hostId'] as String?;
    _hostId = hostId;
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    _isHost = hostId != null && hostId == currentUid;
    final coHosts = List<String>.from((data['coHosts'] as List<dynamic>?) ?? []);
    _isCoHost = !_isHost && currentUid != null && coHosts.contains(currentUid);

    final deadlineTs = data['rsvpDeadline'] as Timestamp?;
    if (deadlineTs != null) {
      final deadline = deadlineTs.toDate();
      _rsvpClosed = DateTime.now().isAfter(deadline);
      const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
      _rsvpDeadlineLabel = '${months[deadline.month - 1]} ${deadline.day}, ${deadline.year}';
    }

    // Normalize capacity at hydration — treat null, 0, and any
    // non-positive value as "no cap set". Without this, a stale doc
    // carrying `capacity: 0` would make isFull true on first render
    // and surface the "Event is full · Join Waitlist" UI to every
    // guest before they've even had a chance to RSVP.
    final rawCapacity = (data['capacity'] as num?)?.toInt();
    _capacity = (rawCapacity != null && rawCapacity > 0) ? rawCapacity : null;
    _allowWaitlist = (data['allowWaitlist'] as bool?) ?? false;
    _allowPlusOnes = (data['allowPlusOnes'] as bool?) ?? false;
    _maxPlusOnes = (data['maxPlusOnes'] as num?)?.toInt();

    final typeName = (data['eventType'] as String?) ?? '';
    _eventTypeName = typeName;
    final matchedType = eventTypes.firstWhere((t) => t.name == typeName, orElse: () => eventTypes.last);
    eventColor = matchedType.primary;

    listType = (data['listType'] as String?) ?? 'Wishlist';

    // Parse every field on every item regardless of listType. Both
    // mode mixes wishlist + checklist items in the same array, so
    // narrowing the parsed shape based on listType silently drops
    // the other kind's fields (quantity for checklist items in a
    // Wishlist/Both event, price for wishlist items in a Checklist
    // event). The downstream tabs gate on `_itemKind(item)` which
    // reads the stored `kind` field — so preserving it here is
    // load-bearing for the checklist tab to find its items.
    // External gift-registry URLs (top-level `registryLinks` array on
    // the event doc, written by edit/create event screens). Defensive
    // whereType<String> drops malformed entries; clear() guards against
    // stale state when the screen rehydrates after an edit.
    final rawRegistry = data['registryLinks'] as List<dynamic>? ?? [];
    _registryLinks
      ..clear()
      ..addAll(rawRegistry.whereType<String>());

    final rawWishlist = data['wishlist'] as List<dynamic>? ?? [];
    wishlistItems = rawWishlist.map((item) {
      final m = item as Map<String, dynamic>;
      final rawClaims = m['claims'] as List<dynamic>? ?? [];
      return <String, dynamic>{
        'name': m['name'] as String? ?? '',
        'kind': m['kind'] as String?,
        // Wishlist fields
        'price': (m['price'] as num?)?.toDouble() ?? 0.0,
        'contributed': (m['contributed'] as num?)?.toDouble() ?? 0.0,
        'bought': m['bought'] as bool? ?? false,
        // Buyer info stamped by the "Buy & Bring" flow — `{uid,
        // name}`. Distinct from the legacy/cart-based bought flag,
        // which clears `contributed` to price without recording who.
        // Presence of boughtBy flips the badge from "Bought ✓" to
        // "Buying it 🛍️" so the host can see who's handling it.
        if (m['boughtBy'] is Map) 'boughtBy': Map<String, dynamic>.from(m['boughtBy'] as Map),
        // Checklist fields
        'quantity': m['quantity']?.toString() ?? '',
        if (m['unlimited'] == true) 'unlimited': true,
        'claimed': (m['claimed'] as num?)?.toInt() ?? 0,
        'claims': rawClaims.map((c) => Map<String, dynamic>.from(c as Map)).toList(),
        if (m['imageUrl'] is String) 'imageUrl': m['imageUrl'],
        if (m['url'] is String) 'url': m['url'],
      };
    }).toList();
  }

  /// One-shot Firestore fetch for callers that pushed the screen with
  /// only an eventId (deep links, push notifications, business feed
  /// Edit button). On success, hydrates the same fields the
  /// constructor-data path sets, then resizes the TabController if
  /// the resolved listType implies a different tab count.
  Future<void> _loadEventDocFromFirestore() async {
    final id = widget.eventId;
    if (id == null) return;
    try {
      final snap = await FirebaseFirestore.instance.collection('events').doc(id).get();
      if (!mounted) return;
      final data = snap.data();
      if (data == null) {
        debugPrint('[GuestEventScreen] event $id does not exist');
        return;
      }
      final beforeWishlist = _hasWishlist;
      final beforeChecklist = _hasChecklist;
      setState(() => _populateFromEventData(data));
      // TabController length is fixed at construction. If the live
      // listType implies a different tab count than our loading-state
      // default ('No List' → 2 tabs), swap the controller now.
      if (_hasWishlist != beforeWishlist || _hasChecklist != beforeChecklist) {
        _tabController.removeListener(_onTabChanged);
        _tabController.dispose();
        final listTabs = (_hasWishlist ? 1 : 0) + (_hasChecklist ? 1 : 0);
        if (mounted) {
          setState(() {
            _tabController = TabController(length: 2 + listTabs, vsync: this)
              ..addListener(_onTabChanged);
          });
        }
      }
    } catch (e) {
      debugPrint('[GuestEventScreen] event doc fetch failed: $e');
    }
  }

  @override
  void dispose() {
    _rsvpsSub?.cancel();
    _waitlistSub?.cancel();
    _contribSub?.cancel();
    _tabController.dispose();
    _welcomeCtrl.dispose();
    _plusOnesController.dispose();
    _claimManualCtrl.dispose();
    if (widget.isOnboarding) _completeOnboarding();
    super.dispose();
  }

  Future<void> _dismissWelcome() async {
    await _welcomeCtrl.reverse();
    if (mounted) setState(() => _showWelcome = false);
  }

  Widget _buildWelcomeOverlay() {
    return FadeTransition(
      opacity: _welcomeAnim,
      child: Container(
        color: _bg.withValues(alpha: 0.95),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('🎉', style: TextStyle(fontSize: 60)),
                  const SizedBox(height: 20),
                  Text(
                    'Welcome to QR Party!',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'FredokaOne',
                      fontSize: 32,
                      color: _isDark ? Colors.white : AppColors.dark,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'This is a live demo event — explore it, then create your own!',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 16,
                      color: _isDark ? const Color(0xFFB8A9D9) : AppColors.muted,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 36),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: _dismissWelcome,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _purple,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 0,
                      ),
                      child: const Text(
                        "Let's Go! 🎉",
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _uploadPhoto() {
    setState(() => uploadedPhotos.add('https://picsum.photos/id/${400 + uploadedPhotos.length}/300/300'));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('📸 Photo added to the wall!'), backgroundColor: AppColors.green));
  }

  void _toggleBuy(int index) {
    final name = wishlistItems[index]['name'] as String;
    final price = wishlistItems[index]['price'] as double;
    setState(() {
      wishlistItems[index]['bought'] = !(wishlistItems[index]['bought'] as bool);
      if (wishlistItems[index]['bought'] as bool) {
        _cart.removeWhere((c) => c['name'] == name);
        _cart.add({'name': name, 'type': 'buy', 'amount': price});
      } else {
        wishlistItems[index]['contributed'] = 0.0;
        _cart.removeWhere((c) => c['name'] == name);
      }
    });
  }

  /// "Buy & Bring" flow — distinct from the cart/Stripe `_toggleBuy`
  /// path that's gated behind kTestingMode. Opens the item's external
  /// retailer URL (if any) so the guest can purchase it directly,
  /// then asks "Did you buy it?" via a confirmation dialog. On
  /// confirm, the item is marked bought + contributed=price and the
  /// buyer's uid+name is stamped under `boughtBy`. Other guests see
  /// the "Buying it 🛍️" badge and contribute buttons disappear so
  /// nobody double-buys.
  Future<void> _buyAndBring(int itemIdx) async {
    final item = wishlistItems[itemIdx];
    final url = (item['url'] as String?) ?? '';
    final name = (item['name'] as String?) ?? 'this item';

    // 1. Open the URL if present so the guest can complete the
    //    purchase on the retailer's site/app. We don't block the
    //    confirmation dialog on launchUrl success — even if the
    //    launch failed, the guest may already have bought via
    //    another channel and just want to mark it.
    if (url.isNotEmpty) {
      final uri = Uri.tryParse(url);
      if (uri != null) {
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (e) {
          debugPrint('[BuyAndBring] launchUrl failed for $url: $e');
        }
      }
    }
    if (!mounted) return;

    // 2. Confirmation dialog. The guest may have just opened the
    //    retailer page and not actually committed yet — "Not yet"
    //    leaves the item open so they (or someone else) can claim
    //    it later.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Got it covered?',
          style: TextStyle(
            fontFamily: 'FredokaOne', fontSize: 18,
            color: _isDark ? Colors.white : AppColors.dark,
          ),
        ),
        content: Text(
          url.isEmpty
              ? 'Marking "$name" as taken care of lets the host know. Other guests won\'t be able to contribute toward it after — you can undo from the item card.'
              : 'If you\'re bringing "$name", we\'ll mark it as taken care of and let the host know. Other guests won\'t be able to contribute toward it after — you can undo from the item card.',
          style: TextStyle(fontFamily: 'Nunito', color: _muted, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Not yet', style: TextStyle(color: _muted, fontWeight: FontWeight.w700)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.purple,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
            child: const Text("Yes, I'll bring it", style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // 3. Stamp the buyer + flip bought+contributed via a transaction
    //    against the master wishlist array. Mirrors the read-modify-
    //    write pattern used by _saveClaimToFirestore.
    await _markBoughtViaBuyBring(itemIdx);
  }

  Future<void> _markBoughtViaBuyBring(int itemIdx) async {
    if (widget.eventId == null) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final price = (wishlistItems[itemIdx]['price'] as num?)?.toDouble() ?? 0.0;
    final buyerName = user.displayName ?? 'Guest';
    final boughtBy = <String, dynamic>{'uid': user.uid, 'name': buyerName};
    final eventRef = FirebaseFirestore.instance.collection('events').doc(widget.eventId);

    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(eventRef);
        final rawWishlist = List<Map<String, dynamic>>.from(
          (snap.data()?['wishlist'] as List<dynamic>? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
        );
        if (itemIdx >= rawWishlist.length) return;
        rawWishlist[itemIdx]['bought'] = true;
        rawWishlist[itemIdx]['contributed'] = price;
        rawWishlist[itemIdx]['boughtBy'] = boughtBy;
        tx.update(eventRef, {'wishlist': rawWishlist});
      });

      if (mounted) {
        setState(() {
          wishlistItems[itemIdx]['bought'] = true;
          wishlistItems[itemIdx]['contributed'] = price;
          wishlistItems[itemIdx]['boughtBy'] = boughtBy;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('You\'re bringing "${wishlistItems[itemIdx]['name']}" 🛍️'),
          backgroundColor: AppColors.purple,
        ));
      }
      // Notify the host that a guest claimed an item via Buy & Bring.
      // Fired only on the success path so a failed transaction (caught
      // below) doesn't trigger a phantom push. Same guest-name pattern
      // as the RSVP notification — falls through to email-local-part
      // and then "A guest" when displayName is empty.
      final guestName = user.displayName ?? user.email?.split('@').first ?? 'A guest';
      final itemName = (wishlistItems[itemIdx]['name'] as String?) ?? 'an item';
      _notifyHost(
        'Item Claimed 🎉',
        '$guestName is bringing $itemName to $eventTitle',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not save: $e'),
          backgroundColor: Colors.redAccent,
        ));
      }
    }
  }

  /// Reverses a "Bring It" claim that the current user made earlier
  /// — clears `bought`, zeroes `contributed`, and removes the
  /// `boughtBy` stamp so the item returns to its open state and the
  /// contribute / Bring It buttons reappear for everyone (including
  /// the original claimer who can re-claim later). The undo button
  /// only surfaces on the wishlist item card when
  /// `boughtBy.uid == current user`, so this should never be called
  /// against someone else's claim, but the transaction re-checks the
  /// uid on the server too as a defensive guard.
  Future<void> _undoBuyAndBring(int itemIdx) async {
    if (widget.eventId == null) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final eventRef = FirebaseFirestore.instance.collection('events').doc(widget.eventId);
    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(eventRef);
        final rawWishlist = List<Map<String, dynamic>>.from(
          (snap.data()?['wishlist'] as List<dynamic>? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
        );
        if (itemIdx >= rawWishlist.length) return;
        final by = rawWishlist[itemIdx]['boughtBy'];
        // Server-side guard — only undo when the current user is the
        // recorded buyer. Prevents a stale UI tap from clobbering
        // someone else's claim if the snapshot listener dropped a
        // beat.
        if (by is! Map || by['uid'] != user.uid) return;
        rawWishlist[itemIdx]['bought'] = false;
        rawWishlist[itemIdx]['contributed'] = 0.0;
        rawWishlist[itemIdx].remove('boughtBy');
        tx.update(eventRef, {'wishlist': rawWishlist});
      });
      if (mounted) {
        setState(() {
          wishlistItems[itemIdx]['bought'] = false;
          wishlistItems[itemIdx]['contributed'] = 0.0;
          wishlistItems[itemIdx].remove('boughtBy');
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not undo: $e'),
          backgroundColor: Colors.redAccent,
        ));
      }
    }
  }


  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Scaffold(
      backgroundColor: _bg,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: _card,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: _isDark ? Colors.white : AppColors.dark),
        // Emoji-only AppBar title — event name removed per the
        // "drop banner text" cleanup. The colored emoji tile is
        // enough visual identity at the top; the screen's tabs
        // (Info & RSVP / Wishlist / Checklist / Photos) carry the
        // contextual orientation. If the user needs the full event
        // name, it's still shown prominently inside the Info tab.
        title: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: eventColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
            child: Center(child: Text(eventEmoji, style: const TextStyle(fontSize: 20))),
          ),
        ]),
        actions: (_isHost || _isCoHost) ? [
          Padding(
            padding: const EdgeInsets.only(right: 12, top: 8, bottom: 8),
            child: GestureDetector(
              onTap: () => setState(() => _isHostMode = !_isHostMode),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                decoration: BoxDecoration(
                  color: _isHostMode ? AppColors.green : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _isHostMode ? AppColors.green : Colors.grey.shade300),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.manage_accounts_outlined, size: 14, color: _isHostMode ? Colors.white : _muted),
                  const SizedBox(width: 5),
                  Text('Host View', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _isHostMode ? Colors.white : _muted)),
                ]),
              ),
            ),
          ),
        ] : null,
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.green,
          unselectedLabelColor: _muted,
          indicatorColor: AppColors.green,
          indicatorWeight: 2.5,
          // 13px (was 14) so all four labels fit on narrow phones
          // without ellipsis when Both-mode is active. The 4-tab
          // layout (Info / Wishlist / Checklist / Photos) was tight
          // at 14px on iPhone SE-class widths.
          labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          // Shortened from "Info & RSVP" — that label was being
          // truncated to "Info & RSV" on Both-mode events. The tab
          // body still includes RSVP controls, weather, host
          // announcements, etc.; "Info" is the broader umbrella.
          tabs: [
            const Tab(text: 'Info'),
            // Per-list tabs, in a stable order regardless of which
            // are active: Wishlist comes before Checklist in Both
            // mode. The TabBarView children list below mirrors this
            // ordering so the controller's index points at the right
            // body for the visible tab.
            if (_hasWishlist) const Tab(text: 'Wishlist'),
            if (_hasChecklist) const Tab(text: 'Checklist'),
            const Tab(text: 'Photos'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildInfoTab(),
          if (_hasWishlist) _buildWishlistTab(),
          if (_hasChecklist) _buildChecklistTab(),
          _buildPhotosTab(),
        ],
      ),
      bottomNavigationBar: widget.isOnboarding
          ? _buildOnboardingBanner()
          : (_showDoneBanner ? _buildDoneBanner() : debugLabel('Screen 10 — Guest View')),
        ),
        if (_showWelcome) _buildWelcomeOverlay(),
      ],
    );
  }

  Widget _buildDoneBanner() {
    return Container(
      decoration: BoxDecoration(
        color: _card,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 16, offset: const Offset(0, -4))],
      ),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 16 + MediaQuery.of(context).padding.bottom),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: () {
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (_) => const HomeFeedScreen()),
              (_) => false,
            );
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.gold,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: const Text('All Set 🎉',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
        ),
      ),
    );
  }

  Widget _buildOnboardingBanner() {
    return Container(
      decoration: BoxDecoration(
        color: _card,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 16, offset: const Offset(0, -4))],
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36, height: 4,
            decoration: BoxDecoration(color: AppColors.greenPale, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 14),
          Text(
            'Welcome to QR Party! 🎉',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark),
          ),
          const SizedBox(height: 6),
          Text(
            "This is a live demo — explore all the features as a guest. When you're ready, tap below to get started.",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: _muted, height: 1.5),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _completeOnboarding,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.purple,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: const Text("Let's Go! 🎉", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _completeOnboarding() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({'hasCompletedOnboarding': true});
    }
    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const HomeFeedScreen()),
        (_) => false,
      );
    }
  }

  Widget _buildInfoTab() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(eventTitle, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: _isDark ? Colors.white : AppColors.dark, letterSpacing: -0.5)),
                const SizedBox(height: 16),
                // Date and location in clean rows
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(16), border: Border.all(color: _border)),
                  child: Column(
                    children: [
                      Row(children: [
                        Container(width: 36, height: 36, decoration: BoxDecoration(color: eventColor.withOpacity(0.1), borderRadius: BorderRadius.circular(10)), child: Icon(Icons.calendar_today_outlined, size: 16, color: eventColor)),
                        const SizedBox(width: 12),
                        Text(eventDate, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: _isDark ? Colors.white : AppColors.dark)),
                      ]),
                      const SizedBox(height: 12),
                      const Divider(height: 1),
                      const SizedBox(height: 12),
                      Row(children: [
                        Container(width: 36, height: 36, decoration: BoxDecoration(color: eventColor.withOpacity(0.1), borderRadius: BorderRadius.circular(10)), child: Icon(Icons.location_on_outlined, size: 16, color: eventColor)),
                        const SizedBox(width: 12),
                        Expanded(child: Text(eventLocation, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: _isDark ? Colors.white : AppColors.dark))),
                        GestureDetector(
                          onTap: () async {
                            final encoded = Uri.encodeComponent(eventLocation);
                            final uri = Uri.parse('https://maps.google.com/?q=$encoded');
                            if (await canLaunchUrl(uri)) {
                              await launchUrl(uri, mode: LaunchMode.externalApplication);
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(color: eventColor, borderRadius: BorderRadius.circular(10)),
                            child: const Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.directions, size: 14, color: Colors.white),
                              SizedBox(width: 4),
                              Text('Go', style: TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
                            ]),
                          ),
                        ),
                      ]),
                      if (_eventDescription.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        const Divider(height: 1),
                        const SizedBox(height: 12),
                        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Container(
                            width: 36, height: 36,
                            decoration: BoxDecoration(color: eventColor.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
                            child: Icon(Icons.notes_outlined, size: 16, color: eventColor),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                _eventDescription,
                                style: TextStyle(fontSize: 14, height: 1.45, color: _muted),
                              ),
                            ),
                          ),
                        ]),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // Registry section — host-attached external gift
                // registry URLs (Zola, Amazon, Babylist, etc.). Self-
                // hides when the host hasn't added any links, so
                // events without registries get no extra chrome.
                // Sits above the weather + RSVP block so guests see
                // it as part of the event-info cluster, not buried
                // below the action area.
                if (_registryLinks.isNotEmpty) ...[
                  _buildRegistrySection(),
                  const SizedBox(height: 16),
                ],
                // Weather widget — gated to outdoor events only. The
                // host opts in via the "Outdoor event" toggle on
                // create / edit; indoor events get nothing here so
                // the forecast pill doesn't surface where it's
                // irrelevant. _buildWeatherWidget itself still
                // self-hides when geocoding failed or the event is
                // >7 days out — this gate is the host-controlled
                // outer switch.
                if (_isOutdoor) ...[
                  _buildWeatherWidget(),
                  if (_weatherLoading || _weatherData != null) const SizedBox(height: 16),
                ],
                // RSVP counts as a single row of stat boxes. Hosts/co-hosts can
                // tap Yes / Maybe to see an adults+children breakdown; the No
                // tile and all tiles for regular guests render as plain text.
                // Counts are total people (adults + children + plus-ones),
                // not RSVP doc count. .length would show 1 when a single
                // guest RSVPs with a family of 4 — _peopleFor sums the
                // three count fields stamped on each rsvps doc.
                Row(children: [
                  _statBox(
                    '${_peopleFor('Yes')}',
                    'Going',
                    AppColors.green,
                    onTap: (_isHost || _isCoHost) ? () => _showRsvpBreakdown('Yes') : null,
                  ),
                  const SizedBox(width: 8),
                  _statBox(
                    '${_peopleFor('Maybe')}',
                    'Maybe',
                    AppColors.gold,
                    onTap: (_isHost || _isCoHost) ? () => _showRsvpBreakdown('Maybe') : null,
                  ),
                  const SizedBox(width: 8),
                  _statBox('${_peopleFor('No')}', "Can't go", Colors.redAccent),
                ]),
                if ((_isHost || _isCoHost) && _waitlist.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: _showWaitlistSheet,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: _purple.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _purple.withValues(alpha: 0.4)),
                      ),
                      child: Row(children: [
                        const Icon(Icons.hourglass_bottom, size: 18, color: _purple),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '${_waitlist.length} on waitlist · Tap to view',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _purple),
                          ),
                        ),
                        const Icon(Icons.chevron_right, size: 18, color: _purple),
                      ]),
                    ),
                  ),
                ],
                if (_rsvps.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _buildGuestAvatarRow(),
                ],
                const SizedBox(height: 20),
                // RSVP section
                if (_isArchived)
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: _card,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: _border),
                    ),
                    child: Row(children: [
                      Container(
                        width: 44, height: 44,
                        decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
                        child: const Icon(Icons.celebration_outlined, color: AppColors.purple, size: 22),
                      ),
                      const SizedBox(width: 14),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('This event has ended', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
                        Text('Thanks for being part of it!', style: TextStyle(fontSize: 13, color: _muted)),
                      ])),
                    ]),
                  )
                else if (_rsvpClosed)
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: _card,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: _border),
                    ),
                    child: Row(children: [
                      Container(
                        width: 44, height: 44,
                        decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(12)),
                        child: const Icon(Icons.lock_clock, color: AppColors.muted, size: 22),
                      ),
                      const SizedBox(width: 14),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('RSVPs are now closed', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
                        if (_rsvpDeadlineLabel.isNotEmpty)
                          Text('Deadline was $_rsvpDeadlineLabel', style: TextStyle(fontSize: 13, color: _muted)),
                      ])),
                    ]),
                  )
                else
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: _card,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: _border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          Expanded(
                            child: Text('Will you attend?', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
                          ),
                          // The deadline banner used to live here next to
                          // the title; pairing it with the Add-to-Calendar
                          // pill on the same line caused a 54px overflow on
                          // narrow phones once the deadline was set. The
                          // banner now renders below the Yes/Maybe/No
                          // chips (see _rsvpDeadlineLabel block further
                          // down) so the header stays single-line.
                          if (rsvpStatus == 'Yes')
                            GestureDetector(
                              onTap: _addToCalendar,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(color: AppColors.dark, borderRadius: BorderRadius.circular(10)),
                                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                                  Icon(Icons.calendar_month_outlined, size: 12, color: Colors.white),
                                  SizedBox(width: 4),
                                  Text('Add to Calendar', style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
                                ]),
                              ),
                            ),
                        ]),
                        const SizedBox(height: 14),
                        Builder(builder: (_) {
                          final yesHeadcount = _rsvps
                              .where((g) => g['status'] == 'Yes')
                              .fold<int>(0, (sum, g) => sum + ((g['adults'] as int? ?? 1) + (g['children'] as int? ?? 0) + (g['plusOnes'] as int? ?? 0)));
                          final cap = _capacity;
                          // Belt-and-suspenders: even though the hydration
                          // path normalizes 0/negative caps to null, also
                          // guard `cap > 0` here so any future code path
                          // that bypasses _initEventData can't silently
                          // mark every event as full.
                          final isFull = cap != null && cap > 0 && yesHeadcount >= cap && rsvpStatus != 'Yes';
                          final uid = FirebaseAuth.instance.currentUser?.uid;
                          final onWaitlist = uid != null && _waitlist.any((w) => w['uid'] == uid);
                          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            Row(children: [
                              Expanded(child: _rsvpButton('Yes', AppColors.green, disabled: isFull)),
                              const SizedBox(width: 10),
                              Expanded(child: _rsvpButton('Maybe', AppColors.gold)),
                              const SizedBox(width: 10),
                              Expanded(child: _rsvpButton('No', Colors.redAccent)),
                            ]),
                            // Deadline banner — moved here from the
                            // header row to keep the title line single-
                            // line. Centered below the chips so it reads
                            // as a soft reminder rather than competing
                            // with the title.
                            if (_rsvpDeadlineLabel.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(color: const Color(0xFFFFF8E1), borderRadius: BorderRadius.circular(20)),
                                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                                    const Icon(Icons.schedule, size: 12, color: AppColors.gold),
                                    const SizedBox(width: 4),
                                    Text('RSVP by $_rsvpDeadlineLabel', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.gold)),
                                  ]),
                                ),
                              ),
                            ],
                            if (isFull) ...[
                              const SizedBox(height: 12),
                              Row(children: [
                                const Icon(Icons.error_outline, size: 16, color: Colors.redAccent),
                                const SizedBox(width: 6),
                                Text('Event is full', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.redAccent)),
                              ]),
                              if (_allowWaitlist && !_isHost && !_isCoHost) ...[
                                const SizedBox(height: 10),
                                SizedBox(
                                  width: double.infinity,
                                  height: 46,
                                  child: ElevatedButton.icon(
                                    onPressed: _joiningWaitlist
                                        ? null
                                        : (onWaitlist ? _leaveWaitlist : _joinWaitlist),
                                    icon: Icon(onWaitlist ? Icons.check_circle_outline : Icons.hourglass_bottom, size: 18),
                                    label: _joiningWaitlist
                                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                        : Text(onWaitlist ? "You're on the waitlist · Tap to leave" : 'Join Waitlist',
                                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _purple,
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ]);
                        }),
                        if (_pendingStatus == 'Yes' || _pendingStatus == 'Maybe') ...[
                          const SizedBox(height: 16),
                          const Divider(),
                          const SizedBox(height: 12),
                          Text('How many guests?', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : AppColors.dark)),
                          const SizedBox(height: 8),
                          Row(children: [
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('Adults', style: TextStyle(fontSize: 13, color: _muted)),
                              DropdownButton<int>(
                                value: adults,
                                underline: const SizedBox(),
                                items: List.generate(6, (i) => DropdownMenuItem(value: i + 1, child: Text('${i + 1}'))),
                                onChanged: (v) => setState(() => adults = v!),
                              ),
                            ])),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('Children', style: TextStyle(fontSize: 13, color: _muted)),
                              DropdownButton<int>(
                                value: children,
                                underline: const SizedBox(),
                                items: List.generate(5, (i) => DropdownMenuItem(value: i, child: Text('$i'))),
                                onChanged: (v) => setState(() => children = v!),
                              ),
                            ])),
                          ]),
                          // Gate plus-ones to events that BOTH have the host
                          // toggle on AND are Corporate or Wedding type.
                          // Public events (no event type) and every other
                          // type (Birthday, Graduation, Holiday, etc.) hide
                          // the selector regardless of the saved flag.
                          if (_allowPlusOnes && _supportsPlusOnesType) ...[
                            const SizedBox(height: 4),
                            Row(children: [
                              Icon(Icons.person_add_alt, size: 16, color: _purple),
                              const SizedBox(width: 6),
                              Text('Plus ones', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : AppColors.dark)),
                              const SizedBox(width: 8),
                              if (_maxPlusOnes != null)
                                Text('(max $_maxPlusOnes)', style: TextStyle(fontSize: 11, color: _muted)),
                            ]),
                            const SizedBox(height: 6),
                            if (_maxPlusOnes != null)
                              DropdownButton<int>(
                                value: plusOnes.clamp(0, _maxPlusOnes!),
                                underline: const SizedBox(),
                                items: List.generate(_maxPlusOnes! + 1, (i) => DropdownMenuItem(value: i, child: Text('$i'))),
                                onChanged: (v) => setState(() => plusOnes = v!),
                              )
                            else
                              SizedBox(
                                width: 100,
                                child: TextField(
                                  controller: _plusOnesController,
                                  keyboardType: TextInputType.number,
                                  style: TextStyle(color: _isDark ? Colors.white : AppColors.dark),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: _border)),
                                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: _border)),
                                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: _purple, width: 1.5)),
                                  ),
                                  onChanged: (v) => setState(() => plusOnes = int.tryParse(v) ?? 0),
                                ),
                              ),
                          ],
                        ],
                        if (_pendingStatus != 'Not Responded') ...[
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            height: 50,
                            child: ElevatedButton(
                              onPressed: _savingRsvp ? null : () => _saveRsvp(_pendingStatus, switchTab: true),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.green,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: _savingRsvp
                                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                  : const Text('Confirm RSVP', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                if (rsvpStatus != 'No' && rsvpStatus != 'Not Responded') ...[
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final u = FirebaseAuth.instance.currentUser;
                      final name = u?.displayName ?? u?.email?.split('@').first ?? 'A guest';
                      await _notifyHost('Running Late', '$name is running late to $eventTitle');
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Running Late notification sent to host!'), backgroundColor: AppColors.gold),
                        );
                      }
                    },
                    icon: const Icon(Icons.directions_run, color: AppColors.gold, size: 18),
                    label: const Text("I'm Running Late", style: TextStyle(color: AppColors.gold, fontWeight: FontWeight.w600, fontSize: 14)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.gold, width: 1.5),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      minimumSize: const Size(double.infinity, 0),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                // Host announcements. The header doubles as a tap
                // target for hosts/co-hosts, opening the announcement
                // composer (HostNotificationsScreen) — previously the
                // section was inert chrome with no way for a host to
                // edit / send a new one without leaving this screen.
                Row(children: [
                  Expanded(
                    child: Text('Announcements',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700,
                            color: _isDark ? Colors.white : AppColors.dark)),
                  ),
                  if (_isHost || _isCoHost)
                    TextButton.icon(
                      onPressed: () => Navigator.push(context, MaterialPageRoute(
                        builder: (_) => const HostNotificationsScreen(),
                      )),
                      icon: const Icon(Icons.edit_outlined, size: 16, color: AppColors.purple),
                      label: const Text('Manage',
                          style: TextStyle(color: AppColors.purple, fontSize: 13, fontWeight: FontWeight.w800)),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                ]),
                const SizedBox(height: 10),
                // No announcements pipeline reads back into this
                // screen yet — host-sent announcements go out via push
                // / email through HostNotificationsScreen and aren't
                // mirrored to a per-event subcollection. Until that
                // pipeline exists, render an empty state rather than
                // the previous hardcoded placeholders, which made it
                // look like every event had two phantom announcements.
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                  decoration: BoxDecoration(
                    color: _card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _border),
                  ),
                  child: Row(children: [
                    Icon(Icons.campaign_outlined, size: 18, color: _muted),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        (_isHost || _isCoHost)
                            ? 'No announcements sent yet. Tap Manage to send one.'
                            : 'No announcements yet.',
                        style: TextStyle(fontSize: 13, color: _muted),
                      ),
                    ),
                  ]),
                ),
                if (_isHostMode) ...[
                  const SizedBox(height: 20),
                  _buildRunningLateButton(),
                  const SizedBox(height: 20),
                  _buildHostGuestList(),
                ],
                const SizedBox(height: 20),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Weather ──────────────────────────────────────────────────

  Future<void> _fetchWeather() async {
    // Pull event data from the constructor first; if the screen was
    // opened with only an eventId (deep link, push notification tap),
    // fall back to a one-shot Firestore read so the weather widget
    // still works on those entry paths. Without this fallback the
    // function early-returned and the widget stayed permanently blank.
    Map<String, dynamic>? data = widget.eventData;
    if (data == null && widget.eventId != null) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('events').doc(widget.eventId).get();
        data = snap.data();
      } catch (e) {
        debugPrint('[Weather] event doc fetch failed: $e');
      }
    }
    if (data == null) {
      debugPrint('[Weather] no event data — aborting');
      return;
    }
    final ts = data['date'];
    if (ts is! Timestamp) {
      debugPrint('[Weather] no date Timestamp — aborting');
      return;
    }

    final eventDay = () {
      final d = ts.toDate();
      return DateTime(d.year, d.month, d.day);
    }();
    final today = () {
      final n = DateTime.now();
      return DateTime(n.year, n.month, n.day);
    }();
    final daysUntil = eventDay.difference(today).inDays;
    if (daysUntil < 0 || daysUntil > 7) {
      debugPrint('[Weather] $daysUntil days out — outside 0..7 forecast window');
      return;
    }

    // Build candidate queries with state + country context up
    // front. Open-Meteo's geocoder is name-based and disambiguates
    // by population, so a bare "Seaside" picks Seaside, FL (more
    // populous) over Seaside, CA — wrong city, wildly wrong
    // weather. _parseLocation pulls out the state when present so
    // we can build "Seaside, California, US" as the highest-priority
    // query. The expectedState below is also used to FILTER the
    // multi-result response in the geocode loop, picking the
    // California row even if it wasn't first in the list.
    final loc = (data['location'] as String?)?.trim() ?? '';
    final zip = (data['zipCode'] as String?)?.trim() ?? '';
    final parsed = _parseLocation(loc);
    final expectedState = parsed.state; // e.g. "California"
    final city = parsed.city;
    final candidates = <String>[
      // Most specific first: city + canonical state name + country.
      if (city != null && expectedState != null)
        '$city, $expectedState, US',
      // City + state alone (no country) — covers cases where the
      // geocoder dislikes the trailing country.
      if (city != null && expectedState != null)
        '$city, $expectedState',
      // Zip + country — only resolves in some regions but cheap.
      if (zip.isNotEmpty) '$zip, US',
      // Bare city — last-resort name-only lookup; the admin1
      // filter in the loop below catches mis-disambiguation here.
      if (city != null) city,
      // Raw location string (trimmed) and bare zip as final
      // fallbacks for whatever shape an event might have.
      if (loc.isNotEmpty) loc,
      if (zip.isNotEmpty) zip,
    ].where((s) => s.isNotEmpty).toSet().toList();
    if (candidates.isEmpty) {
      debugPrint('[Weather] no usable location/zip on event — aborting');
      return;
    }
    debugPrint('[Weather] parsed location: city="$city" state="$expectedState"');
    debugPrint('[Weather] candidates (in order): $candidates');
    debugPrint('[Weather] event location raw="$loc" zip="$zip"');

    if (mounted) setState(() => _weatherLoading = true);
    try {
      double? lat;
      double? lon;
      String? matchedQuery;
      Map<String, dynamic>? geoTopResult;
      for (final query in candidates) {
        // Ask for up to 10 results so we can filter by admin1
        // when the geocoder's first pick disagrees with the parsed
        // state. With count=1 the API picks by population only,
        // which is exactly the failure mode that put Seaside, FL
        // ahead of Seaside, CA on a bare "Seaside" query.
        final geoUri = Uri.parse(
          'https://geocoding-api.open-meteo.com/v1/search'
          '?name=${Uri.encodeQueryComponent(query)}'
          '&count=10&language=en&format=json',
        );
        debugPrint('[Weather] geocode GET $geoUri');
        final geoRes = await http.get(geoUri).timeout(const Duration(seconds: 8));
        if (geoRes.statusCode != 200) {
          debugPrint('[Weather] geocode "$query" status=${geoRes.statusCode}');
          continue;
        }
        final bodyPreview = geoRes.body.length > 2000
            ? '${geoRes.body.substring(0, 2000)}…[+${geoRes.body.length - 2000}ch]'
            : geoRes.body;
        debugPrint('[Weather] geocode "$query" raw body: $bodyPreview');
        final geoJson = jsonDecode(geoRes.body) as Map<String, dynamic>;
        final results = (geoJson['results'] as List<dynamic>?)
            ?.cast<Map<String, dynamic>>();
        if (results == null || results.isEmpty) {
          debugPrint('[Weather] geocode "$query" no results — trying next candidate');
          continue;
        }

        // Picker: prefer the result whose admin1 matches the
        // parsed state. Match is case-insensitive substring so
        // "California" matches "California" and "California, USA"
        // (rare admin1 form) and the abbreviated "CA" (also rare).
        // Falls back to results[0] when no state was parsed or no
        // result matches it — same behaviour as before this fix
        // for inputs without state context.
        Map<String, dynamic> picked = results.first;
        if (expectedState != null) {
          final wantUpper = expectedState.toUpperCase();
          for (final r in results) {
            final admin1 = (r['admin1'] as String? ?? '').toUpperCase();
            if (admin1.contains(wantUpper)
                || admin1 == _resolveUsState(expectedState)?.toUpperCase()) {
              picked = r;
              break;
            }
          }
          if (picked == results.first
              && (picked['admin1'] as String? ?? '')
                      .toUpperCase()
                      .contains(wantUpper) ==
                  false) {
            debugPrint(
                '[Weather] no result matched admin1≈"$expectedState" — falling back to top');
          }
        }
        lat = (picked['latitude'] as num).toDouble();
        lon = (picked['longitude'] as num).toDouble();
        matchedQuery = query;
        geoTopResult = picked;
        debugPrint('[Weather] geocode "$query" results=${results.length} '
            'picked: name="${picked['name']}" '
            'admin1="${picked['admin1']}" '
            'admin2="${picked['admin2']}" '
            'country="${picked['country']}" '
            'lat=$lat lon=$lon '
            'population=${picked['population']} '
            'timezone=${picked['timezone']}');
        break;
      }
      if (lat == null || lon == null) {
        debugPrint('[Weather] all geocode candidates failed: $candidates');
        if (mounted) setState(() => _weatherLoading = false);
        return;
      }
      debugPrint('[Weather] geocoded "$matchedQuery" → lat=$lat lon=$lon '
          '(geoTopResult=$geoTopResult)');

      final dateStr =
          '${eventDay.year}-${eventDay.month.toString().padLeft(2, '0')}-${eventDay.day.toString().padLeft(2, '0')}';
      debugPrint('[Weather] event ts (UTC)=${ts.toDate().toUtc()} '
          'eventDay (local)=$eventDay '
          'today (local)=$today '
          'daysUntil=$daysUntil '
          'dateStr=$dateStr');

      final wxUri = Uri.parse(
        'https://api.open-meteo.com/v1/forecast'
        '?latitude=$lat&longitude=$lon'
        '&daily=weather_code,temperature_2m_max,temperature_2m_min'
        '&temperature_unit=fahrenheit&timezone=auto'
        '&start_date=$dateStr&end_date=$dateStr',
      );
      debugPrint('[Weather] forecast GET $wxUri');
      final wxRes = await http.get(wxUri).timeout(const Duration(seconds: 8));
      if (wxRes.statusCode != 200) {
        debugPrint('[Weather] forecast status=${wxRes.statusCode} body=${wxRes.body}');
        if (mounted) setState(() => _weatherLoading = false);
        return;
      }
      // Full forecast body so we can compare what open-meteo
      // returned against what we end up displaying. Particularly
      // important when start_date == end_date but the API decides
      // to honour the timezone shift and returns a different day.
      final bodyPreview = wxRes.body.length > 4000
          ? '${wxRes.body.substring(0, 4000)}…[+${wxRes.body.length - 4000}ch]'
          : wxRes.body;
      debugPrint('[Weather] forecast raw body: $bodyPreview');
      final wxJson = jsonDecode(wxRes.body) as Map<String, dynamic>;
      // Top-level timezone fields tell you which TZ the API used to
      // bucket the daily array — if it's a continent away from the
      // expected one, the temps might be reading tomorrow's forecast.
      debugPrint('[Weather] forecast meta: '
          'timezone=${wxJson['timezone']} '
          'timezone_abbreviation=${wxJson['timezone_abbreviation']} '
          'utc_offset_seconds=${wxJson['utc_offset_seconds']} '
          'elevation=${wxJson['elevation']}');
      final daily = wxJson['daily'] as Map<String, dynamic>?;
      if (daily == null) {
        debugPrint('[Weather] forecast had no `daily` block');
        if (mounted) setState(() => _weatherLoading = false);
        return;
      }

      final codes = daily['weather_code'] as List<dynamic>;
      final maxTemps = daily['temperature_2m_max'] as List<dynamic>;
      final minTemps = daily['temperature_2m_min'] as List<dynamic>;
      // Dump every day the API returned so we can verify we're
      // reading the right slot. With start_date == end_date, this
      // SHOULD be a single-day array, but if the request crossed a
      // TZ boundary it could include the day before or after.
      final times = daily['time'] as List<dynamic>?;
      debugPrint('[Weather] daily.time=$times '
          'codes=$codes '
          'maxTemps=$maxTemps '
          'minTemps=$minTemps');
      if (codes.isEmpty) {
        debugPrint('[Weather] daily.weather_code is empty array');
        if (mounted) setState(() => _weatherLoading = false);
        return;
      }

      final code = (codes[0] as num).toInt();
      debugPrint('[Weather] DISPLAY → date=${times != null && times.isNotEmpty ? times[0] : '?'} '
          'code=$code (${_wmoCondition(code)}) '
          'max=${maxTemps[0]}°F '
          'min=${minTemps[0]}°F');
      if (mounted) {
        setState(() {
          _weatherLoading = false;
          _weatherData = {
            'max': (maxTemps[0] as num).round(),
            'min': (minTemps[0] as num).round(),
            'condition': _wmoCondition(code),
            'icon': _wmoIcon(code),
          };
        });
      }
    } catch (e) {
      debugPrint('[Weather] fetch failed: $e');
      if (mounted) setState(() => _weatherLoading = false);
    }
  }

  /// Picks the most likely "city" segment out of a comma-delimited
  /// address. Google Places typically returns one of:
  ///   "City"                                 → use as-is
  ///   "City, State"                          → use first segment
  ///   "City, State, Country"                 → first segment
  ///   "Street, City, State, ZIP"             → 2nd segment (city)
  ///   "Street, City, State, ZIP, Country"    → 2nd segment (city)
  /// The previous heuristic always picked the second-to-last segment,
  /// which returned the *state* on 4-part addresses — the geocoder
  /// could resolve states but the lat/lon was hundreds of miles from
  /// the actual venue, hence "weather not updating" visually.
  /// Parses a free-form location string into (city, state) where
  /// state is the canonical full name ("California") when found, or
  /// null when no US state segment is recognizable. Used to enrich
  /// the open-meteo geocoder query with admin1 context, so a query
  /// for "Seaside" doesn't ambiguously match Seaside, Florida or
  /// Seaside, Oregon when the host actually meant Seaside, California.
  ///
  /// Strategy: split by comma, walk segments from the END finding
  /// the first one that matches a US state (full name OR two-letter
  /// abbreviation). The segment immediately before is the city. If
  /// no state segment matches, fall back to the single-/two-/three-
  /// part heuristics from the prior `_extractCity` so events with
  /// just "Seaside" or "Tokyo, Japan" still produce a usable query.
  ({String? city, String? state}) _parseLocation(String location) {
    final parts = location
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return (city: null, state: null);

    String? state;
    int stateIdx = -1;
    for (var i = parts.length - 1; i >= 0; i--) {
      final canonical = _resolveUsState(parts[i]);
      if (canonical != null) {
        state = canonical;
        stateIdx = i;
        break;
      }
    }

    if (state != null && stateIdx > 0) {
      // City is the segment immediately preceding the state segment.
      return (city: parts[stateIdx - 1], state: state);
    }

    // No state recognized — fall back to the single/multi-part
    // heuristic. Keeps non-US events working.
    if (parts.length == 1) return (city: parts.first, state: null);
    if (parts.length == 2) return (city: parts.first, state: null);
    return (city: parts[1], state: null);
  }

  /// US state lookup — accepts either the two-letter abbreviation
  /// (`CA`) or the full name (`California`), case-insensitive,
  /// returns the canonical full name or null. Centralised here so
  /// _parseLocation parsing AND geocoder admin1-result filtering
  /// can both round-trip through the same name.
  static const Map<String, String> _usStateNames = {
    'AL': 'Alabama', 'AK': 'Alaska', 'AZ': 'Arizona', 'AR': 'Arkansas',
    'CA': 'California', 'CO': 'Colorado', 'CT': 'Connecticut',
    'DE': 'Delaware', 'FL': 'Florida', 'GA': 'Georgia', 'HI': 'Hawaii',
    'ID': 'Idaho', 'IL': 'Illinois', 'IN': 'Indiana', 'IA': 'Iowa',
    'KS': 'Kansas', 'KY': 'Kentucky', 'LA': 'Louisiana', 'ME': 'Maine',
    'MD': 'Maryland', 'MA': 'Massachusetts', 'MI': 'Michigan',
    'MN': 'Minnesota', 'MS': 'Mississippi', 'MO': 'Missouri',
    'MT': 'Montana', 'NE': 'Nebraska', 'NV': 'Nevada', 'NH': 'New Hampshire',
    'NJ': 'New Jersey', 'NM': 'New Mexico', 'NY': 'New York',
    'NC': 'North Carolina', 'ND': 'North Dakota', 'OH': 'Ohio',
    'OK': 'Oklahoma', 'OR': 'Oregon', 'PA': 'Pennsylvania',
    'RI': 'Rhode Island', 'SC': 'South Carolina', 'SD': 'South Dakota',
    'TN': 'Tennessee', 'TX': 'Texas', 'UT': 'Utah', 'VT': 'Vermont',
    'VA': 'Virginia', 'WA': 'Washington', 'WV': 'West Virginia',
    'WI': 'Wisconsin', 'WY': 'Wyoming', 'DC': 'District of Columbia',
  };

  String? _resolveUsState(String segment) {
    final upper = segment.toUpperCase().trim();
    // Two-letter abbreviation lookup.
    if (_usStateNames.containsKey(upper)) return _usStateNames[upper];
    // Full-name match (case-insensitive).
    for (final fullName in _usStateNames.values) {
      if (fullName.toUpperCase() == upper) return fullName;
    }
    return null;
  }

  String _wmoCondition(int code) {
    if (code == 0) return 'Clear Sky';
    if (code == 1) return 'Mostly Clear';
    if (code == 2) return 'Partly Cloudy';
    if (code == 3) return 'Overcast';
    if (code == 45 || code == 48) return 'Foggy';
    if (code >= 51 && code <= 55) return 'Drizzle';
    if (code >= 61 && code <= 65) return 'Rainy';
    if (code >= 71 && code <= 77) return 'Snowy';
    if (code >= 80 && code <= 82) return 'Rain Showers';
    if (code >= 85 && code <= 86) return 'Snow Showers';
    if (code == 95) return 'Thunderstorm';
    if (code >= 96) return 'Severe Storm';
    return 'Mixed';
  }

  String _wmoIcon(int code) {
    if (code == 0) return '☀️';
    if (code == 1) return '🌤️';
    if (code == 2) return '⛅';
    if (code == 3) return '☁️';
    if (code == 45 || code == 48) return '🌫️';
    if (code >= 51 && code <= 55) return '🌦️';
    if (code >= 61 && code <= 65) return '🌧️';
    if (code >= 71 && code <= 77) return '🌨️';
    if (code >= 80 && code <= 82) return '🌦️';
    if (code >= 85 && code <= 86) return '🌨️';
    if (code == 95) return '⛈️';
    if (code >= 96) return '⛈️';
    return '🌡️';
  }

  Widget _buildWeatherWidget() {
    if (_weatherLoading) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _border),
        ),
        child: Row(children: [
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: _purple)),
          const SizedBox(width: 12),
          Text('Fetching weather…', style: TextStyle(fontSize: 13, color: _muted)),
        ]),
      );
    }
    if (_weatherData == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Row(children: [
        Text(_weatherData!['icon'] as String, style: const TextStyle(fontSize: 38)),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            'EVENT DAY FORECAST',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: _muted, letterSpacing: 0.8),
          ),
          const SizedBox(height: 3),
          Text(
            _weatherData!['condition'] as String,
            style: TextStyle(fontFamily: 'FredokaOne', fontSize: 18, color: _isDark ? Colors.white : AppColors.dark),
          ),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(
            '${_weatherData!['max']}°F',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _isDark ? Colors.white : AppColors.dark),
          ),
          Text(
            'Low ${_weatherData!['min']}°',
            style: TextStyle(fontSize: 12, color: _muted),
          ),
        ]),
      ]),
    );
  }

  bool _sendingRunningLate = false;

  Future<void> _sendRunningLate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Send Running Late?', style: TextStyle(fontFamily: 'FredokaOne', fontSize: 22, color: _isDark ? Colors.white : AppColors.dark)),
        content: Text(
          'All guests who RSVPd "Yes" will receive a push notification that you\'re running a little late.',
          style: TextStyle(fontFamily: 'Nunito', fontSize: 14, color: _muted, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: _muted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.gold,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
            child: const Text('Send 🏃', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _sendingRunningLate = true);
    try {
      await FirebaseFunctions.instance
          .httpsCallable('sendRunningLateNotification')
          .call({'eventId': widget.eventId});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🏃 Running Late notification sent to all guests!'),
            backgroundColor: AppColors.gold,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send notification: $e'), backgroundColor: Colors.redAccent),
        );
      }
    } finally {
      if (mounted) setState(() => _sendingRunningLate = false);
    }
  }

  Widget _buildRunningLateButton() {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: ElevatedButton.icon(
        onPressed: _sendingRunningLate ? null : _sendRunningLate,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.gold.withValues(alpha: 0.12),
          foregroundColor: AppColors.gold,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: AppColors.gold, width: 1.5),
          ),
        ),
        icon: _sendingRunningLate
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.gold))
            : const Icon(Icons.directions_run, size: 18),
        label: Text(
          _sendingRunningLate ? 'Sending...' : 'Running Late 🏃',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
    );
  }

  Widget _buildHostGuestList() {
    final bringing = <String, List<String>>{};
    if (listType == 'Checklist') {
      for (final item in wishlistItems) {
        for (final claim in (item['claims'] as List<dynamic>? ?? [])) {
          final c = claim as Map<String, dynamic>;
          final uid = (c['uid'] as String?) ?? '';
          final itemName = (item['name'] as String?) ?? '';
          bringing.putIfAbsent(uid, () => []).add(itemName);
        }
      }
    }

    // Deduped first (collapse same-human web+app rows), then filter
    // out 'Not Responded' so the visible guest list, header count, and
    // group totals all agree on what counts as a guest.
    final responded = _dedupedRsvps.where((g) => g['status'] != 'Not Responded').toList();
    final yesGuests = responded.where((g) => g['status'] == 'Yes').toList();
    final maybeGuests = responded.where((g) => g['status'] == 'Maybe').toList();
    final noGuests = responded.where((g) => g['status'] == 'No').toList();
    final totalPeople = responded.fold<int>(
      0,
      (s, g) =>
          s +
          ((g['adults']   as int?) ?? 1) +
          ((g['children'] as int?) ?? 0) +
          ((g['plusOnes'] as int?) ?? 0),
    );

    Widget guestRow(Map<String, dynamic> guest) {
      final name = guest['name'] as String;
      final status = guest['status'] as String;
      final guestAdults = guest['adults'] as int;
      final guestChildren = guest['children'] as int;
      final uid = guest['uid'] as String;
      final statusColor = status == 'Yes' ? AppColors.green : status == 'Maybe' ? AppColors.gold : Colors.redAccent;
      final initials = name.trim().split(' ').take(2).map((p) => p.isNotEmpty ? p[0].toUpperCase() : '').join();
      final items = bringing[uid] ?? [];
      final peopleLabel = guestChildren > 0 ? '$guestAdults adults · $guestChildren children' : '$guestAdults adult${guestAdults == 1 ? '' : 's'}';
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14), border: Border.all(color: _border)),
        child: Row(children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.12), shape: BoxShape.circle),
            child: Center(child: Text(initials, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: statusColor))),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : AppColors.dark)),
            Text(peopleLabel, style: TextStyle(fontSize: 12, color: _muted)),
            if (items.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text('Bringing: ${items.join(', ')}', style: const TextStyle(fontSize: 12, color: AppColors.green, fontWeight: FontWeight.w500)),
              ),
          ])),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
            child: Text(status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: statusColor)),
          ),
        ]),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.people_outline, size: 18, color: AppColors.green),
        const SizedBox(width: 8),
        Text('Guest List (${responded.length})', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
        const Spacer(),
        if (totalPeople > 0)
          Text('$totalPeople people total', style: TextStyle(fontSize: 12, color: _muted)),
      ]),
      const SizedBox(height: 6),
      if (responded.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Center(child: Text('No RSVPs yet', style: TextStyle(color: _muted, fontSize: 14))),
        )
      else ...[
        if (yesGuests.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Going (${yesGuests.fold<int>(0, (s, g) => s + ((g['adults'] as int?) ?? 1) + ((g['children'] as int?) ?? 0) + ((g['plusOnes'] as int?) ?? 0))})', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.green, letterSpacing: 0.4)),
          const SizedBox(height: 6),
          ...yesGuests.map(guestRow),
        ],
        if (maybeGuests.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Maybe (${maybeGuests.fold<int>(0, (s, g) => s + ((g['adults'] as int?) ?? 1) + ((g['children'] as int?) ?? 0) + ((g['plusOnes'] as int?) ?? 0))})', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.gold, letterSpacing: 0.4)),
          const SizedBox(height: 6),
          ...maybeGuests.map(guestRow),
        ],
        if (noGuests.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text("Can't Go (${noGuests.fold<int>(0, (s, g) => s + ((g['adults'] as int?) ?? 1) + ((g['children'] as int?) ?? 0) + ((g['plusOnes'] as int?) ?? 0))})", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.redAccent, letterSpacing: 0.4)),
          const SizedBox(height: 6),
          ...noGuests.map(guestRow),
        ],
      ],
    ]);
  }

  /// Total people for a given RSVP [status] (`Yes` / `Maybe` / `No`).
  /// Sums adults + children + plusOnes across every matching rsvps doc
  /// — not the doc count, which would underreport family RSVPs (a
  /// single doc holding 1 adult + 3 children would otherwise show as 1).
  ///
  /// Two failure modes guarded against:
  ///
  /// 1. **Same person counted twice** — a physical guest can end up
  ///    with two rsvps docs if they RSVP'd via the web flow on
  ///    `event.html` (doc id = email) AND via the app (doc id = uid).
  ///    Both docs land in `_rsvps` with different `'uid'` values
  ///    (because we set `'uid': doc.id`). Since the app RSVP is
  ///    authoritative, we collapse anything that LOOKS like an email
  ///    doc id when there's already an entry with the same `name`,
  ///    keeping only the app-source row.
  ///
  /// 2. **In-list duplicates of the SAME doc id** — defensive only;
  ///    the snapshot listener replaces `_rsvps` wholesale so this
  ///    shouldn't happen, but if a future code path mutates `_rsvps`
  ///    by `.add()` it would. Latest entry per uid wins.
  int _peopleFor(String status) {
    final matching = _rsvps.where((g) => g['status'] == status).toList();

    // Dedupe by `uid` (= doc id) first — last write wins.
    final byId = <String, Map<String, dynamic>>{};
    for (final g in matching) {
      byId[g['uid'] as String] = g;
    }

    // Then collapse web-source duplicates: a doc id that LOOKS like an
    // email AND has the same `name` as an entry whose uid does NOT look
    // like an email (i.e. the app RSVP) → drop the web-source row.
    bool looksLikeEmail(String id) => id.contains('@');
    final emails = byId.entries.where((e) => looksLikeEmail(e.key)).toList();
    for (final webEntry in emails) {
      final webName = (webEntry.value['name'] as String?)?.trim().toLowerCase();
      if (webName == null || webName.isEmpty) continue;
      final hasAppDup = byId.values.any((other) {
        final otherUid = other['uid'] as String;
        if (looksLikeEmail(otherUid)) return false;
        final otherName = (other['name'] as String?)?.trim().toLowerCase();
        return otherName == webName;
      });
      if (hasAppDup) byId.remove(webEntry.key);
    }

    final total = byId.values.fold<int>(
      0,
      (acc, g) =>
          acc +
          ((g['adults']   as int?) ?? 0) +
          ((g['children'] as int?) ?? 0) +
          ((g['plusOnes'] as int?) ?? 0),
    );
    debugPrint('[RSVP] _peopleFor($status) total=$total fromDocs=${byId.length} (raw _rsvps=${_rsvps.length})');
    for (final g in byId.values) {
      debugPrint('[RSVP]   uid=${g['uid']} name=${g['name']} status=${g['status']} adults=${g['adults']} children=${g['children']} plusOnes=${g['plusOnes']}');
    }
    return total;
  }

  Widget _buildGuestAvatarRow() {
    // Same source-of-truth as the host guest list: deduped, then drop
    // 'Not Responded' so the scroller only shows people who actually
    // RSVPed (Yes / Maybe / No). Keeps the avatar count consistent
    // with the `Guest List (N)` header above it.
    final visible = _dedupedRsvps.where((g) => g['status'] != 'Not Responded').toList();
    return SizedBox(
      height: 72,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: visible.length,
        itemBuilder: (context, i) {
          final guest = visible[i];
          final name = guest['name'] as String;
          final status = guest['status'] as String;
          final initials = name.trim().split(' ').take(2).map((p) => p.isNotEmpty ? p[0].toUpperCase() : '').join();
          final Color dotColor = status == 'Yes' ? AppColors.green : status == 'Maybe' ? AppColors.gold : Colors.redAccent;
          final adults = guest['adults'] as int;
          final children = guest['children'] as int;
          final guestPlusOnes = (guest['plusOnes'] as int?) ?? 0;
          // Compact label for the avatar tile under each guest in the
          // horizontal scroller. Just the total people — the full
          // breakdown lives in the tap-detail dialog below.
          final totalPeople = adults + children + guestPlusOnes;
          // Detail-dialog breakdown lines — each non-zero count gets its
          // own pluralised line so the host can see exactly who's on
          // the guest's RSVP.
          final breakdownLines = <String>[
            '$adults adult${adults == 1 ? '' : 's'}',
            if (children > 0) '$children child${children == 1 ? '' : 'ren'}',
            if (guestPlusOnes > 0) '$guestPlusOnes plus-one${guestPlusOnes == 1 ? '' : 's'}',
          ];
          return GestureDetector(
            onTap: () {
              showDialog(
                context: context,
                builder: (_) => Dialog(
                  backgroundColor: _card,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        width: 56, height: 56,
                        decoration: BoxDecoration(color: dotColor.withValues(alpha: 0.15), shape: BoxShape.circle),
                        child: Center(child: Text(initials, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: dotColor))),
                      ),
                      const SizedBox(height: 12),
                      Text(name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                        decoration: BoxDecoration(color: dotColor, borderRadius: BorderRadius.circular(100)),
                        child: Text(status, style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)),
                      ),
                      const SizedBox(height: 10),
                      // Headline: total people on this guest's RSVP.
                      Text(
                        '$totalPeople ${totalPeople == 1 ? 'person' : 'people'}',
                        style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w800,
                          color: _isDark ? Colors.white : AppColors.dark,
                        ),
                      ),
                      const SizedBox(height: 4),
                      // Per-segment breakdown — adults always shown,
                      // children + plus-ones only when > 0.
                      Text(
                        breakdownLines.join(' · '),
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: _muted, height: 1.4),
                      ),
                    ]),
                  ),
                ),
              );
            },
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 44, height: 44,
                        decoration: BoxDecoration(
                          color: dotColor.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                          border: Border.all(color: dotColor.withValues(alpha: 0.4), width: 1.5),
                        ),
                        child: Center(child: Text(initials, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: dotColor))),
                      ),
                      Positioned(
                        bottom: 0, right: 0,
                        child: Container(
                          width: 13, height: 13,
                          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: 44,
                    child: Text(
                      name.split(' ').first,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, color: _muted, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Renders the `events/{id}/wishlist` subcollection — items shared INTO
  /// the event from external apps (Amazon, Target, etc.) via the Android
  /// share sheet. Distinct from the array-based host-defined wishlist
  /// items: these have URLs, thumbnails, and a simple claim toggle rather
  /// than a money contribution flow.
  ///
  /// Streamed live so a host on the event screen sees a guest's share
  /// land immediately, and so claim-state changes propagate without
  /// reloading the screen.
  Widget _buildSharedFromWebSection() {
    if (widget.eventId == null) return const SizedBox.shrink();
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('events').doc(widget.eventId)
          .collection('wishlist')
          .orderBy('addedAt', descending: true)
          .snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? const [];
        if (docs.isEmpty) return const SizedBox.shrink();
        final fg = _isDark ? Colors.white : AppColors.dark;
        // No section header — these items are host-curated, integrated
        // visually into the wishlist tab alongside the array-based items.
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final doc in docs) _sharedWishlistCard(doc, fg),
            const SizedBox(height: 4),
          ]),
        );
      },
    );
  }

  Widget _sharedWishlistCard(QueryDocumentSnapshot doc, Color fg) {
    final m = (doc.data() as Map).cast<String, dynamic>();
    final name     = (m['name']     as String?) ?? 'Untitled';
    final url      = (m['url']      as String?) ?? '';
    final imageUrl = (m['imageUrl'] as String?) ?? '';
    final price    = (m['price']    as num?)?.toDouble();
    final notes    = (m['notes']    as String?) ?? '';
    final claimed  = (m['claimed']  as bool?) ?? false;
    final claimedBy= (m['claimedBy'] as String?);
    final contributedCents = (m['contributed'] as num?)?.toInt() ?? 0;
    final contributed = contributedCents / 100.0;
    final remaining = price == null ? null : (price - contributed).clamp(0.0, price);

    final myUid = FirebaseAuth.instance.currentUser?.uid;
    final iAmClaimer = myUid != null && myUid == claimedBy;
    final canRemove  = _isHost || _isCoHost;

    Future<void> openLink() async {
      if (url.isEmpty) return;
      final uri = Uri.tryParse(url);
      if (uri == null) return;
      // inAppBrowserView → Chrome Custom Tab on Android, SFSafariViewController
      // on iOS. Falls back to the system browser if neither is available.
      try {
        await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
      } catch (_) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: claimed
            ? AppColors.green.withValues(alpha: 0.45)
            : _border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Tappable thumbnail — opens in Chrome Custom Tab.
            InkWell(
              onTap: openLink,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: 64, height: 64,
                decoration: BoxDecoration(
                  color: _isDark ? Colors.white.withValues(alpha: 0.06) : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(10),
                ),
                clipBehavior: Clip.antiAlias,
                child: imageUrl.isNotEmpty
                    ? Image.network(imageUrl, fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Icon(Icons.link, color: _muted, size: 28))
                    : Icon(Icons.card_giftcard_outlined, color: _muted, size: 28),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Tappable name — opens in Chrome Custom Tab. The decoration
              // hint (underline + open icon) tells users it's a link.
              InkWell(
                onTap: url.isEmpty ? null : openLink,
                borderRadius: BorderRadius.circular(4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: Text(
                    name,
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Nunito', fontSize: 14, fontWeight: FontWeight.w800,
                      color: claimed ? _muted : fg,
                      decoration: claimed
                          ? TextDecoration.lineThrough
                          : (url.isEmpty ? null : TextDecoration.underline),
                      decorationColor: AppColors.purple.withValues(alpha: 0.6),
                    ),
                  )),
                  if (url.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 6, top: 2),
                      child: Icon(Icons.open_in_new,
                          size: 12, color: claimed ? _muted : AppColors.purple),
                    ),
                ]),
              ),
              if (price != null) ...[
                const SizedBox(height: 4),
                Text(
                  contributedCents > 0
                      ? '\$${contributed.toStringAsFixed(2)} of \$${price.toStringAsFixed(2)} contributed'
                      : '\$${price.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontFamily: 'Nunito', fontSize: 12, fontWeight: FontWeight.w700,
                    color: AppColors.purple,
                  ),
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: price == 0 ? 0 : (contributed / price).clamp(0.0, 1.0),
                    minHeight: 4,
                    backgroundColor: _border,
                    valueColor: const AlwaysStoppedAnimation<Color>(AppColors.purple),
                  ),
                ),
              ],
              if (notes.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(notes, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: 'Nunito', fontSize: 11.5, color: _muted)),
              ],
            ])),
          ]),
          const SizedBox(height: 10),
          // Action row — wraps so it stays readable on narrow screens with
          // many simultaneous actions (Contribute + Claim + Remove).
          // Contribute is hidden for the host / co-host (same rule as
          // the main wishlist tab — hosts shouldn't contribute to
          // their own event); Claim + Remove still render so they
          // can curate the shared-from-web list.
          Wrap(spacing: 8, runSpacing: 6, alignment: WrapAlignment.end, children: [
            if (!_isHost && !_isCoHost
                && price != null && remaining != null && remaining > 0)
              _smallActionBtn(
                icon: Icons.attach_money,
                label: 'Contribute',
                color: AppColors.purple,
                onTap: myUid == null ? null : () => _promptContribution(doc, name, price, contributed),
              ),
            if (!claimed)
              _smallActionBtn(
                icon: Icons.check,
                label: 'Claim',
                color: AppColors.green,
                onTap: myUid == null ? null : () => doc.reference.update({
                  'claimed': true, 'claimedBy': myUid,
                }),
              )
            else if (iAmClaimer)
              _smallActionBtn(
                icon: Icons.undo,
                label: 'Unclaim',
                color: AppColors.gold,
                onTap: () => doc.reference.update({
                  'claimed': false, 'claimedBy': null,
                }),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.green.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('Claimed',
                    style: TextStyle(
                      fontFamily: 'Nunito', fontSize: 11, fontWeight: FontWeight.w800,
                      color: AppColors.green,
                    )),
              ),
            if (canRemove)
              _smallActionBtn(
                icon: Icons.close,
                label: 'Remove',
                color: Colors.redAccent,
                onTap: () => doc.reference.delete(),
              ),
          ]),
        ]),
      ),
    );
  }

  /// Asks the guest how much to contribute, then runs a transaction that
  /// increments `contributed` (cents) on the wishlist item, clamped to the
  /// remaining balance. No real Stripe charge happens here yet — the field
  /// mirrors the existing array-based wishlist contribution, which also
  /// tracks in Firestore only while `kTestingMode` is on. To wire real
  /// money, hook the existing createPaymentIntent flow before the
  /// transaction succeeds.
  Future<void> _promptContribution(
    QueryDocumentSnapshot doc,
    String name,
    double price,
    double alreadyContributed,
  ) async {
    final remaining = (price - alreadyContributed).clamp(0.0, price);
    if (remaining <= 0) return;
    final ctrl = TextEditingController(text: remaining.toStringAsFixed(2));
    final dollars = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Contribute to $name',
            style: TextStyle(
              fontFamily: 'FredokaOne', fontSize: 18,
              color: _isDark ? Colors.white : AppColors.dark,
            )),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            '\$${remaining.toStringAsFixed(2)} remaining of \$${price.toStringAsFixed(2)}.',
            style: TextStyle(fontFamily: 'Nunito', color: _muted, fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: TextStyle(color: _isDark ? Colors.white : AppColors.dark),
            decoration: const InputDecoration(
              prefixText: r'$ ',
              hintText: 'Amount',
              border: OutlineInputBorder(),
            ),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: _muted)),
          ),
          TextButton(
            onPressed: () {
              final v = double.tryParse(ctrl.text.trim().replaceAll(RegExp(r'[\$,]'), ''));
              if (v != null && v > 0) Navigator.pop(ctx, v);
            },
            child: const Text('Contribute',
                style: TextStyle(color: AppColors.purple, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (dollars == null || dollars <= 0) return;
    final addCents = (dollars.clamp(0.0, remaining) * 100).round();
    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final fresh = await tx.get(doc.reference);
        final m = (fresh.data() as Map?)?.cast<String, dynamic>() ?? {};
        final current = (m['contributed'] as num?)?.toInt() ?? 0;
        final cap = (((m['price'] as num?)?.toDouble() ?? 0.0) * 100).round();
        final next = (current + addCents).clamp(0, cap);
        tx.update(doc.reference, {'contributed': next});
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Contributed \$${(addCents / 100).toStringAsFixed(2)} to $name'),
        backgroundColor: AppColors.green,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not contribute: $e'),
        backgroundColor: Colors.redAccent,
      ));
    }
  }

  Widget _smallActionBtn({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback? onTap,
  }) {
    final disabled = onTap == null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: (disabled ? _muted : color).withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: (disabled ? _muted : color).withValues(alpha: 0.40)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: disabled ? _muted : color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                fontFamily: 'Nunito', fontSize: 11, fontWeight: FontWeight.w800,
                color: disabled ? _muted : color,
              )),
        ]),
      ),
    );
  }

  Widget _buildWishlistTab() {
    // No early dispatch to _buildChecklistTab here. The TabBarView
    // wires _buildWishlistTab() and _buildChecklistTab() to their own
    // tabs independently, so each method only ever renders its own
    // body. In Both mode, both are called for their respective tabs.

    // ── Wishlist mode ──
    // Debug prints for host/co-host evaluation — if the shop chips below
    // never appear, the cause is one of these flags being false at the
    // moment the tab renders. _isHost is set in _initEventData after the
    // event doc loads, so during the very first build (before the event
    // resolves) both will be false; flipping host-mode forces a rebuild.
    debugPrint('[Wishlist] build _isHost=$_isHost _isCoHost=$_isCoHost listType=$listType');
    // Filter wishlistItems to wishlist-kind only. In single-mode events
    // _indicesOfKind returns every index, so this is a no-op there.
    // In Both mode it isolates wishlist entries from the checklist
    // entries that share the master array. The extra `price > 0 ||
    // quantity-empty` guard is a belt-and-suspenders defense for items
    // explicitly tagged `kind: 'wishlist'` whose underlying data is
    // actually checklist-shaped (zero price + a quantity string). Without
    // it, those items render with Buy / contribute buttons that do
    // nothing useful at $0 — symptom users reported as "tables and
    // chairs showing wishlist UI". The legacy-data routing in
    // _itemKind() handles the un-tagged case; this catches mis-tagged
    // ones too.
    final wishlistIndices = _indicesOfKind('wishlist').where((i) {
      final item = wishlistItems[i];
      final price = (item['price'] as num?)?.toDouble() ?? 0.0;
      final qty = (item['quantity'] as String?) ?? '';
      return price > 0 || qty.isEmpty;
    }).toList();
    final fulfilledCount = wishlistIndices.where((i) {
      final item = wishlistItems[i];
      final bought = item['bought'] == true;
      final price = (item['price'] as num?)?.toDouble() ?? 0.0;
      final contrib = (item['contributed'] as num?)?.toDouble() ?? 0.0;
      return bought || (price > 0 && contrib >= price);
    }).length;
    final wishlistTotal = wishlistIndices.length;
    return SafeArea(
      // top:false so we don't double-pad below the AppBar; we only want
      // the bottom safe-area inset (gesture bar / nav buttons) folded in
      // alongside the keyboard inset on the inner SingleChildScrollView.
      top: false,
      child: Stack(
      children: [
      // SingleChildScrollView wraps the whole wishlist body so the fixed-height
      // banners + header can't overflow the RenderFlex when the keyboard opens
      // and shrinks the viewport. The inner ListView.builder becomes shrinkWrap
      // with no physics of its own — the outer scroll view owns scrolling.
      //
      // We deliberately do NOT add viewInsets.bottom here: the parent Scaffold
      // already has `resizeToAvoidBottomInset: true`, so the body is shrunken
      // above the keyboard, and viewInsets.bottom still reports the keyboard
      // height. Adding it as inner padding stacked on top of the resize was
      // exactly the 99px overflow the user kept seeing. Just use a flat 16px
      // breathing-room margin and let Scaffold own the keyboard handling.
      SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
      children: [
        if (_isArchived)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.purple.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.purple.withValues(alpha: 0.2)),
            ),
            child: Row(children: [
              const Icon(Icons.lock_outline, size: 16, color: AppColors.purple),
              const SizedBox(width: 10),
              const Text('Contributions are now closed', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.purple)),
            ]),
          ),
        if (_isHostMode)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.green.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.green.withValues(alpha: 0.25)),
            ),
            child: Row(children: [
              const Icon(Icons.attach_money, size: 18, color: AppColors.green),
              const SizedBox(width: 8),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Total Raised', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.green, letterSpacing: 0.4)),
                Text('\$${totalContributed.toStringAsFixed(2)} of \$${totalWishlistValue.toStringAsFixed(2)}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.green)),
              ]),
              const Spacer(),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('$fulfilledCount of $wishlistTotal', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _isDark ? Colors.white : AppColors.dark)),
                Text('items fulfilled', style: TextStyle(fontSize: 11, color: _muted)),
              ]),
            ]),
          ),
        Container(
          color: _card,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Row(
            children: [
              Expanded(child: Text('Wishlist', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _isDark ? Colors.white : AppColors.dark))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: AppColors.greenPale, borderRadius: BorderRadius.circular(100)),
                child: Text('$fulfilledCount/$wishlistTotal fulfilled', style: const TextStyle(fontSize: 12, color: AppColors.green, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
        // Shop chips for browsing retailer apps live on EditEventScreen now,
        // not here — guests should never see them.
        // Items shared into the event via the Android share sheet — separate
        // subcollection from the host-defined wishlist array. Hidden entirely
        // when nothing's been shared, so it adds zero noise for events that
        // never receive external shares.
        _buildSharedFromWebSection(),
        ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(16, 16, 16, _cart.isEmpty ? 16 : 88),
            // wishlistIndices holds the original-array indices of items
            // whose kind is 'wishlist'. We pass that original index
            // through to the item builder so per-item mutations
            // (contribute, bought, claim) keep operating on the master
            // wishlistItems array — no index translation needed at the
            // mutation site.
            itemCount: wishlistIndices.length,
            itemBuilder: (context, index) {
              final itemIdx = wishlistIndices[index];
              final item = wishlistItems[itemIdx];
              final isBought = item['bought'] as bool;
              final price = item['price'] as double;
              final totalContrib = item['contributed'] as double;
              final myContrib = _myContributions[item['name'] as String] ?? 0.0;
              // Guard against price <= 0 — dividing 0 contribution by
              // 0 price gave NaN, and LinearProgressIndicator renders
              // NaN as a fully-filled bar rather than empty. The bar
              // should be empty until either a contribution lands or
              // the host sets a target price. Anything > 0 still
              // computes the normal contributed/price ratio.
              final totalProgress = price > 0
                  ? (totalContrib / price).clamp(0.0, 1.0)
                  : 0.0;
              final myProgress = price > 0
                  ? (myContrib / price).clamp(0.0, 1.0)
                  : 0.0;
              // boughtBy is set by the "Bring It" flow with the
              // buyer's uid + name. Drives the "Bringing it 🛍️"
              // badge (vs the legacy "Bought ✓" pill) so the host
              // can see who's covering it. `iAmBuyer` flips on the
              // undo affordance so only the original claimer can
              // reverse their own commitment.
              final boughtBy = item['boughtBy'] is Map ? Map<String, dynamic>.from(item['boughtBy'] as Map) : null;
              final hasBuyer = boughtBy != null && (boughtBy['uid'] as String?) != null;
              final buyerName = (boughtBy?['name'] as String?) ?? '';
              final myUid = FirebaseAuth.instance.currentUser?.uid;
              final iAmBuyer = hasBuyer && boughtBy['uid'] == myUid;
              return Container(
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: isBought ? (_isDark ? Colors.white.withValues(alpha: 0.04) : Colors.grey.shade50) : _card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: isBought ? (_isDark ? _border : Colors.grey.shade200) : _border),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(item['name'] as String,
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                              color: isBought ? _muted : (_isDark ? Colors.white : AppColors.dark),
                              decoration: isBought ? TextDecoration.lineThrough : null)),
                        ),
                        if (isBought && hasBuyer)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: AppColors.purple.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(100),
                              border: Border.all(color: AppColors.purple.withValues(alpha: 0.4)),
                            ),
                            child: const Text('Bringing it 🛍️', style: TextStyle(fontSize: 12, color: AppColors.purple, fontWeight: FontWeight.w800)),
                          )
                        else if (isBought)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(100)),
                            child: const Text('Bought ✓', style: TextStyle(fontSize: 12, color: AppColors.muted, fontWeight: FontWeight.w600)),
                          )
                        else
                          Text('\$${(item['price'] as double).toStringAsFixed(2)}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : AppColors.dark)),
                      ],
                    ),
                    if (isBought && hasBuyer && buyerName.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '$buyerName is bringing it',
                          style: const TextStyle(fontSize: 12, color: AppColors.purple, fontWeight: FontWeight.w600),
                        ),
                      ),
                    const SizedBox(height: 10),
                    // Progress track. Background is the theme-aware
                    // `_border` color (medium-light grey in light mode,
                    // medium-dark in dark mode) — was previously
                    // `Colors.grey.shade100` (near-white), which made
                    // an empty bar visually indistinguishable from a
                    // fully-filled green bar at a glance. The 0% case
                    // now reads as a clearly-empty track.
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        height: 8,
                        child: Stack(
                          children: [
                            LinearProgressIndicator(
                              value: isBought ? 1.0 : totalProgress,
                              minHeight: 8,
                              backgroundColor: _border,
                              color: isBought ? _muted : AppColors.greenLight,
                            ),
                            if (!isBought && myProgress > 0)
                              LinearProgressIndicator(
                                value: myProgress,
                                minHeight: 8,
                                backgroundColor: Colors.transparent,
                                color: AppColors.purple.withValues(alpha: 0.75),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text('Total: \$${totalContrib.toStringAsFixed(0)} of \$${price.toStringAsFixed(0)} contributed', style: TextStyle(fontSize: 12, color: _muted)),
                    if (myContrib > 0)
                      Text('Your contribution: \$${myContrib.toStringAsFixed(0)}', style: const TextStyle(fontSize: 12, color: AppColors.purple, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 12),
                    if (widget.isOnboarding)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text('Payments disabled in demo', style: TextStyle(fontSize: 11, color: _muted, fontStyle: FontStyle.italic)),
                      )
                    // Hide the entire Buy / Contribute / Undo row for the
                    // event host. Hosts shouldn't be contributing to their
                    // own wishlist — the buttons used to render disabled
                    // when `myUid == hostId`, but the user wanted them
                    // gone from the UI completely. Co-hosts (who help
                    // run the event) follow the same rule. The
                    // contribution-progress text + total-raised banner
                    // up the tree remain visible so the host can still
                    // see what guests have done.
                    else if (_isHost || _isCoHost)
                      const SizedBox.shrink()
                    // Bought state — collapses the entire action area
                    // to a single pill. Bringing it 🛍️ when stamped
                    // via the Bring It flow (boughtBy present); Bought
                    // ✓ for legacy/cart-paid items where no buyer was
                    // recorded. When the current user is the recorded
                    // buyer, an Undo button sits trailing the label
                    // so they can reverse a mis-tap; other guests
                    // (and cart-paid items) get the label alone.
                    else if (isBought)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: hasBuyer
                              ? AppColors.purple.withValues(alpha: 0.10)
                              : Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(10),
                          border: hasBuyer
                              ? Border.all(color: AppColors.purple.withValues(alpha: 0.35))
                              : null,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              hasBuyer ? 'Bringing it 🛍️' : 'Bought ✓',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: hasBuyer ? AppColors.purple : AppColors.muted,
                              ),
                            ),
                            if (iAmBuyer) ...[
                              const SizedBox(width: 12),
                              InkWell(
                                onTap: _isArchived ? null : () => _undoBuyAndBring(itemIdx),
                                borderRadius: BorderRadius.circular(8),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                                    Icon(Icons.undo, size: 13, color: AppColors.purple.withValues(alpha: 0.85)),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Undo',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                        color: AppColors.purple.withValues(alpha: 0.85),
                                      ),
                                    ),
                                  ]),
                                ),
                              ),
                            ],
                          ],
                        ),
                      )
                    else ...[
                      // Bring It — primary purple button on its own
                      // row, sits ABOVE the contribute amounts. Tapping
                      // launches the item URL externally (if any), then
                      // shows the "Got it covered?" confirmation. Once
                      // confirmed, the whole action area collapses to
                      // the Bringing it 🛍️ pill above (with an Undo
                      // affordance for the original claimer) so nobody
                      // else double-buys.
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _isArchived ? null : () => _buyAndBring(itemIdx),
                          icon: const Icon(Icons.shopping_bag_outlined, size: 16),
                          label: const Text('Bring It', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isArchived ? Colors.grey.shade300 : AppColors.purple,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Buy + preset contribute amounts + undo. Always
                      // rendered so guests never see the action area
                      // collapse mid-flow — buttons disable (greyed
                      // out) when the action wouldn't apply (item
                      // already fully funded, no remaining balance,
                      // archived event), but they don't disappear.
                      // Previous version replaced Buy with a "Funded"
                      // pill at totalProgress >= 1.0 and clamped each
                      // contribute amount to `remaining`, which made
                      // a fully-funded item render as "$0 $0 $0" —
                      // visually indistinguishable from missing
                      // buttons.
                      Row(
                        children: [
                          // Buy — always present. Disabled when item
                          // is already fully funded.
                          SizedBox(
                            width: 56,
                            child: ElevatedButton(
                              onPressed: (_isArchived || totalProgress >= 1.0)
                                  ? null
                                  : () => _toggleBuy(itemIdx),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.green,
                                foregroundColor: Colors.white,
                                disabledBackgroundColor: Colors.grey.shade200,
                                disabledForegroundColor: Colors.grey.shade500,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              ),
                              child: const Text('Buy', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                            ),
                          ),
                          const SizedBox(width: 4),
                          // Preset contribute amounts — dynamically
                          // tailored so a guest can never push the
                          // total over the item's price. Standard
                          // presets ($5/$10/$20/$50) are filtered to
                          // those strictly less than the remaining
                          // balance, then a final exact-remaining
                          // chip is appended when it's not already
                          // in the list. Fully-funded items show the
                          // standard presets all disabled (grey) so
                          // the row keeps visual continuity instead
                          // of collapsing to nothing.
                          Expanded(
                            child: Builder(builder: (_) {
                              final remaining = (price - totalContrib).clamp(0.0, price);
                              const standardPresets = <double>[5, 10, 20, 50];
                              final allDisabled = _isArchived || totalProgress >= 1.0 || remaining <= 0;
                              final List<double> chipAmounts;
                              if (remaining <= 0) {
                                chipAmounts = standardPresets;
                              } else {
                                final filtered = standardPresets
                                    .where((p) => p < remaining)
                                    .toList();
                                if (!filtered.contains(remaining)) {
                                  filtered.add(remaining);
                                }
                                chipAmounts = filtered.isEmpty
                                    ? <double>[remaining]
                                    : filtered;
                              }
                              return Row(
                                children: chipAmounts.map((amt) {
                                  // Whole-dollar values render without
                                  // decimals; fractional remaining
                                  // amounts ($42.50 left, etc.) keep
                                  // two decimals so the displayed total
                                  // matches the actual contribution.
                                  final label = amt == amt.roundToDouble()
                                      ? '\$${amt.toInt()}'
                                      : '\$${amt.toStringAsFixed(2)}';
                                  return Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 3),
                                      child: OutlinedButton(
                                        onPressed: allDisabled ? null : () {
                                          _addToCart(item['name'] as String, amt);
                                          _contributeFirestore(itemIdx, amt);
                                        },
                                        style: OutlinedButton.styleFrom(
                                          side: BorderSide(color: allDisabled ? Colors.grey.shade300 : AppColors.green),
                                          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                        ),
                                        child: Text(
                                          label,
                                          style: TextStyle(
                                            color: allDisabled ? Colors.grey.shade400 : AppColors.green,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                }).toList(),
                              );
                            }),
                          ),
                          if (myContrib > 0) ...[
                            const SizedBox(width: 4),
                            GestureDetector(
                              onTap: () {
                                _removeFromCart(item['name'] as String);
                                _undoContributionFirestore(itemIdx);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                decoration: BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.circular(8)),
                                child: const Icon(Icons.undo, size: 13, color: Colors.white),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                    if (!isBought)
                      Padding(padding: const EdgeInsets.only(top: 6), child: Text('Unfulfilled contributions go to the host', style: TextStyle(fontSize: 11, color: _muted, fontStyle: FontStyle.italic))),
                  ],
                ),
              );
            },
          ),
      ],
      ),
      ),
      if (_cart.isNotEmpty && !widget.isOnboarding)
        Positioned(
          left: 16, right: 16, bottom: 16,
          child: _buildCartBar(),
        ),
      ],
      ),
    );
  }

  Widget _buildCartBar() {
    final total = _cart.fold<double>(0, (s, c) => s + (c['amount'] as double));
    final count = _cart.length;
    return GestureDetector(
      onTap: _showCartSheet,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        decoration: BoxDecoration(
          color: AppColors.green,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: AppColors.green.withValues(alpha: 0.45), blurRadius: 24, offset: const Offset(0, 8))],
        ),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(12)),
            child: Text('$count item${count == 1 ? '' : 's'}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
          ),
          const SizedBox(width: 10),
          const Text('·', style: TextStyle(fontSize: 14, color: Colors.white)),
          const SizedBox(width: 10),
          Expanded(child: Text('\$${total.toStringAsFixed(2)}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white))),
          const Text('View Cart', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right, color: Colors.white, size: 18),
        ]),
      ),
    );
  }

  Future<void> _completePurchase({
    required List<Map<String, dynamic>> cartSnapshot,
    required double total,
  }) async {
    final amountCents = (total * 100).round();
    debugPrint('[Payment] starting purchase: total=\$$total amountCents=$amountCents');
    try {
      debugPrint('[Payment] calling createPaymentIntent Cloud Function...');
      final callable = FirebaseFunctions.instance.httpsCallable('createPaymentIntent');
      final result = await callable.call({
        'amount': amountCents,
        'currency': 'usd',
      });
      debugPrint('[Payment] Cloud Function response: ${result.data}');
      final clientSecret = result.data['clientSecret'] as String;
      debugPrint('[Payment] got clientSecret: ${clientSecret.substring(0, 20)}...');

      debugPrint('[Payment] initializing payment sheet...');
      await Stripe.instance.initPaymentSheet(
        paymentSheetParameters: SetupPaymentSheetParameters(
          paymentIntentClientSecret: clientSecret,
          merchantDisplayName: 'QRParty',
          style: ThemeMode.system,
          returnURL: 'com.qrparty.app://stripe-redirect',
          billingDetailsCollectionConfiguration: const BillingDetailsCollectionConfiguration(
            email: CollectionMode.automatic,
          ),
        ),
      );
      debugPrint('[Payment] payment sheet initialized');

      debugPrint('[Payment] presenting payment sheet...');
      await Stripe.instance.presentPaymentSheet();
      debugPrint('[Payment] payment sheet completed successfully');

      // Payment succeeded — now close the cart sheet and save
      if (mounted) Navigator.pop(context);
      await _saveCartToFirestore(cartSnapshot);
      setState(() => _cart.clear());
      debugPrint('[Payment] Firestore updated and cart cleared');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('🎉 Payment successful! Thank you!'),
          backgroundColor: AppColors.green,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        ));
      }
    } on StripeException catch (e) {
      debugPrint('[Payment] StripeException: code=${e.error.code} msg=${e.error.localizedMessage} type=${e.error.type}');
      if (e.error.code != FailureCode.Canceled && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Payment failed: ${e.error.localizedMessage ?? 'Please try again'}'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        ));
      }
      rethrow;
    } catch (e, st) {
      debugPrint('[Payment] unexpected error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not process payment: $e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        ));
      }
      rethrow;
    }
  }

  Future<void> _saveCartToFirestore(List<Map<String, dynamic>> cart) async {
    if (widget.eventId == null) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final eventRef = FirebaseFirestore.instance.collection('events').doc(widget.eventId);
    final contribRef = eventRef.collection('wishlist_contributions').doc(user.uid);

    await FirebaseFirestore.instance.runTransaction((tx) async {
      final eventSnap = await tx.get(eventRef);
      final contribSnap = await tx.get(contribRef);
      final rawWishlist = List<Map<String, dynamic>>.from(
        (eventSnap.data()?['wishlist'] as List<dynamic>? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
      );
      final existingItems = Map<String, dynamic>.from(contribSnap.data()?['items'] as Map? ?? {});

      for (final cartItem in cart) {
        final name = cartItem['name'] as String;
        final amount = cartItem['amount'] as double;
        final type = cartItem['type'] as String;
        final idx = rawWishlist.indexWhere((w) => w['name'] == name);
        if (idx < 0) continue;

        if (type == 'contribute') {
          final price = (rawWishlist[idx]['price'] as num?)?.toDouble() ?? 0.0;
          final currentTotal = (rawWishlist[idx]['contributed'] as num?)?.toDouble() ?? 0.0;
          final remaining = price - currentTotal;
          if (remaining <= 0) continue;
          final toAdd = amount > remaining ? remaining : amount;
          rawWishlist[idx]['contributed'] = currentTotal + toAdd;
          existingItems[name] = ((existingItems[name] as num?)?.toDouble() ?? 0.0) + toAdd;
        } else if (type == 'buy') {
          final price = (rawWishlist[idx]['price'] as num?)?.toDouble() ?? 0.0;
          rawWishlist[idx]['bought'] = true;
          rawWishlist[idx]['contributed'] = price;
          existingItems[name] = price;
        }
      }

      tx.update(eventRef, {'wishlist': rawWishlist});
      tx.set(contribRef, {'items': existingItems}, SetOptions(merge: true));
    });

    setState(() {
      for (final cartItem in cart) {
        final name = cartItem['name'] as String;
        final amount = cartItem['amount'] as double;
        final type = cartItem['type'] as String;
        final idx = wishlistItems.indexWhere((w) => w['name'] == name);
        if (idx < 0) continue;
        if (type == 'contribute') {
          final price = wishlistItems[idx]['price'] as double;
          final current = wishlistItems[idx]['contributed'] as double;
          final remaining = price - current;
          final toAdd = amount > remaining ? remaining : amount;
          wishlistItems[idx]['contributed'] = (current + toAdd).clamp(0.0, price);
          _myContributions[name] = (_myContributions[name] ?? 0.0) + toAdd;
        } else if (type == 'buy') {
          final price = wishlistItems[idx]['price'] as double;
          wishlistItems[idx]['bought'] = true;
          wishlistItems[idx]['contributed'] = price;
          _myContributions[name] = price;
        }
      }
    });
  }

  void _showCartSheet() {
    final cartSnapshot = List<Map<String, dynamic>>.from(_cart.map((c) => Map<String, dynamic>.from(c)));
    final total = cartSnapshot.fold<double>(0, (s, c) => s + (c['amount'] as double));
    showModalBottomSheet(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      isScrollControlled: true,
      builder: (_) {
        bool processing = false;
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 36),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: _border, borderRadius: BorderRadius.circular(2)))),
                const SizedBox(height: 18),
                Row(children: [
                  const Icon(Icons.shopping_cart_outlined, color: AppColors.green, size: 22),
                  const SizedBox(width: 10),
                  Text('Your Cart', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _isDark ? Colors.white : AppColors.dark)),
                ]),
                const SizedBox(height: 16),
                ...cartSnapshot.map((c) {
                  final isBuy = c['type'] == 'buy';
                  final amt = c['amount'] as double;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(children: [
                      Expanded(child: Text(c['name'] as String, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: _isDark ? Colors.white : AppColors.dark))),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: (isBuy ? AppColors.green : AppColors.purple).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
                        child: Text(isBuy ? 'Buy' : 'Contribute', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isBuy ? AppColors.green : AppColors.purple)),
                      ),
                      const SizedBox(width: 12),
                      Text('\$${amt.toStringAsFixed(2)}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
                    ]),
                  );
                }),
                const Divider(height: 24),
                Row(children: [
                  Expanded(child: Text('Total', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark))),
                  Text('\$${total.toStringAsFixed(2)}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: AppColors.green)),
                ]),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: kTestingMode || processing
                        ? null
                        : () async {
                            setSheetState(() => processing = true);
                            try {
                              await _completePurchase(cartSnapshot: cartSnapshot, total: total);
                            } finally {
                              if (sheetCtx.mounted) setSheetState(() => processing = false);
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.green,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: _border,
                      disabledForegroundColor: _muted,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: kTestingMode
                        ? const Text('Payments coming soon', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700))
                        : processing
                            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                            : const Text('Complete Purchase', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildChecklistTab() {
    // Same kind-filter pattern as _buildWishlistTab: in single-mode
    // events _indicesOfKind returns every index, in Both mode it
    // isolates checklist entries from wishlist entries that share the
    // master wishlistItems array.
    final checklistIndices = _indicesOfKind('checklist');
    final claimedCount = checklistIndices.where(
      (i) => ((wishlistItems[i]['claimed'] as num?)?.toInt() ?? 0) > 0,
    ).length;
    final checklistTotal = checklistIndices.length;
    // Wrap the whole checklist body in a scroll view so the fixed-height
    // banner + header can't overflow when the keyboard pops up to claim
    // an item. The parent Scaffold has resizeToAvoidBottomInset: true,
    // which already shrinks the body above the keyboard — adding
    // viewInsets.bottom as extra padding here would double-count the
    // inset and push the inner column off the bottom of the viewport.
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
      children: [
        if (_showChecklistBanner)
          Container(
            color: AppColors.green,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                const Text('🧺', style: TextStyle(fontSize: 16)),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Let the host know what you\'re bringing!',
                    style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
                GestureDetector(
                  onTap: () => setState(() => _showChecklistBanner = false),
                  child: const Icon(Icons.close, color: Colors.white, size: 18),
                ),
              ],
            ),
          ),
        Container(
          color: _card,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Row(
            children: [
              Expanded(child: Text('Checklist', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _isDark ? Colors.white : AppColors.dark))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: AppColors.greenPale, borderRadius: BorderRadius.circular(100)),
                child: Text('$claimedCount/$checklistTotal claimed', style: const TextStyle(fontSize: 12, color: AppColors.green, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
        ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            // checklistIndices passes through the master-array index so
            // _saveClaimToFirestore et al. continue to write to the
            // right slot in event.wishlist without translation.
            itemCount: checklistIndices.length,
            itemBuilder: (context, builderIdx) {
              final index = checklistIndices[builderIdx];
              final item = wishlistItems[index];
              final qty = (item['quantity'] as String?) ?? '';
              final claims = List<Map<String, dynamic>>.from(item['claims'] as List? ?? []);
              final isActive = _activeClaimIndex == index;
              // Quantity tracking. quantityNeeded is the host-set
              // target (int); totalClaimed is the SUM of guest claim
              // amounts. When quantityNeeded is set, the row shows
              // "X/Y claimed" and chips/buttons cap at the
              // remainder. When unset (legacy items, or host didn't
              // type a number) display falls back to the raw qty
              // string and chips run uncapped.
              final quantityNeeded = _itemQuantityNeeded(item);
              final totalClaimed = _itemTotalClaimed(item);
              final remaining = quantityNeeded != null
                  ? (quantityNeeded - totalClaimed).clamp(0, quantityNeeded)
                  : null;
              final fullyClaimed = remaining != null && remaining == 0;
              return Container(
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: isActive ? AppColors.green : _border, width: isActive ? 1.5 : 1),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header row: name + qty pill + (when not active) close X
                    Row(
                      children: [
                        Expanded(
                          child: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              Text(item['name'] as String, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
                              // Quantity pill. Unlimited items get a
                              // purple pill with the running tally +
                              // ∞. Cap-having items use the host-set
                              // numeric `quantityNeeded` ("X/Y
                              // claimed"); fall back to the legacy
                              // free-form `quantity` String for items
                              // written before the typed quantity
                              // field existed.
                              if (item['unlimited'] == true)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                                  decoration: BoxDecoration(color: _purple.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(100)),
                                  child: Text(
                                    '$totalClaimed claimed · ∞',
                                    style: const TextStyle(fontSize: 12, color: _purple, fontWeight: FontWeight.w800),
                                  ),
                                )
                              else if (quantityNeeded != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                                  decoration: BoxDecoration(color: AppColors.greenPale, borderRadius: BorderRadius.circular(100)),
                                  child: Text(
                                    '$totalClaimed/$quantityNeeded claimed',
                                    style: const TextStyle(fontSize: 12, color: AppColors.green, fontWeight: FontWeight.w600),
                                  ),
                                )
                              else if (qty.isNotEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                                  decoration: BoxDecoration(color: AppColors.greenPale, borderRadius: BorderRadius.circular(100)),
                                  child: Text('Qty: $qty', style: const TextStyle(fontSize: 12, color: AppColors.green, fontWeight: FontWeight.w600)),
                                ),
                            ],
                          ),
                        ),
                        if (isActive) ...[
                          const SizedBox(width: 12),
                          GestureDetector(
                            onTap: () => setState(() {
                              _activeClaimIndex = null;
                              _activeClaimQty = '1';
                              _activeClaimManualMode = false;
                              _claimManualCtrl.clear();
                            }),
                            child: Icon(Icons.close, size: 20, color: _muted),
                          ),
                        ],
                      ],
                    ),
                    // Toggle between the two-button row and the
                    // quantity-chip selector. Single if/else so they
                    // can never both render or both vanish — previous
                    // version used two separate conditionals which
                    // were structurally fine but harder to reason
                    // about during rapid taps.
                    if (fullyClaimed) ...[
                      // Item is fully covered — host's quantity needed
                      // is met by the sum of guest claims. Collapses
                      // the action area to a single pill so no one can
                      // pile on more claims that would push the total
                      // over.
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: AppColors.green.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.green.withValues(alpha: 0.35)),
                        ),
                        child: const Center(
                          child: Text(
                            'Fully claimed ✓',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.green),
                          ),
                        ),
                      ),
                    ] else if (isActive) ...[
                      const SizedBox(height: 14),
                      Text(
                        'How many are you bringing?',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : AppColors.dark),
                      ),
                      const SizedBox(height: 8),
                      // Single chip row that includes a trailing "✏️"
                      // Other chip. Tapping Other swaps THAT chip
                      // (only) into a numeric TextField with the
                      // same green-outlined-selected look as a
                      // chosen chip, while the preset chips stay
                      // visible. Tapping any preset clears the
                      // manual entry and switches back to chip mode.
                      // Both paths honor the quantityNeeded cap (chip
                      // filter + manual-mode runtime check + server
                      // re-validation inside the transaction).
                      Builder(builder: (_) {
                        final availableChips = remaining == null
                            ? _claimQtyOptions
                            : _claimQtyOptions
                                .where((opt) => _claimAmountValue(opt) <= remaining)
                                .toList();
                        // If the active selection no longer fits the
                        // cap (e.g. earlier chip-tap landed on '5'
                        // but remaining is now 3), snap it back to a
                        // valid option so Confirm can't over-claim.
                        // Manual mode is exempt — we're not picking
                        // a chip in that state.
                        if (!_activeClaimManualMode
                            && availableChips.isNotEmpty
                            && !availableChips.contains(_activeClaimQty)) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (!mounted) return;
                            setState(() => _activeClaimQty = availableChips.first);
                          });
                        }
                        // Helper that builds a single preset chip.
                        // Tapping any preset exits manual mode and
                        // selects the preset.
                        Widget presetChip(String opt) {
                          final isSelected = !_activeClaimManualMode && _activeClaimQty == opt;
                          return OutlinedButton(
                            onPressed: () => setState(() {
                              _activeClaimQty = opt;
                              _activeClaimManualMode = false;
                              _claimManualCtrl.clear();
                            }),
                            style: OutlinedButton.styleFrom(
                              backgroundColor: isSelected ? AppColors.green : Colors.transparent,
                              side: BorderSide(color: AppColors.green, width: isSelected ? 1.5 : 1),
                              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            child: Text(
                              opt,
                              style: TextStyle(
                                color: isSelected ? Colors.white : AppColors.green,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          );
                        }
                        // Trailing "Other" cell — either the ✏️ chip
                        // (idle) or an inline TextField (active).
                        // The TextField mimics the selected-chip
                        // look: filled green background, white-on-
                        // green text, same height as a chip so the
                        // grid stays even.
                        Widget otherCell() {
                          if (_activeClaimManualMode) {
                            return SizedBox(
                              height: 38,
                              child: TextField(
                                controller: _claimManualCtrl,
                                autofocus: true,
                                keyboardType: TextInputType.number,
                                textInputAction: TextInputAction.done,
                                textAlign: TextAlign.center,
                                onSubmitted: (_) {
                                  if (_savingClaim) return;
                                  final n = int.tryParse(_claimManualCtrl.text.trim());
                                  if (n == null || n <= 0) return;
                                  if (remaining != null && n > remaining) return;
                                  _saveClaimToFirestore(index, n.toString());
                                },
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14),
                                cursorColor: Colors.white,
                                decoration: InputDecoration(
                                  isDense: true,
                                  filled: true,
                                  fillColor: AppColors.green,
                                  hintText: remaining != null ? '≤ $remaining' : 'e.g. 30',
                                  hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontWeight: FontWeight.w700, fontSize: 13),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppColors.green, width: 1.5)),
                                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppColors.green, width: 1.5)),
                                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppColors.green, width: 1.5)),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                                ),
                              ),
                            );
                          }
                          return OutlinedButton(
                            onPressed: () => setState(() {
                              _activeClaimManualMode = true;
                              // Pre-seed with the current chip
                              // selection if it's a plain integer.
                              final asInt = int.tryParse(_activeClaimQty);
                              _claimManualCtrl.text = asInt != null ? asInt.toString() : '';
                            }),
                            style: OutlinedButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              side: const BorderSide(color: AppColors.green, width: 1),
                              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            child: const Text(
                              '✏️',
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                            ),
                          );
                        }
                        // Build the full cell list (presets + Other),
                        // then chunk into rows of 2. Each chip is
                        // wrapped in Expanded so all cells are equal-
                        // width. Orphan rows (odd cell count) get a
                        // SizedBox.shrink() filler in the second slot
                        // to preserve the 50% column width — without
                        // it the lone chip would stretch full-width.
                        final cells = <Widget>[
                          ...availableChips.map(presetChip),
                          otherCell(),
                        ];
                        final rows = <Widget>[];
                        for (var i = 0; i < cells.length; i += 2) {
                          if (i > 0) rows.add(const SizedBox(height: 8));
                          final left = cells[i];
                          final right = i + 1 < cells.length
                              ? cells[i + 1]
                              : const SizedBox.shrink();
                          rows.add(Row(children: [
                            Expanded(child: left),
                            const SizedBox(width: 8),
                            Expanded(child: right),
                          ]));
                        }
                        return Column(children: rows);
                      }),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _savingClaim
                              ? null
                              : () {
                                  if (_activeClaimManualMode) {
                                    final n = int.tryParse(_claimManualCtrl.text.trim());
                                    if (n == null || n <= 0) {
                                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                        content: Text('Enter a number greater than 0.'),
                                        backgroundColor: Colors.redAccent,
                                      ));
                                      return;
                                    }
                                    if (remaining != null && n > remaining) {
                                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                        content: Text('Only $remaining left to claim — try a smaller number.'),
                                        backgroundColor: AppColors.gold,
                                      ));
                                      return;
                                    }
                                    _saveClaimToFirestore(index, n.toString());
                                  } else {
                                    _saveClaimToFirestore(index, _activeClaimQty);
                                  }
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.green,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          child: _savingClaim
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                              : const Text('Confirm', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 12),
                      // Single full-width "I'll bring this" button.
                      // Tapping opens the quantity-chip flow above.
                      // The previous purple "Bring It" companion was
                      // removed — checklist now has one path: claim,
                      // pick a count, confirm.
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () => setState(() {
                            _activeClaimIndex = index;
                            _activeClaimQty = '1';
                            _activeClaimManualMode = false;
                            _claimManualCtrl.clear();
                          }),
                          style: ElevatedButton.styleFrom(backgroundColor: AppColors.green, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), padding: const EdgeInsets.symmetric(vertical: 10)),
                          child: const Text("I'll bring this", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                    // Claims list
                    if (claims.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      const Divider(height: 1),
                      const SizedBox(height: 10),
                      ...claims.map((c) {
                        final claimUid = c['uid'] as String?;
                        final myUid = FirebaseAuth.instance.currentUser?.uid;
                        final isMine = claimUid != null && claimUid == myUid;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            children: [
                              const Icon(Icons.check_circle_outline, size: 14, color: AppColors.green),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  c['name'] as String,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : AppColors.dark),
                                ),
                              ),
                              Text(' · ', style: TextStyle(color: _muted)),
                              Flexible(
                                child: Text(
                                  c['amount'] as String,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 13, color: _muted),
                                ),
                              ),
                              // Undo button — only shown on the row that
                              // represents this user's own claim. Tapping
                              // removes their entry from the claims array
                              // and bumps `claimed` down. Surfaced only
                              // for guests; the host already has admin
                              // tools elsewhere and shouldn't have an
                              // identity-collision-prone undo button on
                              // someone else's claim row.
                              if (isMine) ...[
                                const Spacer(),
                                InkWell(
                                  onTap: _savingClaim ? null : () => _unclaimFromFirestore(index),
                                  borderRadius: BorderRadius.circular(8),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                                      Icon(Icons.undo, size: 13, color: _muted),
                                      const SizedBox(width: 4),
                                      Text(
                                        'Undo',
                                        style: TextStyle(fontSize: 12, color: _muted, fontWeight: FontWeight.w700),
                                      ),
                                    ]),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        );
                      }),
                    ],
                  ],
                ),
              );
            },
          ),
      ],
      ),
    );
  }

  Widget _buildPhotosTab() {
    return Column(
      children: [
        // Conditional banner
        Container(
          width: double.infinity,
          color: eventHasEnded ? eventColor : AppColors.greenPale,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(children: [
            Icon(
              eventHasEnded ? Icons.photo_library_outlined : Icons.camera_alt_outlined,
              color: eventHasEnded ? Colors.white : AppColors.green,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                eventHasEnded ? 'The event has ended! Share your photos below.' : 'Photos will be shared after the event ends.',
                style: TextStyle(color: eventHasEnded ? Colors.white : AppColors.green, fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          ]),
        ),
        Expanded(
          child: _isHostMode
              ? (uploadedPhotos.isEmpty
                  ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const Text('📷', style: TextStyle(fontSize: 48)),
                      const SizedBox(height: 12),
                      Text('No photos uploaded yet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : AppColors.dark)),
                      const SizedBox(height: 6),
                      Text('Photos added by guests appear here', style: TextStyle(fontSize: 13, color: _muted)),
                    ]))
                  : GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8),
                      itemCount: uploadedPhotos.length,
                      itemBuilder: (context, i) => Stack(
                        fit: StackFit.expand,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.network(uploadedPhotos[i], fit: BoxFit.cover),
                          ),
                          Positioned(
                            top: 4, right: 4,
                            child: GestureDetector(
                              onTap: () => setState(() => uploadedPhotos.removeAt(i)),
                              child: Container(
                                width: 24, height: 24,
                                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), shape: BoxShape.circle),
                                child: const Icon(Icons.close, size: 14, color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ))
              : !eventHasEnded
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('📸', style: TextStyle(fontSize: 48)),
                          const SizedBox(height: 16),
                          Text('No photos yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : AppColors.dark)),
                          const SizedBox(height: 8),
                          Text('Photos will appear here after the event', style: TextStyle(fontSize: 14, color: _muted)),
                        ],
                      ),
                    )
                  : Column(
                      children: [
                        const SizedBox(height: 24),
                        const Text('📷', style: TextStyle(fontSize: 56)),
                        const SizedBox(height: 16),
                        Text('8 photos shared', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
                        const SizedBox(height: 8),
                        Text('Tap below to view and add photos', style: TextStyle(fontSize: 14, color: _muted)),
                        const SizedBox(height: 28),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 40),
                          child: ElevatedButton.icon(
                            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PictureWallScreen(eventId: widget.eventId ?? '', eventTitle: eventTitle))),
                            icon: const Icon(Icons.photo_library_outlined),
                            label: const Text('Open Picture Wall', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.purple,
                              foregroundColor: Colors.white,
                              minimumSize: const Size(double.infinity, 52),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                          ),
                        ),
                      ],
                    ),
        ),
      ],
    );
  }

  Widget _statBox(String number, String label, Color color, {VoidCallback? onTap}) {
    final inner = Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(14), border: Border.all(color: color.withOpacity(0.2))),
      child: Column(
        children: [
          Text(number, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: color)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: color.withOpacity(0.8))),
        ],
      ),
    );
    return Expanded(
      child: onTap == null
          ? inner
          : Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: InkWell(onTap: onTap, child: inner),
            ),
    );
  }

  Future<void> _showWaitlistSheet() async {
    final fg = _isDark ? Colors.white : AppColors.dark;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: _border, borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 18),
              Row(children: [
                const Icon(Icons.hourglass_bottom, color: _purple, size: 22),
                const SizedBox(width: 8),
                Text('Waitlist (${_waitlist.length})', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: fg)),
              ]),
              const SizedBox(height: 6),
              Text('Listed in the order they joined. The first person is notified when a spot opens.',
                  style: TextStyle(fontSize: 12, color: _muted)),
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.5),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _waitlist.length,
                  separatorBuilder: (_, __) => Divider(color: _border, height: 1),
                  itemBuilder: (_, i) {
                    final w = _waitlist[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(children: [
                        Container(
                          width: 28, height: 28,
                          decoration: BoxDecoration(color: _purple.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(14)),
                          child: Center(child: Text('${i + 1}', style: const TextStyle(color: _purple, fontWeight: FontWeight.w700, fontSize: 13))),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(w['name'] as String, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: fg)),
                          if ((w['email'] as String).isNotEmpty)
                            Text(w['email'] as String, style: TextStyle(fontSize: 12, color: _muted)),
                        ])),
                      ]),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showRsvpBreakdown(String status) async {
    final guests = _rsvps.where((g) => g['status'] == status).toList();
    final totalAdults   = guests.fold<int>(0, (s, g) => s + ((g['adults']   as int?) ?? 1));
    final totalChildren = guests.fold<int>(0, (s, g) => s + ((g['children'] as int?) ?? 0));
    final totalPlusOnes = guests.fold<int>(0, (s, g) => s + ((g['plusOnes'] as int?) ?? 0));
    final totalPeople   = totalAdults + totalChildren + totalPlusOnes;
    final statusColor   = status == 'Yes' ? AppColors.green : AppColors.gold;
    final fg            = _isDark ? Colors.white : AppColors.dark;
    final statusLabel   = status == 'Yes' ? 'Going' : 'Maybe';
    final statusIcon    = status == 'Yes' ? Icons.check_circle : Icons.help_outline;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: _border, borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 18),
              Row(children: [
                Icon(statusIcon, color: statusColor, size: 22),
                const SizedBox(width: 8),
                Text(statusLabel, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: fg)),
              ]),
              const SizedBox(height: 18),
              _breakdownRow('Total RSVPs', '${guests.length}', statusColor, fg),
              const SizedBox(height: 12),
              _breakdownRow('Adults', '$totalAdults', fg, fg),
              const SizedBox(height: 12),
              _breakdownRow('Children', '$totalChildren', fg, fg),
              if (totalPlusOnes > 0) ...[
                const SizedBox(height: 12),
                _breakdownRow('Plus ones', '$totalPlusOnes', fg, fg),
              ],
              const SizedBox(height: 16),
              Divider(color: _border, height: 1),
              const SizedBox(height: 16),
              _breakdownRow('Total people', '$totalPeople', statusColor, fg, emphasize: true),
            ],
          ),
        ),
      ),
    );
  }

  Widget _breakdownRow(String label, String value, Color valueColor, Color labelColor, {bool emphasize = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: emphasize ? 16 : 14,
            fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500,
            color: labelColor,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: emphasize ? 22 : 18,
            fontWeight: FontWeight.w800,
            color: valueColor,
          ),
        ),
      ],
    );
  }

  Future<void> _saveClaimToFirestore(int itemIndex, String amount, {bool buying = false}) async {
    if (widget.eventId == null) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => _savingClaim = true);
    final eventRef = FirebaseFirestore.instance.collection('events').doc(widget.eventId);
    // Build the claim payload once so the transaction write and the
    // local optimistic update can't drift. `buying: true` flips the
    // "buying it" badge on the item card; only set when the guest
    // tapped "Buy & Bring", otherwise we omit the field entirely so
    // legacy items don't grow a `buying: false` shadow on every
    // re-claim. The `amount` may be downgraded inside the
    // transaction if a concurrent claim raised the total past the
    // host's quantityNeeded — chip caps prevent this on the UI
    // side, but two guests racing the same item could both see
    // remaining = N and both confirm; the server-side guard is the
    // last line of defense.
    Map<String, dynamic> claim = <String, dynamic>{
      'uid': user.uid,
      'name': user.displayName ?? 'Guest',
      'amount': amount,
      if (buying) 'buying': true,
    };
    bool cappedByServer = false;

    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(eventRef);
        final rawWishlist = List<Map<String, dynamic>>.from(
          (snap.data()?['wishlist'] as List<dynamic>? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
        );
        final item = rawWishlist[itemIndex];
        final claims = List<Map<String, dynamic>>.from(
          item['claims'] as List<dynamic>? ?? [],
        );
        // Quantity guard: if the host set a quantityNeeded, sum
        // every other guest's claim and cap the new claim's amount
        // to whatever's left. If nothing's left, abort outright so
        // we don't write a 0-amount claim that just clutters the
        // claims list.
        final cap = _itemQuantityNeeded(item);
        if (cap != null) {
          final othersTotal = claims
              .where((c) => c['uid'] != user.uid)
              .fold<int>(0, (s, c) => s + _claimAmountValue((c as Map?)?['amount'] as String?));
          final remaining = (cap - othersTotal).clamp(0, cap);
          if (remaining <= 0) {
            throw StateError('fully-claimed');
          }
          final requested = _claimAmountValue(amount);
          if (requested > remaining) {
            // Snap to the largest preset that fits. '6+' (=6) only
            // gets to land if remaining >= 6; otherwise the largest
            // single-digit preset that fits.
            final downgraded = remaining >= 6 ? '6+' : remaining.toString();
            claim = <String, dynamic>{
              ...claim,
              'amount': downgraded,
            };
            cappedByServer = true;
          }
        }
        claims.removeWhere((c) => c['uid'] == user.uid);
        claims.add(claim);
        rawWishlist[itemIndex]['claims'] = claims;
        rawWishlist[itemIndex]['claimed'] = claims.length;
        tx.update(eventRef, {'wishlist': rawWishlist});
      });

      if (mounted) {
        setState(() {
          final claims = List<Map<String, dynamic>>.from(wishlistItems[itemIndex]['claims'] as List);
          claims.removeWhere((c) => c['uid'] == user.uid);
          claims.add(claim);
          wishlistItems[itemIndex]['claims'] = claims;
          wishlistItems[itemIndex]['claimed'] = claims.length;
          _activeClaimIndex = null;
          _activeClaimQty = '1';
          _activeClaimManualMode = false;
          _claimManualCtrl.clear();
        });
        if (cappedByServer) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Claim adjusted to ${claim['amount']} — only that many were left.'),
            backgroundColor: AppColors.gold,
          ));
        }
      }
      // Notify the host that a guest claimed a checklist item. Sits
      // INSIDE the try success path so the fully-claimed StateError
      // (thrown inside the transaction when remaining == 0) skips
      // straight to the catch below without firing a misleading push.
      // Same guest-name pattern as the RSVP notification.
      final guestName = user.displayName ?? user.email?.split('@').first ?? 'A guest';
      final itemName = (wishlistItems[itemIndex]['name'] as String?) ?? 'an item';
      _notifyHost(
        'Checklist Claim ✅',
        '$guestName claimed $itemName on $eventTitle',
      );
    } catch (e) {
      if (e is StateError && e.message == 'fully-claimed') {
        if (mounted) {
          setState(() {
            _activeClaimIndex = null;
            _activeClaimQty = '1';
            _activeClaimManualMode = false;
            _claimManualCtrl.clear();
          });
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Someone else just claimed the last one.'),
            backgroundColor: Colors.redAccent,
          ));
        }
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save: $e'), backgroundColor: Colors.redAccent),
        );
      }
    } finally {
      if (mounted) setState(() => _savingClaim = false);
    }
  }

  /// Removes the current user's claim from the item at [itemIndex].
  /// Mirror of _saveClaimToFirestore but it strips the entry rather
  /// than upserting it, then bumps `claimed` down to the new claims
  /// length. No-op when the user has no claim on the item (anyone
  /// else's claim row doesn't surface the Undo button — the UI
  /// gates on uid match — so this should only ever be invoked when
  /// the row exists).
  Future<void> _unclaimFromFirestore(int itemIndex) async {
    if (widget.eventId == null) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => _savingClaim = true);
    final eventRef = FirebaseFirestore.instance.collection('events').doc(widget.eventId);

    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(eventRef);
        final rawWishlist = List<Map<String, dynamic>>.from(
          (snap.data()?['wishlist'] as List<dynamic>? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
        );
        final claims = List<Map<String, dynamic>>.from(
          rawWishlist[itemIndex]['claims'] as List<dynamic>? ?? [],
        );
        claims.removeWhere((c) => c['uid'] == user.uid);
        rawWishlist[itemIndex]['claims'] = claims;
        rawWishlist[itemIndex]['claimed'] = claims.length;
        tx.update(eventRef, {'wishlist': rawWishlist});
      });

      if (mounted) {
        setState(() {
          final claims = List<Map<String, dynamic>>.from(wishlistItems[itemIndex]['claims'] as List);
          claims.removeWhere((c) => c['uid'] == user.uid);
          wishlistItems[itemIndex]['claims'] = claims;
          wishlistItems[itemIndex]['claimed'] = claims.length;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not undo claim: $e'), backgroundColor: Colors.redAccent),
        );
      }
    } finally {
      if (mounted) setState(() => _savingClaim = false);
    }
  }

  Widget _rsvpButton(String label, Color color, {bool disabled = false}) {
    final isSelected = _pendingStatus == label;
    return ElevatedButton(
      onPressed: (_savingRsvp || disabled) ? null : () => setState(() => _pendingStatus = label),
      style: ElevatedButton.styleFrom(
        backgroundColor: isSelected ? color : Colors.grey.shade100,
        foregroundColor: isSelected ? Colors.white : AppColors.muted,
        disabledBackgroundColor: Colors.grey.shade100,
        disabledForegroundColor: Colors.grey.shade400,
        elevation: 0,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }
}

class ViewFullEventScreen extends StatelessWidget {
  const ViewFullEventScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Event Details'), backgroundColor: Colors.white, elevation: 0),
        body: const Center(child: Text('Screen 5 — View Full Event\n(Coming soon)', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted))),
        bottomNavigationBar: debugLabel('Screen 5 — Host View'),
      );
}

class OrderPrintsScreen extends StatelessWidget {
  const OrderPrintsScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Order Prints'), backgroundColor: Colors.white, elevation: 0),
        body: const Center(child: Text('Screen 6 — Order Prints\n(Coming soon)', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted))),
        bottomNavigationBar: debugLabel('Screen 6 — Host View'),
      );
}
