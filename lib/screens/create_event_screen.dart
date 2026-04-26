import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;
import '../utils.dart';
import 'generate_qr_screen.dart';
import 'home_feed_screen.dart';

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
const _gold        = Color(0xFFC8922A);

const _placesApiKey = 'AIzaSyAHONfmej_Ifpv8ui9nbCnCnQcweDzpqIc';

class CreateEventScreen extends StatefulWidget {
  final String? draftId;
  final Map<String, dynamic>? draftData;
  final Map<String, dynamic>? templateData;
  const CreateEventScreen({super.key, this.draftId, this.draftData, this.templateData});
  @override
  State<CreateEventScreen> createState() => _CreateEventScreenState();
}

// ── Short-code generator ────────────────────────────────────────
// 6-character uppercase alphanumeric code, deliberately omitting the
// ambiguous 0/O and 1/I pairs so codes can be typed off a printed
// invitation without confusion. 32^6 ≈ 1B keyspace — collision math
// is negligible for any realistic event volume.
const _shortCodeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
final _shortCodeRand = math.Random.secure();

String _generateShortCode() => List.generate(
      6,
      (_) => _shortCodeAlphabet[_shortCodeRand.nextInt(_shortCodeAlphabet.length)],
    ).join();

/// Generates a code, then queries Firestore for collisions and retries up
/// to 5 times. The window between the read and the next event create is
/// where two concurrent creates could land on the same code, but at
/// 1B/keyspace the probability is vanishingly small for the volumes
/// this app sees. If it ever becomes a real problem, switch to a
/// transactional reservation in a `shortCodes/{code}` collection.
Future<String> _allocateUniqueShortCode() async {
  for (var i = 0; i < 5; i++) {
    final code = _generateShortCode();
    final dup = await FirebaseFirestore.instance
        .collection('events')
        .where('shortCode', isEqualTo: code)
        .limit(1)
        .get();
    if (dup.docs.isEmpty) return code;
  }
  // Extremely unlikely; fall through with a fresh code rather than throw.
  // Worst case the host gets a duplicate and the secondary lookup returns
  // the first match — still functional.
  return _generateShortCode();
}

class _CreateEventScreenState extends State<CreateEventScreen> {
  int currentStep = 0;
  EventType? selectedEventType;
  DateTime? selectedDate;
  TimeOfDay? selectedTime;
  late TextEditingController titleController;
  final descController = TextEditingController();
  final locationController = TextEditingController();
  final newItemNameController = TextEditingController();
  final newItemPriceController = TextEditingController();
  final newItemQtyController = TextEditingController();
  String listType = 'Wishlist';
  bool _isPublic = false;
  DateTime? _rsvpDeadline;
  bool _isBusiness = false;
  // Full raw accountType from users/{uid}.accountType ('personal' | 'business' |
  // 'businessPlus'); stamped on every event this user creates so the personal
  // and business feeds can filter each other's events out.
  String? _accountType;
  final TextEditingController _coHostEmailController = TextEditingController();
  bool _lookingUpCoHost = false;
  String? _coHostError;
  final List<Map<String, dynamic>> _coHosts = [];

  // Set to true right before navigating to GenerateQRCodeScreen so the
  // back-press dialog doesn't prompt to save/discard a finalised event.
  bool _eventFinalized = false;

  List<Map<String, dynamic>> wishlistItems = [];

  String? _draftId;
  Timer? _draftTimer;

  int _templateRsvpOffsetDays = 0;
  List<Map<String, dynamic>> _templates = [];
  bool _templatesLoading = false;

  String _zipCode = '';
  List<Map<String, dynamic>> _suggestions = [];
  bool _fetchingSuggestions = false;
  Timer? _suggestionsDebounce;
  final _locationFocusNode = FocusNode();

  bool _isRecurring = false;
  String _recurrenceFrequency = 'weekly';
  DateTime? _recurrenceEndDate;

  // Capacity + waitlist state. _maxPlusOnes: 1, 2, or null = unlimited.
  bool _capacityEnabled = false;
  final TextEditingController _capacityController = TextEditingController();
  bool _allowPlusOnes = false;
  int? _maxPlusOnes = 1;
  bool _allowWaitlist = true;

  // Theme-aware color getters — resolve light vs dark variant from the current Theme.
  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;

  @override
  void initState() {
    super.initState();
    _draftId = widget.draftId;
    final d = widget.draftData;
    titleController = TextEditingController(text: d != null ? (d['title'] as String? ?? '') : '');
    if (d != null) {
      descController.text = (d['description'] as String?) ?? descController.text;
      locationController.text = (d['location'] as String?) ?? '';
      listType = (d['listType'] as String?) ?? 'Wishlist';
      final ts = d['date'] as Timestamp?;
      if (ts != null) selectedDate = ts.toDate();
      final timeStr = d['time'] as String?;
      if (timeStr != null) {
        final parts = timeStr.split(':');
        if (parts.length == 2) selectedTime = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
      }
      final typeName = d['eventType'] as String?;
      if (typeName != null) selectedEventType = eventTypes.firstWhere((t) => t.name == typeName, orElse: () => eventTypes.last);
      final rawList = d['wishlist'] as List<dynamic>? ?? [];
      wishlistItems = rawList.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      _isPublic = (d['isPublic'] as bool?) ?? false;
      final deadlineTs = d['rsvpDeadline'] as Timestamp?;
      if (deadlineTs != null) _rsvpDeadline = deadlineTs.toDate();
      _zipCode = (d['zipCode'] as String?) ?? '';
      final loadedCapacity = (d['capacity'] as num?)?.toInt();
      _capacityEnabled = loadedCapacity != null;
      if (loadedCapacity != null) _capacityController.text = '$loadedCapacity';
      _allowPlusOnes = (d['allowPlusOnes'] as bool?) ?? false;
      _maxPlusOnes   = (d['maxPlusOnes']   as num?)?.toInt();
      _allowWaitlist = (d['allowWaitlist'] as bool?) ?? true;
      _isRecurring = (d['isRecurring'] as bool?) ?? false;
      final rule = d['recurrenceRule'] as Map?;
      if (rule != null) {
        _recurrenceFrequency = (rule['frequency'] as String?) ?? 'weekly';
        final endTs = rule['endDate'] as Timestamp?;
        if (endTs != null) _recurrenceEndDate = endTs.toDate();
      }
      if (selectedEventType != null) currentStep = 1;
    } else if (widget.templateData != null) {
      final t = widget.templateData!;
      titleController.text = (t['title'] as String?) ?? '';
      descController.text = (t['description'] as String?) ?? '';
      listType = (t['listType'] as String?) ?? 'Wishlist';
      _isPublic = (t['isPublic'] as bool?) ?? false;
      final typeName = t['eventType'] as String?;
      if (typeName != null) {
        selectedEventType = eventTypes.firstWhere((e) => e.name == typeName, orElse: () => eventTypes.last);
      }
      final coHostEmails = List<String>.from(t['coHostEmails'] as List? ?? []);
      final coHostUids = List<String>.from(t['coHosts'] as List? ?? []);
      for (int i = 0; i < coHostUids.length && i < coHostEmails.length; i++) {
        _coHosts.add({'uid': coHostUids[i], 'email': coHostEmails[i]});
      }
      _templateRsvpOffsetDays = (t['rsvpDeadlineOffsetDays'] as int?) ?? 0;
      if (selectedEventType != null) currentStep = 1;
    }
    titleController.addListener(_onTitleChanged);
    _locationFocusNode.addListener(() {
      if (!_locationFocusNode.hasFocus) {
        Future.delayed(const Duration(milliseconds: 150), () {
          if (mounted) setState(() => _suggestions = []);
        });
      }
    });
    _checkBusinessAccount();
  }

