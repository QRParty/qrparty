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
const bool kTestingMode = true;

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
  String _pendingStatus = 'Not Responded';
  int adults = 1;
  int children = 0;
  int plusOnes = 0;
  final TextEditingController _plusOnesController = TextEditingController(text: '0');
  List<String> uploadedPhotos = [];

  bool _allowPlusOnes = false;
  int? _maxPlusOnes;

  late String eventTitle;
  late String eventDate;
  late String eventLocation;
  late String eventEmoji;
  late Color eventColor;
  late bool eventHasEnded;
  bool _isHost = false;
  bool _isCoHost = false;
  bool _isHostMode = false;
  bool _isArchived = false;
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
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(_hostId).get();
      final token = doc.data()?['fcmToken'] as String?;
      if (token != null) {
        await NotificationService.sendNotification([token], title, body, eventId: widget.eventId);
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
  final TextEditingController _claimAmountController = TextEditingController();
  bool _savingClaim = false;

  double get totalWishlistValue => wishlistItems.fold(0, (sum, i) => sum + (i['price'] as double));
  double get totalContributed => wishlistItems.fold(0, (sum, i) => sum + (i['contributed'] as double));

  @override
  void initState() {
    super.initState();
    _initEventData(); // must run first to set listType
    _tabController = TabController(length: listType == 'No List' ? 2 : 3, vsync: this);
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
      setState(() {
        _rsvps = snap.docs.map((doc) {
          final d = doc.data();
          return {
            'uid': doc.id,
            'name': (d['name'] as String?) ?? 'Guest',
            'status': (d['status'] as String?) ?? 'Not Responded',
            'adults': (d['adults'] as int?) ?? 1,
            'children': (d['children'] as int?) ?? 0,
            'plusOnes': (d['plusOnes'] as int?) ?? 0,
          };
        }).toList();
      });
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
    setState(() {
      final currentTotal = item['contributed'] as double;
      final remaining = price - currentTotal;
      final toAdd = amount > remaining ? remaining : amount;
      wishlistItems[index]['contributed'] = (currentTotal + toAdd).clamp(0.0, price);
    });
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
        final effectivePlusOnes = _allowPlusOnes ? plusOnes : 0;
        final newHeadcount = adults + children + effectivePlusOnes;

        tx.set(rsvpRef, {
          'uid': user.uid,
          'name': user.displayName ?? 'Guest',
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
        if (_allowPlusOnes && plusOnes > 0 && (newStatus == 'Yes' || newStatus == 'Maybe')) {
          msg = '$msg (+$plusOnes plus ${plusOnes == 1 ? 'one' : 'ones'})';
        }
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: AppColors.green));
        if (switchTab && listType == 'Checklist' && (newStatus == 'Yes' || newStatus == 'Maybe')) {
          _tabController.animateTo(1);
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
      eventTitle = (data['title'] as String?) ?? 'Event';
      eventEmoji = (data['eventEmoji'] as String?) ?? '🎉';
      eventLocation = (data['location'] as String?) ?? 'Location TBD';

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

      _capacity = (data['capacity'] as num?)?.toInt();
      _allowWaitlist = (data['allowWaitlist'] as bool?) ?? false;
      _allowPlusOnes = (data['allowPlusOnes'] as bool?) ?? false;
      _maxPlusOnes = (data['maxPlusOnes'] as num?)?.toInt();

      final typeName = (data['eventType'] as String?) ?? '';
      final matchedType = eventTypes.firstWhere((t) => t.name == typeName, orElse: () => eventTypes.last);
      eventColor = matchedType.primary;

      listType = (data['listType'] as String?) ?? 'Wishlist';

      final rawWishlist = data['wishlist'] as List<dynamic>? ?? [];
      wishlistItems = rawWishlist.map((item) {
        final m = item as Map<String, dynamic>;
        if (listType == 'Checklist') {
          final rawClaims = m['claims'] as List<dynamic>? ?? [];
          return {
            'name': m['name'] as String? ?? '',
            'quantity': m['quantity']?.toString() ?? '',
            'claimed': (m['claimed'] as num?)?.toInt() ?? 0,
            'claims': rawClaims.map((c) => Map<String, dynamic>.from(c as Map)).toList(),
          };
        }
        return {
          'name': m['name'] as String? ?? '',
          'price': (m['price'] as num?)?.toDouble() ?? 0.0,
          'contributed': (m['contributed'] as num?)?.toDouble() ?? 0.0,
          'bought': m['bought'] as bool? ?? false,
        };
      }).toList();
    } else {
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
    }
  }

  @override
  void dispose() {
    _rsvpsSub?.cancel();
    _waitlistSub?.cancel();
    _contribSub?.cancel();
    _tabController.dispose();
    _welcomeCtrl.dispose();
    _claimAmountController.dispose();
    _plusOnesController.dispose();
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
        title: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: eventColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
            child: Center(child: Text(eventEmoji, style: const TextStyle(fontSize: 20))),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(eventTitle, style: TextStyle(fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark, fontSize: 16))),
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
          labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          tabs: [
            const Tab(text: 'Info & RSVP'),
            if (listType != 'No List') Tab(text: listType == 'Checklist' ? 'Checklist' : 'Wishlist'),
            const Tab(text: 'Photos'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildInfoTab(),
          if (listType != 'No List') _buildWishlistTab(),
          _buildPhotosTab(),
        ],
      ),
      bottomNavigationBar: widget.isOnboarding ? _buildOnboardingBanner() : debugLabel('Screen 10 — Guest View'),
        ),
        if (_showWelcome) _buildWelcomeOverlay(),
      ],
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
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (!_isHostMode) ...[
                  _buildWeatherWidget(),
                  if (_weatherLoading || _weatherData != null) const SizedBox(height: 16),
                ],
                // RSVP counts as a single row of stat boxes. Hosts/co-hosts can
                // tap Yes / Maybe to see an adults+children breakdown; the No
                // tile and all tiles for regular guests render as plain text.
                Row(children: [
                  _statBox(
                    '${_rsvps.where((g) => g['status'] == 'Yes').length}',
                    'Going',
                    AppColors.green,
                    onTap: (_isHost || _isCoHost) ? () => _showRsvpBreakdown('Yes') : null,
                  ),
                  const SizedBox(width: 8),
                  _statBox(
                    '${_rsvps.where((g) => g['status'] == 'Maybe').length}',
                    'Maybe',
                    AppColors.gold,
                    onTap: (_isHost || _isCoHost) ? () => _showRsvpBreakdown('Maybe') : null,
                  ),
                  const SizedBox(width: 8),
                  _statBox('${_rsvps.where((g) => g['status'] == 'No').length}', "Can't go", Colors.redAccent),
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
                          Text('Will you attend?', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            if (_rsvpDeadlineLabel.isNotEmpty) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(color: const Color(0xFFFFF8E1), borderRadius: BorderRadius.circular(20)),
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  const Icon(Icons.schedule, size: 12, color: AppColors.gold),
                                  const SizedBox(width: 4),
                                  Text('By $_rsvpDeadlineLabel', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.gold)),
                                ]),
                              ),
                              if (rsvpStatus == 'Yes') const SizedBox(width: 8),
                            ],
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
                        ]),
                        const SizedBox(height: 14),
                        Builder(builder: (_) {
                          final yesHeadcount = _rsvps
                              .where((g) => g['status'] == 'Yes')
                              .fold<int>(0, (sum, g) => sum + ((g['adults'] as int? ?? 1) + (g['children'] as int? ?? 0) + (g['plusOnes'] as int? ?? 0)));
                          final cap = _capacity;
                          final isFull = cap != null && yesHeadcount >= cap && rsvpStatus != 'Yes';
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
                          if (_allowPlusOnes) ...[
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
                // Host announcements
                Text('Announcements', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
                const SizedBox(height: 10),
                _announcementCard("Don't forget to bring a gift! 🎁", '2 hours ago'),
                _announcementCard("Parking is available on Celebration Lane 🚗", 'Yesterday'),
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
    final data = widget.eventData;
    if (data == null) return;
    final ts = data['date'];
    if (ts is! Timestamp) return;

    final eventDay = () {
      final d = ts.toDate();
      return DateTime(d.year, d.month, d.day);
    }();
    final today = () {
      final n = DateTime.now();
      return DateTime(n.year, n.month, n.day);
    }();
    final daysUntil = eventDay.difference(today).inDays;
    if (daysUntil < 0 || daysUntil > 7) return;

    if (mounted) setState(() => _weatherLoading = true);
    try {
      // Prefer explicit zipCode field; fall back to parsing location string
      final raw = (data['zipCode'] as String?)?.trim();
      final query = (raw != null && raw.isNotEmpty)
          ? raw
          : _extractCity((data['location'] as String?) ?? '');
      if (query.isEmpty) return;

      final geoUri = Uri.parse(
        'https://geocoding-api.open-meteo.com/v1/search'
        '?name=${Uri.encodeQueryComponent(query)}&count=1&language=en&format=json',
      );
      final geoRes = await http.get(geoUri).timeout(const Duration(seconds: 8));
      if (geoRes.statusCode != 200) return;
      final geoJson = jsonDecode(geoRes.body) as Map<String, dynamic>;
      final results = geoJson['results'] as List<dynamic>?;
      if (results == null || results.isEmpty) return;

      final lat = (results[0]['latitude'] as num).toDouble();
      final lon = (results[0]['longitude'] as num).toDouble();
      final dateStr =
          '${eventDay.year}-${eventDay.month.toString().padLeft(2, '0')}-${eventDay.day.toString().padLeft(2, '0')}';

      final wxUri = Uri.parse(
        'https://api.open-meteo.com/v1/forecast'
        '?latitude=$lat&longitude=$lon'
        '&daily=weather_code,temperature_2m_max,temperature_2m_min'
        '&temperature_unit=fahrenheit&timezone=auto'
        '&start_date=$dateStr&end_date=$dateStr',
      );
      final wxRes = await http.get(wxUri).timeout(const Duration(seconds: 8));
      if (wxRes.statusCode != 200) return;
      final wxJson = jsonDecode(wxRes.body) as Map<String, dynamic>;
      final daily = wxJson['daily'] as Map<String, dynamic>?;
      if (daily == null) return;

      final codes = daily['weather_code'] as List<dynamic>;
      final maxTemps = daily['temperature_2m_max'] as List<dynamic>;
      final minTemps = daily['temperature_2m_min'] as List<dynamic>;
      if (codes.isEmpty) return;

      final code = (codes[0] as num).toInt();
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
    } catch (_) {
      if (mounted) setState(() => _weatherLoading = false);
    }
  }

  String _extractCity(String location) {
    final parts = location.split(',');
    if (parts.length >= 2) return parts[parts.length - 2].trim();
    return location.trim();
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

    final yesGuests = _rsvps.where((g) => g['status'] == 'Yes').toList();
    final maybeGuests = _rsvps.where((g) => g['status'] == 'Maybe').toList();
    final noGuests = _rsvps.where((g) => g['status'] == 'No').toList();
    final totalPeople = _rsvps.fold<int>(0, (s, g) => s + (g['adults'] as int) + (g['children'] as int));

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
        Text('Guest List (${_rsvps.length})', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
        const Spacer(),
        if (totalPeople > 0)
          Text('$totalPeople people total', style: TextStyle(fontSize: 12, color: _muted)),
      ]),
      const SizedBox(height: 6),
      if (_rsvps.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Center(child: Text('No RSVPs yet', style: TextStyle(color: _muted, fontSize: 14))),
        )
      else ...[
        if (yesGuests.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Going (${yesGuests.fold(0, (s, g) => s + (g['adults'] as int) + (g['children'] as int))})', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.green, letterSpacing: 0.4)),
          const SizedBox(height: 6),
          ...yesGuests.map(guestRow),
        ],
        if (maybeGuests.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Maybe (${maybeGuests.fold(0, (s, g) => s + (g['adults'] as int) + (g['children'] as int))})', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.gold, letterSpacing: 0.4)),
          const SizedBox(height: 6),
          ...maybeGuests.map(guestRow),
        ],
        if (noGuests.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text("Can't Go (${noGuests.fold(0, (s, g) => s + (g['adults'] as int) + (g['children'] as int))})", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.redAccent, letterSpacing: 0.4)),
          const SizedBox(height: 6),
          ...noGuests.map(guestRow),
        ],
      ],
    ]);
  }

  Widget _buildGuestAvatarRow() {
    return SizedBox(
      height: 72,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _rsvps.length,
        itemBuilder: (context, i) {
          final guest = _rsvps[i];
          final name = guest['name'] as String;
          final status = guest['status'] as String;
          final initials = name.trim().split(' ').take(2).map((p) => p.isNotEmpty ? p[0].toUpperCase() : '').join();
          final Color dotColor = status == 'Yes' ? AppColors.green : status == 'Maybe' ? AppColors.gold : Colors.redAccent;
          final adults = guest['adults'] as int;
          final children = guest['children'] as int;
          final peopleLabel = children == 0 ? '$adults adult${adults == 1 ? '' : 's'}' : '$adults + $children';
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
                      const SizedBox(height: 6),
                      Text(peopleLabel, style: TextStyle(fontSize: 13, color: _muted)),
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
          Wrap(spacing: 8, runSpacing: 6, alignment: WrapAlignment.end, children: [
            if (price != null && remaining != null && remaining > 0)
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
    if (listType == 'Checklist') return _buildChecklistTab();

    // ── Wishlist mode ──
    final fulfilledCount = wishlistItems.where((i) =>
      i['bought'] == true || (i['contributed'] as double) >= (i['price'] as double)).length;
    return Stack(
      children: [
      // SingleChildScrollView wraps the whole wishlist body so the fixed-height
      // banners + header can't overflow the RenderFlex when the keyboard opens
      // and shrinks the viewport. The inner ListView.builder becomes shrinkWrap
      // with no physics of its own — the outer scroll view owns scrolling.
      SingleChildScrollView(
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
                Text('$fulfilledCount of ${wishlistItems.length}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _isDark ? Colors.white : AppColors.dark)),
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
                child: Text('$fulfilledCount/${wishlistItems.length} fulfilled', style: const TextStyle(fontSize: 12, color: AppColors.green, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
        // Items shared into the event via the Android share sheet — separate
        // subcollection from the host-defined wishlist array. Hidden entirely
        // when nothing's been shared, so it adds zero noise for events that
        // never receive external shares.
        _buildSharedFromWebSection(),
        ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(16, 16, 16, _cart.isEmpty ? 16 : 88),
            itemCount: wishlistItems.length,
            itemBuilder: (context, index) {
              final itemIdx = index;
              final item = wishlistItems[itemIdx];
              final isBought = item['bought'] as bool;
              final price = item['price'] as double;
              final totalContrib = item['contributed'] as double;
              final myContrib = _myContributions[item['name'] as String] ?? 0.0;
              final totalProgress = (totalContrib / price).clamp(0.0, 1.0);
              final myProgress = (myContrib / price).clamp(0.0, 1.0);
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
                        if (isBought)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(100)),
                            child: const Text('Bought ✓', style: TextStyle(fontSize: 12, color: AppColors.muted, fontWeight: FontWeight.w600)),
                          )
                        else
                          Text('\$${(item['price'] as double).toStringAsFixed(2)}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : AppColors.dark)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        height: 8,
                        child: Stack(
                          children: [
                            LinearProgressIndicator(
                              value: isBought ? 1.0 : totalProgress,
                              minHeight: 8,
                              backgroundColor: Colors.grey.shade100,
                              color: isBought ? Colors.grey.shade300 : AppColors.greenLight,
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
                    else
                    Row(
                      children: [
                        isBought || totalProgress >= 1.0
                            ? Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                                decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(8)),
                                child: const Text('Bought', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.muted)),
                              )
                            : ElevatedButton(
                                onPressed: _isArchived ? null : () => _toggleBuy(itemIdx),
                                style: ElevatedButton.styleFrom(backgroundColor: _isArchived ? Colors.grey.shade300 : AppColors.green, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                                child: const Text('Buy', style: TextStyle(fontSize: 11)),
                              ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Row(
                            children: [20, 40, 60].map((amt) {
                              final remaining = price - totalContrib;
                              final effectiveAmt = amt.toDouble() > remaining ? remaining : amt.toDouble();
                              final isDisabled = _isArchived || isBought || totalProgress >= 1.0 || remaining <= 0;
                              return Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 3),
                                  child: OutlinedButton(
                                    onPressed: isDisabled ? null : () {
                                      _addToCart(item['name'] as String, effectiveAmt);
                                      _contributeFirestore(itemIdx, amt.toDouble());
                                    },
                                    style: OutlinedButton.styleFrom(side: BorderSide(color: isDisabled ? Colors.grey.shade300 : AppColors.green), padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                                    child: Text('\$${effectiveAmt.toStringAsFixed(0)}', style: TextStyle(color: isDisabled ? Colors.grey.shade400 : AppColors.green, fontSize: 11)),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                        if (myContrib > 0) ...[
                          const SizedBox(width: 4),
                          GestureDetector(
                            onTap: () {
                              _removeFromCart(item['name'] as String);
                              _undoContributionFirestore(itemIdx);
                            },
                            child: Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6), decoration: BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.undo, size: 13, color: Colors.white)),
                          ),
                        ],
                      ],
                    ),
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
    final claimedCount = wishlistItems.where((i) => (i['claimed'] as int) > 0).length;
    // Wrap the whole checklist body in a scroll view so the fixed-height
    // banner + header can't overflow when the keyboard pops up to claim an item.
    return SingleChildScrollView(
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
                child: Text('$claimedCount/${wishlistItems.length} claimed', style: const TextStyle(fontSize: 12, color: AppColors.green, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
        ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            itemCount: wishlistItems.length,
            itemBuilder: (context, index) {
              final item = wishlistItems[index];
              final qty = item['quantity'] as String;
              final claims = List<Map<String, dynamic>>.from(item['claims'] as List? ?? []);
              final isActive = _activeClaimIndex == index;
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
                    // Header row: name + qty pill + button
                    Row(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(child: Text(item['name'] as String, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark))),
                              if (qty.isNotEmpty)
                                Container(
                                  margin: const EdgeInsets.only(left: 8),
                                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                                  decoration: BoxDecoration(color: AppColors.greenPale, borderRadius: BorderRadius.circular(100)),
                                  child: Text(qty, style: const TextStyle(fontSize: 12, color: AppColors.green, fontWeight: FontWeight.w600)),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        isActive
                            ? GestureDetector(
                                onTap: () => setState(() { _activeClaimIndex = null; _claimAmountController.clear(); }),
                                child: Icon(Icons.close, size: 20, color: _muted),
                              )
                            : ElevatedButton(
                                onPressed: () => setState(() { _activeClaimIndex = index; _claimAmountController.clear(); }),
                                style: ElevatedButton.styleFrom(backgroundColor: AppColors.green, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
                                child: const Text("I'll bring this", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                              ),
                      ],
                    ),
                    // Inline claim input
                    if (isActive) ...[
                      const SizedBox(height: 14),
                      Text('How much are you bringing?', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : AppColors.dark)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _claimAmountController,
                              autofocus: true,
                              decoration: InputDecoration(
                                hintText: qty.isNotEmpty ? 'e.g. $qty' : 'Enter amount',
                                hintStyle: TextStyle(color: _muted),
                                filled: true,
                                fillColor: _bg,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: _border)),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: _border)),
                                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.green, width: 1.5)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          ElevatedButton(
                            onPressed: _savingClaim
                                ? null
                                : () {
                                    final amount = _claimAmountController.text.trim();
                                    if (amount.isEmpty) return;
                                    _saveClaimToFirestore(index, amount);
                                  },
                            style: ElevatedButton.styleFrom(backgroundColor: AppColors.green, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
                            child: _savingClaim
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                : const Text('Confirm', style: TextStyle(fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    ],
                    // Claims list
                    if (claims.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      const Divider(height: 1),
                      const SizedBox(height: 10),
                      ...claims.map((c) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle_outline, size: 14, color: AppColors.green),
                            const SizedBox(width: 6),
                            Text(c['name'] as String, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : AppColors.dark)),
                            Text(' · ', style: TextStyle(color: _muted)),
                            Text(c['amount'] as String, style: TextStyle(fontSize: 13, color: _muted)),
                          ],
                        ),
                      )),
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

  Widget _announcementCard(String message, String time) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.purplePale,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.purple.withOpacity(0.15)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(color: AppColors.purple.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
              child: const Center(child: Icon(Icons.campaign_outlined, size: 16, color: AppColors.purple)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.dark)),
                  const SizedBox(height: 4),
                  Text(time, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                ],
              ),
            ),
          ],
        ),
      );

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

  Future<void> _saveClaimToFirestore(int itemIndex, String amount) async {
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
        claims.add({'uid': user.uid, 'name': user.displayName ?? 'Guest', 'amount': amount});
        rawWishlist[itemIndex]['claims'] = claims;
        rawWishlist[itemIndex]['claimed'] = claims.length;
        tx.update(eventRef, {'wishlist': rawWishlist});
      });

      if (mounted) {
        setState(() {
          final claims = List<Map<String, dynamic>>.from(wishlistItems[itemIndex]['claims'] as List);
          claims.removeWhere((c) => c['uid'] == user.uid);
          claims.add({'uid': user.uid, 'name': user.displayName ?? 'Guest', 'amount': amount});
          wishlistItems[itemIndex]['claims'] = claims;
          wishlistItems[itemIndex]['claimed'] = claims.length;
          _activeClaimIndex = null;
          _claimAmountController.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save: $e'), backgroundColor: Colors.redAccent),
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