  void _onTitleChanged() {
    setState(() {});
    if (titleController.text.isNotEmpty && _draftId == null) {
      _createDraft();
    } else if (_draftId != null) {
      _scheduleDraftSave();
    }
  }

  Future<void> _createDraft() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      // Ensure we know the user's accountType so we can stamp it on the event.
      // _checkBusinessAccount populates _accountType asynchronously; if the user
      // types fast enough to beat that, read the profile here so we don't fall
      // through to a stale default.
      if (_accountType == null) {
        final userDoc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
        final fetched = (userDoc.data()?['accountType'] as String?) ?? 'personal';
        if (mounted) setState(() => _accountType = fetched);
      }
      final acctType = _accountType ?? 'personal';

      // Allocate a unique short code BEFORE writing the doc so it's
      // guaranteed present from creation through publish — guests typing
      // partywithqr.com/event/XXXXXX work even if the host is still editing
      // a draft.
      final shortCode = await _allocateUniqueShortCode();

      final docRef = await FirebaseFirestore.instance.collection('events').add({
        'isDraft': true,
        'title': titleController.text,
        'hostId': user.uid,
        'hostName': user.displayName ?? 'Host',
        'accountType': acctType,
        'shortCode': shortCode,
        'yes': 0, 'maybe': 0, 'no': 0,
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) setState(() => _draftId = docRef.id);
    } catch (_) {}
  }

  void _scheduleDraftSave() {
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 600), _saveDraftNow);
  }

  Future<void> _saveDraftNow() async {
    if (_draftId == null) return;
    try {
      await FirebaseFirestore.instance.collection('events').doc(_draftId).update({
        'accountType': _accountType ?? 'personal',
        'title': titleController.text,
        'description': descController.text,
        'location': locationController.text,
        'date': selectedDate != null ? Timestamp.fromDate(selectedDate!) : null,
        'time': selectedTime != null ? '${selectedTime!.hour}:${selectedTime!.minute}' : null,
        'eventType': selectedEventType?.name,
        'eventEmoji': selectedEventType?.emoji,
        'listType': listType,
        'isPublic': _isPublic,
        'rsvpDeadline': _rsvpDeadline != null ? Timestamp.fromDate(_rsvpDeadline!) : null,
        'zipCode': _zipCode,
        'coHosts': _coHosts.map((c) => c['uid'] as String).toList(),
        'isRecurring': _isRecurring && _isBusiness,
        'recurrenceRule': (_isRecurring && _isBusiness) ? _buildRecurrenceRule() : null,
        'capacity': _capacityEnabled ? int.tryParse(_capacityController.text.trim()) : null,
        'allowPlusOnes': _allowPlusOnes,
        'maxPlusOnes': _allowPlusOnes ? _maxPlusOnes : null,
        'allowWaitlist': _capacityEnabled ? _allowWaitlist : false,
        'wishlist': wishlistItems.map((item) => listType == 'Checklist'
            ? {'name': item['name'], 'quantity': item['quantity'], 'claimed': 0}
            : {'name': item['name'], 'price': item['price'], 'contributed': 0.0, 'bought': false}).toList(),
      });
    } catch (_) {}
  }

  Map<String, dynamic> _buildRecurrenceRule() {
    final rule = <String, dynamic>{'frequency': _recurrenceFrequency};
    if (_recurrenceFrequency == 'weekly' || _recurrenceFrequency == 'biweekly') {
      // 0 = Sunday, 6 = Saturday (JS convention, used by the Cloud Function)
      rule['dayOfWeek'] = (selectedDate?.weekday ?? DateTime.monday) % 7;
    }
    if (_recurrenceFrequency == 'monthly') {
      rule['dayOfMonth'] = selectedDate?.day ?? 1;
    }
    rule['endDate'] = _recurrenceEndDate != null ? Timestamp.fromDate(_recurrenceEndDate!) : null;
    return rule;
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    _suggestionsDebounce?.cancel();
    titleController.removeListener(_onTitleChanged);
    titleController.dispose();
    descController.dispose();
    locationController.dispose();
    _locationFocusNode.dispose();
    newItemNameController.dispose();
    newItemPriceController.dispose();
    newItemQtyController.dispose();
    _coHostEmailController.dispose();
    _capacityController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime.now(), lastDate: DateTime(2027));
    if (picked != null) {
      setState(() {
        selectedDate = picked;
        if (_templateRsvpOffsetDays > 0 && _rsvpDeadline == null) {
          _rsvpDeadline = picked.subtract(Duration(days: _templateRsvpOffsetDays));
        }
      });
      _scheduleDraftSave();
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (picked != null) { setState(() => selectedTime = picked); _scheduleDraftSave(); }
  }

  Future<void> _pickRsvpDeadline() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _rsvpDeadline ?? now.add(const Duration(days: 7)),
      firstDate: now,
      lastDate: selectedDate ?? DateTime(2027),
      helpText: 'Select RSVP deadline',
    );
    if (picked != null) {
      setState(() => _rsvpDeadline = picked);
      _scheduleDraftSave();
      if (mounted) {
        final months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
        final label = '${months[picked.month - 1]} ${picked.day}, ${picked.year}';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Guests have until $label to RSVP'), duration: const Duration(seconds: 3)),
        );
      }
    }
  }

  Future<void> _checkBusinessAccount() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      final data = doc.data();
      if (data != null && mounted) {
        final acctType = data['accountType'] as String?;
        final isBiz = acctType == 'business' && data['isTrialing'] != true;
        setState(() {
          _isBusiness = isBiz;
          _accountType = acctType ?? 'personal';
        });
        if (isBiz) _loadTemplates();
      }
    } catch (_) {}
  }

  Future<void> _loadTemplates() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (mounted) setState(() => _templatesLoading = true);
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('templates')
          .orderBy('createdAt', descending: true)
          .get();
      if (mounted) {
        setState(() {
          _templates = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
          _templatesLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _templatesLoading = false);
    }
  }

  void _showTemplatePicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TemplatePickerSheet(
        templates: _templates,
        onPicked: _applyTemplateFromPicker,
        onDeleted: (templateId) async {
          final user = FirebaseAuth.instance.currentUser;
          if (user == null) return;
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .collection('templates')
              .doc(templateId)
              .delete();
          if (mounted) setState(() => _templates.removeWhere((t) => t['id'] == templateId));
        },
      ),
    );
  }

  void _applyTemplateFromPicker(Map<String, dynamic> t) {
    setState(() {
      titleController.text = (t['title'] as String?) ?? '';
      descController.text = (t['description'] as String?) ?? '';
      listType = (t['listType'] as String?) ?? 'Wishlist';
      _isPublic = (t['isPublic'] as bool?) ?? false;
      final typeName = t['eventType'] as String?;
      if (typeName != null) {
        selectedEventType = eventTypes.firstWhere((e) => e.name == typeName, orElse: () => eventTypes.last);
      }
      _coHosts.clear();
      final coHostEmails = List<String>.from(t['coHostEmails'] as List? ?? []);
      final coHostUids = List<String>.from(t['coHosts'] as List? ?? []);
      for (int i = 0; i < coHostUids.length && i < coHostEmails.length; i++) {
        _coHosts.add({'uid': coHostUids[i], 'email': coHostEmails[i]});
      }
      _templateRsvpOffsetDays = (t['rsvpDeadlineOffsetDays'] as int?) ?? 0;
      _rsvpDeadline = null;
      if (selectedEventType != null) currentStep = 1;
    });
  }

  Future<void> _fetchSuggestions(String input) async {
    if (input.length < 3) {
      if (mounted) setState(() { _suggestions = []; _fetchingSuggestions = false; });
      return;
    }
    if (mounted) setState(() => _fetchingSuggestions = true);
    try {
      final uri = Uri.https('maps.googleapis.com', '/maps/api/place/autocomplete/json', {
        'input': input,
        'types': 'address',
        'key': _placesApiKey,
      });
      final response = await http.get(uri);
      if (!mounted) return;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final preds = (data['predictions'] as List? ?? []).cast<Map<String, dynamic>>();
      setState(() {
        _suggestions = preds.take(5).toList();
        _fetchingSuggestions = false;
      });
    } catch (_) {
      if (mounted) setState(() { _suggestions = []; _fetchingSuggestions = false; });
    }
  }

  Future<void> _selectSuggestion(Map<String, dynamic> prediction) async {
    final placeId = prediction['place_id'] as String? ?? '';
    final description = prediction['description'] as String? ?? '';
    setState(() {
      locationController.text = description;
      _suggestions = [];
      _zipCode = '';
      _fetchingSuggestions = false;
    });
    _suggestionsDebounce?.cancel();
    if (placeId.isEmpty) { _scheduleDraftSave(); return; }
    try {
      final uri = Uri.https('maps.googleapis.com', '/maps/api/place/details/json', {
        'place_id': placeId,
        'fields': 'formatted_address,address_components',
        'key': _placesApiKey,
      });
      final response = await http.get(uri);
      if (!mounted) return;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final result = data['result'] as Map<String, dynamic>?;
      if (result != null) {
        final formatted = result['formatted_address'] as String? ?? description;
        locationController.text = formatted;
        final comps = result['address_components'] as List? ?? [];
        for (final comp in comps) {
          final types = List<String>.from((comp as Map)['types'] as List? ?? []);
          if (types.contains('postal_code')) {
            setState(() => _zipCode = (comp['long_name'] as String?) ?? '');
            break;
          }
        }
      }
    } catch (_) {}
    _scheduleDraftSave();
  }

  Future<void> _addCoHost() async {
    final email = _coHostEmailController.text.trim().toLowerCase();
    if (email.isEmpty) return;
    if (_coHosts.any((c) => c['email'] == email)) {
      setState(() => _coHostError = 'Already added');
      return;
    }
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser?.email?.toLowerCase() == email) {
      setState(() => _coHostError = "You're the host");
      return;
    }
    setState(() { _lookingUpCoHost = true; _coHostError = null; });
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .where('email', isEqualTo: email)
          .limit(1)
          .get();
      if (snap.docs.isEmpty) {
        setState(() => _coHostError = 'No account found with that email');
      } else {
        final uid = snap.docs.first.id;
        setState(() {
          _coHosts.add({'uid': uid, 'email': email});
          _coHostEmailController.clear();
          _coHostError = null;
        });
        _scheduleDraftSave();
      }
    } catch (_) {
      setState(() => _coHostError = 'Error looking up user');
    } finally {
      if (mounted) setState(() => _lookingUpCoHost = false);
    }
  }

  void _addWishlistItem() {
    if (newItemNameController.text.isEmpty) return;
    if (listType == 'Wishlist' && newItemPriceController.text.isEmpty) return;
    if (listType == 'Checklist' && newItemQtyController.text.isEmpty) return;
    setState(() {
      if (listType == 'Checklist') {
        wishlistItems.add({'name': newItemNameController.text, 'quantity': newItemQtyController.text.trim(), 'claimed': 0});
      } else {
        wishlistItems.add({'name': newItemNameController.text, 'price': double.tryParse(newItemPriceController.text) ?? 0.0, 'contributed': 0.0, 'bought': false});
      }
      newItemNameController.clear();
      newItemPriceController.clear();
      newItemQtyController.clear();
    });
    _scheduleDraftSave();
  }

  Future<bool> _confirmExit() async {
    // Finalised events and brand-new unchanged screens exit freely.
    if (_eventFinalized) return true;
    if (_draftId == null || titleController.text.trim().isEmpty) return true;

    // Flush any pending debounced write so the dialog reflects the latest edits.
    _draftTimer?.cancel();
    await _saveDraftNow();
    if (!mounted) return false;

    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Save your progress?',
          style: TextStyle(color: _isDark ? Colors.white : AppColors.dark, fontWeight: FontWeight.w700),
        ),
        content: Text(
          "We've auto-saved your event as a draft. Come back to it anytime from your feed — or discard it now.",
          style: TextStyle(color: _muted, fontSize: 14, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: Text('Keep editing', style: TextStyle(color: _muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: const Text('Discard', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: Text('Save draft', style: TextStyle(color: _purple, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (choice == 'discard') {
      try {
        await FirebaseFirestore.instance.collection('events').doc(_draftId).delete();
      } catch (_) {}
      return true;
    }
    return choice == 'save';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final ok = await _confirmExit();
        if (ok && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Text(
          currentStep == 0 ? 'Choose Event Type' : currentStep == 1 ? 'Event Details' : 'Wishlist',
          style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
        ),
        leading: currentStep > 0
            ? IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => setState(() => currentStep--))
            : null,
      ),
      body: Column(
        children: [
          // Step indicator
          Container(
            color: _bg,
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Row(
              children: [
                _stepDot(0, 'Type'),
                Expanded(child: Divider(color: currentStep >= 1 ? _purple : _border, thickness: 2)),
                _stepDot(1, 'Details'),
                Expanded(child: Divider(color: currentStep >= 2 ? _purple : _border, thickness: 2)),
                _stepDot(2, 'Wishlist'),
              ],
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
              child: KeyedSubtree(
                key: ValueKey(currentStep),
                child: currentStep == 0
                    ? _buildStep0()
                    : currentStep == 1
                        ? _buildStep1()
                        : _buildStep2(),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: debugLabel('Screen 3 — Host View'),
      ),
    );
  }

  Widget _stepDot(int step, String label) => Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: currentStep >= step ? _purple : _border,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: currentStep > step
                  ? const Icon(Icons.check, color: Colors.white, size: 16)
                  : Text('${step + 1}', style: TextStyle(color: currentStep == step ? Colors.white : _muted, fontWeight: FontWeight.w700, fontSize: 14)),
            ),
          ),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(fontSize: 11, color: currentStep >= step ? _purple : _muted, fontWeight: FontWeight.w500)),
        ],
      );

  // ── STEP 0: Event Type Selector ──
  Widget _buildStep0() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: Text("What's the occasion?", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Text("Pick a type and we'll set the vibe", style: TextStyle(fontSize: 14, color: _muted)),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 0.95,
            ),
            itemCount: eventTypes.length,
            itemBuilder: (context, index) {
              final type = eventTypes[index];
              final isSelected = selectedEventType?.name == type.name;
              return GestureDetector(
                onTap: () => setState(() { selectedEventType = type; }),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  decoration: BoxDecoration(
                    color: isSelected ? type.primary.withValues(alpha: 0.18) : _card,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: isSelected ? type.primary : _border,
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        height: 48,
                        decoration: BoxDecoration(
                          color: type.primary,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                        ),
                        child: Center(child: Text(type.emoji, style: const TextStyle(fontSize: 26))),
                      ),
                      const SizedBox(height: 8),
                      Text(type.name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: isSelected ? type.primary : Colors.white)),
                      if (isSelected)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Icon(Icons.check_circle, color: type.primary, size: 16),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        if (_isBusiness && _templates.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: OutlinedButton.icon(
              onPressed: _showTemplatePicker,
              icon: const Icon(Icons.bookmark_outlined, size: 16),
              label: const Text('Use a Template'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _gold,
                side: const BorderSide(color: _gold),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                minimumSize: const Size(double.infinity, 44),
              ),
            ),
          ),
        if (selectedEventType == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text('Select an event type to continue', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: _muted)),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: selectedEventType == null
                  ? null
                  : () { setState(() => currentStep = 1); _scheduleDraftSave(); },
              style: ElevatedButton.styleFrom(
                backgroundColor: selectedEventType?.primary ?? _purple,
                foregroundColor: Colors.white,
                disabledBackgroundColor: _border,
                disabledForegroundColor: _muted,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(selectedEventType == null ? 'Select an event type' : 'Next: Event Details', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                  if (selectedEventType != null) ...[const SizedBox(width: 8), const Icon(Icons.arrow_forward)],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── STEP 1: Event Details ──
  Widget _buildStep1() {
    final type = selectedEventType!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _fieldLabel('Event Title'),
            _glowWrap(Row(
              children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: type.primary.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(child: Text(type.emoji, style: const TextStyle(fontSize: 20))),
                ),
                const SizedBox(width: 8),
                Expanded(child: TextField(
                  controller: titleController,
                  style: const TextStyle(color: Colors.white),
                  decoration: _inputDecoration('e.g. ${type.suggestion}'),
                )),
              ],
            )),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _fieldLabel('Date'),
                    _glowWrap(GestureDetector(
                      onTap: _pickDate,
                      child: _dateTimeBox(selectedDate != null ? '${selectedDate!.month}/${selectedDate!.day}/${selectedDate!.year}' : 'Pick Date', Icons.calendar_today_outlined),
                    )),
                  ]),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _fieldLabel('Time'),
                    _glowWrap(GestureDetector(
                      onTap: _pickTime,
                      child: _dateTimeBox(selectedTime != null ? selectedTime!.format(context) : 'Pick Time', Icons.access_time_outlined),
                    )),
                  ]),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _fieldLabel('Location'),
            _buildLocationField(),
            const SizedBox(height: 16),
            _fieldLabel('Description'),
            _glowWrap(TextField(
              controller: descController,
              maxLines: 2,
              style: const TextStyle(color: Colors.white),
              decoration: _inputDecoration('Tell your guests what to expect...'),
              onChanged: (_) => _scheduleDraftSave(),
            )),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: _card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _isPublic ? _purple : _border, width: _isPublic ? 1.5 : 1),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.public, size: 16, color: _isPublic ? _purple : _muted),
                          const SizedBox(width: 6),
                          Text('Make this event public', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _isPublic ? _purple : Colors.white)),
                        ]),
                        const SizedBox(height: 2),
                        Text('Appears in Explore tab for nearby guests', style: TextStyle(fontSize: 11, color: _muted)),
                      ],
                    ),
                  ),
                  Switch(
                    value: _isPublic,
                    onChanged: (v) { setState(() => _isPublic = v); _scheduleDraftSave(); },
                    activeTrackColor: _purple,
                    activeThumbColor: Colors.white,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: _pickRsvpDeadline,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _rsvpDeadline != null ? _purple : _border, width: _rsvpDeadline != null ? 1.5 : 1),
                ),
                child: Row(children: [
                  Icon(Icons.event_busy_outlined, size: 18, color: _rsvpDeadline != null ? _purple : _muted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _rsvpDeadline != null
                        ? Text(
                            '${const ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'][_rsvpDeadline!.month - 1]} ${_rsvpDeadline!.day}, ${_rsvpDeadline!.year}',
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
                          )
                        : Text('RSVP Deadline (optional)', style: TextStyle(fontSize: 14, color: _muted)),
                  ),
                  if (_rsvpDeadline != null)
                    GestureDetector(
                      onTap: () { setState(() => _rsvpDeadline = null); _scheduleDraftSave(); },
                      child: Icon(Icons.close, size: 18, color: _muted),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: 10),
            _buildCapacitySection(),
            if (_isBusiness) ...[
              const SizedBox(height: 10),
              _buildRecurringSection(),
              if (_isRecurring) ...[
                const SizedBox(height: 10),
                _buildFrequencyPicker(),
                const SizedBox(height: 10),
                _buildRecurrenceEndDate(),
              ],
              const SizedBox(height: 10),
              _buildCoHostSection(),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: titleController.text.isEmpty
                    ? null
                    : () => setState(() => currentStep = 2),
                style: ElevatedButton.styleFrom(
                  backgroundColor: type.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: _border,
                  disabledForegroundColor: _muted,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(
                    titleController.text.isEmpty ? 'Enter a title to continue' : 'Next: Wishlist',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  if (titleController.text.isNotEmpty) ...[const SizedBox(width: 8), const Icon(Icons.arrow_forward)],
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep2() {
    final type = selectedEventType!;
    final isNoList = listType == 'No List';
    final isChecklist = listType == 'Checklist';

    return Column(
      children: [
        // Mini themed banner
        Container(
          height: 60,
          color: type.primary,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(type.emoji, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
              Text(titleController.text.isEmpty ? type.name : titleController.text,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
            ],
          ),
        ),
        // List type toggle
        _glowWrap(Container(
          color: _card,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('List Type', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
              const SizedBox(height: 10),
              Row(
                children: [
                  _listTypeChip('Wishlist', Icons.card_giftcard_outlined, type),
                  const SizedBox(width: 8),
                  _listTypeChip('Checklist', Icons.checklist_outlined, type),
                  const SizedBox(width: 8),
                  _listTypeChip('No List', Icons.block_outlined, type),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                isNoList
                    ? 'No list will be shown to guests'
                    : isChecklist
                        ? 'Guests sign up to bring items — great for potlucks'
                        : 'Guests can contribute money or buy items',
                style: TextStyle(fontSize: 12, color: _muted),
              ),
              const SizedBox(height: 14),
            ],
          ),
        )),
        // Item input row (hidden for No List)
        if (!isNoList)
          Container(
            color: _card,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: newItemNameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration(isChecklist ? 'Item to bring' : 'Item name'),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 90,
                  child: isChecklist
                      ? TextField(
                          controller: newItemQtyController,
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration('e.g. 2 bags'),
                        )
                      : TextField(
                          controller: newItemPriceController,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration('\$ Price'),
                        ),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: _addWishlistItem,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: type.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                  child: const Icon(Icons.add),
                ),
              ],
            ),
          ),
        Expanded(
          child: isNoList
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('🚫', style: TextStyle(fontSize: 48)),
                      const SizedBox(height: 12),
                      Text('No list for this event', style: TextStyle(fontSize: 16, color: _muted)),
                      const SizedBox(height: 4),
                      Text('The Wishlist tab will be hidden from guests', style: TextStyle(fontSize: 13, color: _muted)),
                    ],
                  ),
                )
              : wishlistItems.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(isChecklist ? '📋' : '🎁', style: const TextStyle(fontSize: 48)),
                          const SizedBox(height: 12),
                          Text('No ${isChecklist ? 'checklist' : 'wishlist'} items yet', style: TextStyle(fontSize: 16, color: _muted)),
                          const SizedBox(height: 4),
                          Text(isChecklist ? 'Add items for guests to claim' : 'Add items above for guests to gift', style: TextStyle(fontSize: 13, color: _muted)),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: wishlistItems.length,
                      itemBuilder: (context, index) => _buildWishlistItem(index),
                    ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: () async {
                final user = FirebaseAuth.instance.currentUser;
                if (user == null) return;
                _draftTimer?.cancel();
                try {
                  final isRecurring = _isRecurring && _isBusiness;
                  final recurrenceRule = isRecurring ? _buildRecurrenceRule() : null;
                  final seriesId = isRecurring
                      ? FirebaseFirestore.instance.collection('recurringEvents').doc().id
                      : null;
                  final wishlistData = wishlistItems.map((item) => listType == 'Checklist'
                      ? {'name': item['name'], 'quantity': item['quantity'], 'claimed': 0}
                      : {'name': item['name'], 'price': item['price'], 'contributed': 0.0, 'bought': false}).toList();
                  final finalData = {
                    'accountType': _accountType ?? 'personal',
                    'title': titleController.text,
                    'description': descController.text,
                    'location': locationController.text,
                    'date': selectedDate != null ? Timestamp.fromDate(selectedDate!) : null,
                    'time': selectedTime != null ? '${selectedTime!.hour}:${selectedTime!.minute}' : null,
                    'eventType': selectedEventType?.name,
                    'eventEmoji': selectedEventType?.emoji,
                    'hostId': user.uid,
                    'hostName': user.displayName ?? 'Host',
                    'listType': listType,
                    'wishlist': wishlistData,
                    'yes': 0,
                    'maybe': 0,
                    'no': 0,
                    'isPublic': _isPublic,
                    'rsvpDeadline': _rsvpDeadline != null ? Timestamp.fromDate(_rsvpDeadline!) : null,
                    'coHosts': _coHosts.map((c) => c['uid'] as String).toList(),
                    'zipCode': _zipCode,
                    'isRecurring': isRecurring,
                    if (seriesId != null) 'recurringSeriesId': seriesId,
                    if (recurrenceRule != null) 'recurrenceRule': recurrenceRule,
                    'capacity': _capacityEnabled ? int.tryParse(_capacityController.text.trim()) : null,
                    'allowPlusOnes': _allowPlusOnes,
                    'maxPlusOnes': _allowPlusOnes ? _maxPlusOnes : null,
                    'allowWaitlist': _capacityEnabled ? _allowWaitlist : false,
                    'isDraft': false,
                    'createdAt': FieldValue.serverTimestamp(),
                  };
                  debugPrint('[CreateEvent] saving event — authUid=${user.uid} hostId=${user.uid} draftId=$_draftId recurring=$isRecurring');
                  String eventId;
                  if (_draftId != null) {
                    await FirebaseFirestore.instance.collection('events').doc(_draftId).update(finalData);
                    eventId = _draftId!;
                    debugPrint('[CreateEvent] updated draft $eventId');
                  } else {
                    final docRef = await FirebaseFirestore.instance.collection('events').add(finalData);
                    eventId = docRef.id;
                    debugPrint('[CreateEvent] created new event $eventId');
                  }
                  // Create series tracking doc for recurring events
                  if (isRecurring && seriesId != null && recurrenceRule != null) {
                    await FirebaseFirestore.instance.collection('recurringEvents').doc(seriesId).set({
                      'hostId': user.uid,
                      'hostName': user.displayName ?? 'Host',
                      'rule': recurrenceRule,
                      'eventTemplate': {
                        'title': titleController.text,
                        'description': descController.text,
                        'location': locationController.text,
                        'time': selectedTime != null ? '${selectedTime!.hour}:${selectedTime!.minute}' : null,
                        'eventType': selectedEventType?.name,
                        'eventEmoji': selectedEventType?.emoji,
                        'listType': listType,
                        'wishlist': wishlistData,
                        'isPublic': _isPublic,
                        'coHosts': _coHosts.map((c) => c['uid'] as String).toList(),
                        'zipCode': _zipCode,
                      },
                      'active': true,
                      'originalEventId': eventId,
                      'latestEventId': eventId,
                      'latestEventDate': selectedDate != null ? Timestamp.fromDate(selectedDate!) : null,
                      'createdAt': FieldValue.serverTimestamp(),
                    });
                    debugPrint('[CreateEvent] created series $seriesId with rule=$recurrenceRule');
                  }
                  // Schedule notification task if deadline is set
                  if (_rsvpDeadline != null) {
                    final notifyAt = _rsvpDeadline!.subtract(const Duration(days: 7));
                    final months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
                    final deadlineLabel = '${months[_rsvpDeadline!.month - 1]} ${_rsvpDeadline!.day}';
                    await FirebaseFirestore.instance
                        .collection('notificationTasks')
                        .doc(eventId)
                        .set({
                      'eventId':      eventId,
                      'eventTitle':   titleController.text,
                      'type':         'rsvp_reminder',
                      'message':      'Last chance! RSVP to ${titleController.text} by $deadlineLabel',
                      'scheduledFor': Timestamp.fromDate(notifyAt),
                      'deadline':     Timestamp.fromDate(_rsvpDeadline!),
                      'status':       'pending',
                      'createdAt':    FieldValue.serverTimestamp(),
                    });
                  }
                  _eventFinalized = true;
                  if (mounted) {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => GenerateQRCodeScreen(eventId: eventId, eventTitle: titleController.text)));
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error saving event: $e'), backgroundColor: Colors.redAccent));
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: type.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.qr_code_2),
                SizedBox(width: 10),
                Text('Generate Event QR Code', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _listTypeChip(String label, IconData icon, EventType type) {
    final isSelected = listType == label;
    return Expanded(
      child: GestureDetector(
        onTap: () { setState(() { listType = label; wishlistItems.clear(); }); _scheduleDraftSave(); },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? type.primary : _border,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: isSelected ? Colors.white : _muted),
              const SizedBox(height: 4),
              Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: isSelected ? Colors.white : _muted)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWishlistItem(int index) {
    final item = wishlistItems[index];
    final isChecklist = listType == 'Checklist';
    final subtitle = isChecklist
        ? 'Qty needed: ${item['quantity']}'
        : '\$${(item['price'] as double).toStringAsFixed(2)}';
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item['name'] as String, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
                const SizedBox(height: 4),
                Text(subtitle, style: TextStyle(fontSize: 14, color: _muted)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            onPressed: () => setState(() => wishlistItems.removeAt(index)),
          ),
        ],
      ),
    );
  }

  Widget _buildLocationField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _glowWrap(TextField(
          controller: locationController,
          focusNode: _locationFocusNode,
          style: const TextStyle(color: Colors.white),
          decoration: _inputDecoration('e.g. 123 Celebration Lane, Seaside CA').copyWith(
            prefixIcon: Icon(Icons.location_on_outlined, size: 18, color: _muted),
            suffixIcon: _fetchingSuggestions
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(color: _purple, strokeWidth: 2),
                    ),
                  )
                : locationController.text.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.close, size: 16, color: _muted),
                        onPressed: () {
                          locationController.clear();
                          setState(() { _suggestions = []; _zipCode = ''; });
                          _scheduleDraftSave();
                        },
                      )
                    : null,
          ),
          onChanged: (v) {
            setState(() {});
            _scheduleDraftSave();
            _suggestionsDebounce?.cancel();
            if (v.length >= 3) {
              _suggestionsDebounce = Timer(
                const Duration(milliseconds: 400),
                () => _fetchSuggestions(v),
              );
            } else {
              setState(() { _suggestions = []; _fetchingSuggestions = false; });
            }
          },
        )),
        if (_suggestions.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _border),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _suggestions.length,
              separatorBuilder: (_, _) => Divider(height: 1, color: _border, indent: 40),
              itemBuilder: (_, i) {
                final s = _suggestions[i];
                final fmt = s['structured_formatting'] as Map<String, dynamic>?;
                final main = fmt?['main_text'] as String? ?? (s['description'] as String? ?? '');
                final secondary = fmt?['secondary_text'] as String? ?? '';
                return InkWell(
                  onTap: () => _selectSuggestion(s),
                  borderRadius: BorderRadius.vertical(
                    top: i == 0 ? const Radius.circular(12) : Radius.zero,
                    bottom: i == _suggestions.length - 1 ? const Radius.circular(12) : Radius.zero,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.location_on_outlined, size: 16, color: _purple),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(main, style: const TextStyle(fontSize: 14, color: Colors.white, fontWeight: FontWeight.w500)),
                              if (secondary.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(secondary, style: TextStyle(fontSize: 11, color: _muted)),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        if (_zipCode.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Icon(Icons.pin_drop_outlined, size: 13, color: _muted),
                const SizedBox(width: 4),
                Text('ZIP: $_zipCode', style: TextStyle(fontSize: 12, color: _muted)),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _pickRecurrenceEndDate() async {
    final now = DateTime.now();
    final start = selectedDate ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: _recurrenceEndDate ?? start.add(const Duration(days: 90)),
      firstDate: start,
      lastDate: DateTime(start.year + 5),
      helpText: 'Stop repeating on',
    );
    if (picked != null) {
      setState(() => _recurrenceEndDate = picked);
      _scheduleDraftSave();
    }
  }

  Widget _buildCapacitySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _capacityEnabled ? _purple : _border, width: _capacityEnabled ? 1.5 : 1),
          ),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.groups_outlined, size: 16, color: _capacityEnabled ? _purple : _muted),
                    const SizedBox(width: 6),
                    Text('Set capacity limit', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _capacityEnabled ? _purple : Colors.white)),
                  ]),
                  const SizedBox(height: 2),
                  Text('Cap how many guests can RSVP Yes', style: TextStyle(fontSize: 11, color: _muted)),
                ],
              ),
            ),
            Switch(
              value: _capacityEnabled,
              onChanged: (v) {
                setState(() {
                  _capacityEnabled = v;
                  if (!v) _capacityController.clear();
                });
                _scheduleDraftSave();
              },
              activeTrackColor: _purple,
              activeThumbColor: Colors.white,
            ),
          ]),
        ),
        if (_capacityEnabled) ...[
          const SizedBox(height: 10),
          _glowWrap(TextField(
            controller: _capacityController,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.white),
            decoration: _inputDecoration('Max guests (e.g. 50)'),
            onChanged: (_) => _scheduleDraftSave(),
          )),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _allowWaitlist ? _purple : _border, width: _allowWaitlist ? 1.5 : 1),
            ),
            child: Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.hourglass_bottom, size: 16, color: _allowWaitlist ? _purple : _muted),
                      const SizedBox(width: 6),
                      Text('Allow waitlist', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _allowWaitlist ? _purple : Colors.white)),
                    ]),
                    const SizedBox(height: 2),
                    Text('Notify the next person when a spot opens', style: TextStyle(fontSize: 11, color: _muted)),
                  ],
                ),
              ),
              Switch(
                value: _allowWaitlist,
                onChanged: (v) { setState(() => _allowWaitlist = v); _scheduleDraftSave(); },
                activeTrackColor: _purple,
                activeThumbColor: Colors.white,
              ),
            ]),
          ),
        ],
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _allowPlusOnes ? _purple : _border, width: _allowPlusOnes ? 1.5 : 1),
          ),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.person_add_alt, size: 16, color: _allowPlusOnes ? _purple : _muted),
                    const SizedBox(width: 6),
                    Text('Allow plus ones', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _allowPlusOnes ? _purple : Colors.white)),
                  ]),
                  const SizedBox(height: 2),
                  Text('Let guests bring extra people', style: TextStyle(fontSize: 11, color: _muted)),
                ],
              ),
            ),
            Switch(
              value: _allowPlusOnes,
              onChanged: (v) { setState(() => _allowPlusOnes = v); _scheduleDraftSave(); },
              activeTrackColor: _purple,
              activeThumbColor: Colors.white,
            ),
          ]),
        ),
        if (_allowPlusOnes) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              for (final opt in const [(1, '1'), (2, '2'), (null, 'Unlimited')]) ...[
                Expanded(
                  child: GestureDetector(
                    onTap: () { setState(() => _maxPlusOnes = opt.$1); _scheduleDraftSave(); },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: _maxPlusOnes == opt.$1 ? _purple.withValues(alpha: 0.18) : _card,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _maxPlusOnes == opt.$1 ? _purple : _border, width: _maxPlusOnes == opt.$1 ? 1.5 : 1),
                      ),
                      child: Center(
                        child: Text(
                          opt.$2,
                          style: TextStyle(
                            color: _maxPlusOnes == opt.$1 ? _purple : Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (opt.$2 != 'Unlimited') const SizedBox(width: 8),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildRecurringSection() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _isRecurring ? _purple : _border, width: _isRecurring ? 1.5 : 1),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.repeat, size: 16, color: _isRecurring ? _purple : _muted),
                  const SizedBox(width: 6),
                  Text('Make this recurring', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _isRecurring ? _purple : Colors.white)),
                ]),
                const SizedBox(height: 2),
                Text('Automatically create the next event in the series', style: TextStyle(fontSize: 11, color: _muted)),
              ],
            ),
          ),
          Switch(
            value: _isRecurring,
            onChanged: (v) {
              setState(() {
                _isRecurring = v;
                if (!v) _recurrenceEndDate = null;
              });
              _scheduleDraftSave();
            },
            activeTrackColor: _purple,
            activeThumbColor: Colors.white,
          ),
        ],
      ),
    );
  }

  Widget _buildFrequencyPicker() {
    final options = const [
      ('daily',    'Daily',    Icons.today_outlined),
      ('weekly',   'Weekly',   Icons.view_week_outlined),
      ('biweekly', 'Biweekly', Icons.date_range_outlined),
      ('monthly',  'Monthly',  Icons.calendar_month_outlined),
    ];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text('Frequency', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _muted, letterSpacing: 0.5)),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: options.map((o) {
              final (value, label, icon) = o;
              final selected = _recurrenceFrequency == value;
              return GestureDetector(
                onTap: () {
                  setState(() => _recurrenceFrequency = value);
                  _scheduleDraftSave();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: selected ? _purple.withValues(alpha: 0.18) : _bg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: selected ? _purple : _border, width: selected ? 1.5 : 1),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon, size: 14, color: selected ? _purple : _muted),
                    const SizedBox(width: 6),
                    Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: selected ? _purple : Colors.white)),
                  ]),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildRecurrenceEndDate() {
    final months = const ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return GestureDetector(
      onTap: _pickRecurrenceEndDate,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _recurrenceEndDate != null ? _gold : _border, width: _recurrenceEndDate != null ? 1.5 : 1),
        ),
        child: Row(children: [
          Icon(Icons.event_busy_outlined, size: 18, color: _recurrenceEndDate != null ? _gold : _muted),
          const SizedBox(width: 10),
          Expanded(
            child: _recurrenceEndDate != null
                ? Text(
                    'Stop on ${months[_recurrenceEndDate!.month - 1]} ${_recurrenceEndDate!.day}, ${_recurrenceEndDate!.year}',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
                  )
                : Text('End date (optional — repeats forever if empty)', style: TextStyle(fontSize: 14, color: _muted)),
          ),
          if (_recurrenceEndDate != null)
            GestureDetector(
              onTap: () { setState(() => _recurrenceEndDate = null); _scheduleDraftSave(); },
              child: Icon(Icons.close, size: 18, color: _muted),
            ),
        ]),
      ),
    );
  }

  Widget _buildCoHostSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel('Co-Hosts'),
        Row(children: [
          Expanded(child: TextField(
            controller: _coHostEmailController,
            style: const TextStyle(color: Colors.white),
            keyboardType: TextInputType.emailAddress,
            decoration: _inputDecoration('Email address').copyWith(
              errorText: _coHostError,
              errorStyle: const TextStyle(color: Colors.redAccent, fontSize: 11),
            ),
            onSubmitted: (_) => _addCoHost(),
          )),
          const SizedBox(width: 8),
          SizedBox(
            height: 50,
            child: ElevatedButton(
              onPressed: _lookingUpCoHost ? null : _addCoHost,
              style: ElevatedButton.styleFrom(
                backgroundColor: _purple,
                foregroundColor: Colors.white,
                disabledBackgroundColor: _border,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              child: _lookingUpCoHost
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Text('Add', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
        if (_coHosts.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _coHosts.map((coHost) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _purple.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _purple.withValues(alpha: 0.40)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.person_outline, size: 14, color: _purple),
                const SizedBox(width: 6),
                Text(coHost['email'] as String, style: const TextStyle(fontSize: 12, color: _purple, fontWeight: FontWeight.w500)),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () {
                    setState(() => _coHosts.removeWhere((c) => c['uid'] == coHost['uid']));
                    _scheduleDraftSave();
                  },
                  child: const Icon(Icons.close, size: 14, color: _purple),
                ),
              ]),
            )).toList(),
          ),
        ],
      ],
    );
  }

  Widget _glowWrap(Widget child) => child;

  Widget _fieldLabel(String label) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white)),
      );

  InputDecoration _inputDecoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: _muted),
        filled: true,
        fillColor: _card,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _purple, width: 1.5)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      );

  Widget _dateTimeBox(String text, IconData icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(12), border: Border.all(color: _border)),
        child: Row(children: [
          Icon(icon, size: 18, color: _muted),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontSize: 14, color: Colors.white)),
        ]),
      );
}

// ── Template Picker Bottom Sheet ──────────────────────────────
class _TemplatePickerSheet extends StatefulWidget {
  final List<Map<String, dynamic>> templates;
  final void Function(Map<String, dynamic>) onPicked;
  final Future<void> Function(String templateId) onDeleted;

  const _TemplatePickerSheet({
    required this.templates,
    required this.onPicked,
    required this.onDeleted,
  });

  @override
  State<_TemplatePickerSheet> createState() => _TemplatePickerSheetState();
}

class _TemplatePickerSheetState extends State<_TemplatePickerSheet> {
  late List<Map<String, dynamic>> _local;

  // Theme-aware color getters — same light/dark swap as the parent screen.
  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;

  @override
  void initState() {
    super.initState();
    _local = List.from(widget.templates);
  }

  Future<void> _delete(String templateId) async {
    await widget.onDeleted(templateId);
    if (mounted) setState(() => _local.removeWhere((t) => t['id'] == templateId));
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (_, controller) => Container(
        decoration: BoxDecoration(
          color: _card,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: _border, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Icon(Icons.bookmark_outlined, color: _gold, size: 20),
                  SizedBox(width: 8),
                  Text('Your Templates', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (_local.isEmpty)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('📄', style: TextStyle(fontSize: 40)),
                      const SizedBox(height: 12),
                      Text('No templates yet', style: TextStyle(color: _muted, fontSize: 15)),
                      const SizedBox(height: 4),
                      Text('Save an event as a template from your feed', style: TextStyle(color: _muted, fontSize: 12)),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: _local.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final t = _local[i];
                    final emoji = t['eventEmoji'] as String? ?? '✨';
                    final title = t['title'] as String? ?? 'Untitled';
                    final typeName = t['eventType'] as String? ?? '';
                    final offsetDays = t['rsvpDeadlineOffsetDays'] as int? ?? 0;
                    return Container(
                      decoration: BoxDecoration(
                        color: _bg,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: _border),
                      ),
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          Container(
                            width: 44, height: 44,
                            decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(12)),
                            child: Center(child: Text(emoji, style: const TextStyle(fontSize: 22))),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                                const SizedBox(height: 2),
                                Text(
                                  offsetDays > 0 ? '$typeName · RSVP $offsetDays days before' : typeName,
                                  style: TextStyle(fontSize: 12, color: _muted),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                            onPressed: () => _delete(t['id'] as String),
                            tooltip: 'Delete template',
                          ),
                          ElevatedButton(
                            onPressed: () {
                              Navigator.pop(context);
                              widget.onPicked(t);
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _gold,
                              foregroundColor: _bg,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            ),
                            child: const Text('Use', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
