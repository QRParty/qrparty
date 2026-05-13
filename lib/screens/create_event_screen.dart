import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_places_flutter/google_places_flutter.dart';
import 'package:google_places_flutter/model/prediction.dart';
import 'package:http/http.dart' as http;
import '../utils.dart';
import '../models/merch_order.dart';
import 'generate_qr_screen.dart';
import 'order_merch_screen.dart';
import 'wishlist_browser_screen.dart';

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

// Google Places API key. Used by the GooglePlaceAutoCompleteTextField
// widget for address autocomplete and by [_fetchZipFromPlaceId] for the
// follow-up Place Details request that pulls `postal_code` out of the
// address components.
//
// IMPORTANT — common failure modes when autocomplete returns nothing:
//
//   1. Places API not enabled on the GCP project. Console →
//      "APIs & Services" → "Library" → enable both:
//        • Places API (legacy)  — required by the maps.googleapis.com/
//          maps/api/place/autocomplete + place/details endpoints used
//          by `google_places_flutter`.
//        • Maps SDK for Android — required by the Maps view used in
//          create_event_screen's location picker.
//
//   2. Application restrictions limit the key to "Android apps" with
//      a SHA-1 + package allow-list. THAT BLOCKS this code path
//      because google_places_flutter calls the Places HTTP API
//      directly (not via the Android SDK), so requests don't carry
//      the Android signing certificate. Fix: switch the key to "None"
//      restriction OR create a separate "HTTP referrers" key with
//      `*.googleapis.com` and use that here.
//
//   3. Billing not enabled on the GCP project. Places API requires
//      billing even for the free tier ($200/mo credit). Enable it
//      under Billing → Link a billing account.
//
// Authorized Android signing SHA-256 fingerprints (mirror these in
// the GCP key restriction if you opt for Android-restricted access
// — only works for the SDK call paths, not the HTTP path above):
//   25:74:13:2F:C9:02:D8:E1:4B:1A:69:12:62:F3:56:2C:3B:44:07:B0:AD:2E:05:F4:DE:34:02:33:84:1B:D8:14
//   90:B0:43:AD:12:E8:82:F0:13:B7:02:40:54:D6:0E:D6:EA:AF:30:F7:5E:14:E1:DC:8B:93:8E:0D:AB:46:E1:A6
// (Source: public/.well-known/assetlinks.json — second fingerprint is
// the Play App Signing key Google re-signs the prod release with.)
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
  // Optional secondary location detail — room number, suite, area
  // within the venue. Stored separately from `location` so the Places
  // autocomplete on the main field can keep returning a clean address
  // string, with the freeform "Library / Room 204 / Main Stage"
  // detail layered on top.
  final locationDetailController = TextEditingController();
  final newItemNameController = TextEditingController();
  final newItemPriceController = TextEditingController();
  final newItemQtyController = TextEditingController();
  // Custom event-type name. Visible only when [selectedEventType?.name]
  // is 'Custom'. Saved as the literal `eventType` string on the event
  // doc when non-empty so the host's choice survives reload + render.
  final _customTypeCtrl = TextEditingController();
  // Unlimited-quantity mode for the next checklist item the host adds.
  // When true, the qty TextField is replaced with an ∞ pill and the
  // saved item carries `unlimited: true` (no `quantityNeeded`).
  bool _newItemUnlimited = false;
  // Default list type for a brand-new event. Falls through to Checklist
  // when Wishlist is disabled so the form doesn't start in a state whose
  // chip isn't even rendered. Existing drafts/templates hydrate their
  // own listType from Firestore below — this default only applies when
  // there's nothing to hydrate from.
  // listType holds one of: 'No List', 'Wishlist', 'Checklist', 'Both'.
  // 'Both' was added when hosts asked to run a potluck (checklist) and a
  // gift list (wishlist) on the same event. The two booleans below are
  // the user-facing source of truth in the editor; listType is derived
  // from them on save (and when reading a draft/template back, the
  // booleans are derived in reverse).
  String listType = kWishlistEnabled ? 'Wishlist' : 'Checklist';
  bool get _hasWishlist => listType == 'Wishlist' || listType == 'Both';
  bool get _hasChecklist => listType == 'Checklist' || listType == 'Both';
  /// Recompute listType from the two booleans. Called by the editor
  /// toggles. Keeps the single string field that the rest of the app
  /// (templates, analytics, business feed) still reads.
  /// Tier-filtered picker list. Driven by `_accountType` — Business
  /// and BusinessPlus owners pick from [businessEventTypes]; everyone
  /// else (including unset/null) gets [personalEventTypes]. Restoration
  /// still uses the union [eventTypes] so legacy saves resolve.
  List<EventType> get _tierEventTypes =>
      (_accountType == 'business' || _accountType == 'businessPlus')
          ? businessEventTypes
          : personalEventTypes;

  /// Saved-doc value for the `eventType` field. When the host picked
  /// "Custom" and typed a label, return the typed label so the saved
  /// doc carries their wording. Empty input falls back to literal
  /// "Custom" so the saved doc still has SOME identifier.
  String? get _resolvedEventTypeName {
    final type = selectedEventType;
    if (type == null) return null;
    if (type.name == 'Custom') {
      final custom = _customTypeCtrl.text.trim();
      return custom.isNotEmpty ? custom : 'Custom';
    }
    return type.name;
  }

  void _setHasWishlist(bool v) {
    setState(() {
      final c = _hasChecklist;
      listType = v
          ? (c ? 'Both' : 'Wishlist')
          : (c ? 'Checklist' : 'No List');
      // Drop wishlist-kind items when wishlist is turned off.
      if (!v) wishlistItems.removeWhere((i) => _itemKind(i) == 'wishlist');
    });
    _scheduleDraftSave();
  }
  void _setHasChecklist(bool v) {
    setState(() {
      final w = _hasWishlist;
      listType = v
          ? (w ? 'Both' : 'Checklist')
          : (w ? 'Wishlist' : 'No List');
      if (!v) wishlistItems.removeWhere((i) => _itemKind(i) == 'checklist');
    });
    _scheduleDraftSave();
  }
  /// Returns the per-item kind. Items written under the new model have
  /// a `kind` field. Legacy items (no `kind`) infer from listType: a
  /// 'Wishlist' event's items are wishlist; a 'Checklist' event's items
  /// are checklist; a 'Both' event REQUIRES kind, defaulting to
  /// 'wishlist' for malformed items so they're at least visible.
  String _itemKind(Map<String, dynamic> item) {
    final stored = item['kind'] as String?;
    if (stored == 'wishlist' || stored == 'checklist') return stored!;
    if (listType == 'Checklist') return 'checklist';
    return 'wishlist';
  }
  bool _isPublic = false;
  // Outdoor flag — when true, the guest screen renders the weather
  // widget. Defaults to false so indoor events (most parties) don't
  // surface a weather pill that's irrelevant to them.
  bool _isOutdoor = false;
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
  // Flips true for the duration of the Firestore write that finalises
  // the event. Drives the Generate-QR button's spinner + disabled
  // state so a slow write (offline, cold App Check) doesn't look
  // like the button is broken — previously it stayed "Generate Event
  // QR Code" with no indicator, and missing-required-field rejections
  // surfaced as a transient SnackBar that was easy to miss.
  bool _saving = false;

  List<Map<String, dynamic>> wishlistItems = [];

  // ── Registry Links state ────────────────────────────────────
  // External gift-registry URLs (Zola / Amazon / Target / Babylist /
  // etc.). Lives on a dedicated `registryLinks` field on the event
  // doc so a host can attach registries even on `No List` events.
  // Hydrated from draft / template in initState; flushed back on every
  // draft save and on the final create write.
  final List<String> _registryLinks = [];
  final TextEditingController _registryLinkController = TextEditingController();

  String? _draftId;
  Timer? _draftTimer;

  int _templateRsvpOffsetDays = 0;
  List<Map<String, dynamic>> _templates = [];

  String _zipCode = '';
  final _locationFocusNode = FocusNode();
  // Focus targets for the wishlist + checklist item-name fields.
  // Two separate nodes are required because in 'Both' mode both
  // sections render simultaneously — a single FocusNode can only
  // attach to one TextField at a time. The right node is refocused
  // after each manual `+ Add` press in [_addItemOfKind] so the host
  // can keep typing the next item's name without re-tapping the
  // field, AND after the WebView returns from [_openShop].
  final _itemNameFocusNode = FocusNode();         // wishlist section
  final _checklistNameFocusNode = FocusNode();    // checklist section
  // Focus targets for the secondary fields on the inline add row.
  // The name field's textInputAction is .next, which routes the
  // keyboard's Next button to whichever of these is relevant for
  // the current section (qty for checklist, price for wishlist) so
  // the host can rip through a long list without re-tapping each
  // field manually.
  final _checklistQtyFocusNode = FocusNode();
  final _wishlistPriceFocusNode = FocusNode();

  bool _isRecurring = false;
  String _recurrenceFrequency = 'weekly';
  DateTime? _recurrenceEndDate;

  /// Plus-ones is only relevant for Corporate and Wedding events. For
  /// every other type the toggle is hidden entirely and `_allowPlusOnes`
  /// stays false on the saved doc.
  bool get _supportsPlusOnes =>
      selectedEventType?.name == 'Corporate' || selectedEventType?.name == 'Wedding';

  // Capacity + waitlist state. _maxPlusOnes: 1, 2, or null = unlimited.
  bool _capacityEnabled = false;

  /// Single source of truth for the capacity field that lands on
  /// Firestore. Returns null whenever the toggle is off OR the parsed
  /// value isn't a positive integer — which closes the
  /// `capacity: 0 → "Event is full" forever` bug at the point where
  /// it would otherwise enter the data layer. Empty fields, "0",
  /// negatives, and anything int.tryParse can't read all collapse
  /// to null instead of being persisted.
  int? get _persistedCapacity {
    if (!_capacityEnabled) return null;
    final n = int.tryParse(_capacityController.text.trim());
    return (n != null && n > 0) ? n : null;
  }
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
  // Foreground for body text on _bg or _card surfaces. Without this getter,
  // earlier code hardcoded Colors.white, which became invisible in light
  // mode where _card resolves to Colors.white. Use this anywhere the text
  // sits on a theme-switching background; keep Colors.white only on
  // brand-colored surfaces (event type primary, green/purple buttons, etc.).
  Color get _fg     => _isDark ? Colors.white : AppColors.dark;

  @override
  void initState() {
    super.initState();
    _draftId = widget.draftId;
    final d = widget.draftData;
    titleController = TextEditingController(text: d != null ? (d['title'] as String? ?? '') : '');
    if (d != null) {
      descController.text = (d['description'] as String?) ?? descController.text;
      locationController.text = (d['location'] as String?) ?? '';
      locationDetailController.text = (d['locationDetail'] as String?) ?? '';
      listType = (d['listType'] as String?) ?? 'Wishlist';
      final ts = d['date'] as Timestamp?;
      if (ts != null) selectedDate = ts.toDate();
      final timeStr = d['time'] as String?;
      if (timeStr != null) {
        final parts = timeStr.split(':');
        if (parts.length == 2) selectedTime = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
      }
      final typeName = d['eventType'] as String?;
      if (typeName != null) {
        final migrated = migrateEventTypeName(typeName);
        selectedEventType = eventTypes.firstWhere((t) => t.name == migrated, orElse: () => eventTypes.last);
        // Preserve the original saved label when it falls through to
        // Custom (e.g. user previously typed "Yard Sale") so editing
        // doesn't wipe their typed name back to the literal "Custom".
        if (selectedEventType?.name == 'Custom' && migrated.isNotEmpty && migrated != 'Custom') {
          _customTypeCtrl.text = migrated;
        }
      }
      final rawList = d['wishlist'] as List<dynamic>? ?? [];
      wishlistItems = rawList.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final rawRegistry = d['registryLinks'] as List<dynamic>? ?? [];
      _registryLinks
        ..clear()
        ..addAll(rawRegistry.whereType<String>());
      _isPublic = (d['isPublic'] as bool?) ?? false;
      _isOutdoor = (d['isOutdoor'] as bool?) ?? false;
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
        final migrated = migrateEventTypeName(typeName);
        selectedEventType = eventTypes.firstWhere((e) => e.name == migrated, orElse: () => eventTypes.last);
        if (selectedEventType?.name == 'Custom' && migrated.isNotEmpty && migrated != 'Custom') {
          _customTypeCtrl.text = migrated;
        }
      }
      final coHostEmails = List<String>.from(t['coHostEmails'] as List? ?? []);
      final coHostUids = List<String>.from(t['coHosts'] as List? ?? []);
      for (int i = 0; i < coHostUids.length && i < coHostEmails.length; i++) {
        _coHosts.add({'uid': coHostUids[i], 'email': coHostEmails[i]});
      }
      _templateRsvpOffsetDays = (t['rsvpDeadlineOffsetDays'] as int?) ?? 0;
      final rawTplRegistry = t['registryLinks'] as List<dynamic>? ?? [];
      _registryLinks
        ..clear()
        ..addAll(rawTplRegistry.whereType<String>());
      if (selectedEventType != null) currentStep = 1;
    }
    titleController.addListener(_onTitleChanged);
    // Keep the draft state in sync when the user types directly into the
    // location field without picking a suggestion. The
    // GooglePlaceAutoCompleteTextField widget owns the field's onChanged,
    // so a controller listener is the only hook left to us.
    locationController.addListener(_scheduleDraftSave);
    locationDetailController.addListener(_scheduleDraftSave);
    _checkBusinessAccount();
  }

  void _onTitleChanged() {
    setState(() {});
    // Route the first-character-typed case through the debounced
    // saver too, NOT a synchronous _createDraft() call. Earlier this
    // method did an immediate await firestore.add() on the first
    // keystroke; if the host popped the screen before the write
    // resolved, dispose() couldn't cancel the in-flight Future and
    // the draft landed in Firestore anyway as an orphan. The host
    // never saw the "Save your progress?" dialog (because _draftId
    // was still null at pop time) and the orphan kept showing up on
    // the home feed every time they came back. Routing through
    // _scheduleDraftSave fixes that — the 600ms Timer IS cancelable
    // in dispose(), so a typo+back-out leaves no doc behind.
    if (titleController.text.isNotEmpty || _draftId != null) {
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
        // Stamp date as null up front so the field is *present* on the
        // doc. Firestore's orderBy('date') excludes docs where the field
        // is missing entirely — without this, a fresh draft (created
        // before the host picks a date) wouldn't appear in the home feed
        // until the 600ms _saveDraftNow debounce fired.
        'date': null,
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
    // First-write path: no draft doc exists yet. Skip entirely if the
    // title is still empty — there's no point creating a Firestore
    // doc for a host who hasn't typed anything meaningful. When a
    // title IS present, allocate the doc via _createDraft, which
    // populates _draftId before falling through to the update path
    // below (so the very first save also lands the rest of the
    // form's state in one shot).
    if (_draftId == null) {
      if (titleController.text.trim().isEmpty) return;
      await _createDraft();
      if (_draftId == null) return; // create failed — bail.
    }
    try {
      await FirebaseFirestore.instance.collection('events').doc(_draftId).update({
        'accountType': _accountType ?? 'personal',
        'title': titleController.text,
        'description': descController.text,
        'location': locationController.text,
        'locationDetail': locationDetailController.text.trim(),
        'date': selectedDate != null ? Timestamp.fromDate(selectedDate!) : null,
        'time': selectedTime != null ? '${selectedTime!.hour}:${selectedTime!.minute}' : null,
        'eventType': _resolvedEventTypeName,
        'eventEmoji': selectedEventType?.emoji,
        'listType': listType,
        'isPublic': _isPublic,
        'isOutdoor': _isOutdoor,
        'rsvpDeadline': _rsvpDeadline != null ? Timestamp.fromDate(_rsvpDeadline!) : null,
        'zipCode': _zipCode,
        'coHosts': _coHosts.map((c) => c['uid'] as String).toList(),
        'isRecurring': _isRecurring && _isBusiness,
        'recurrenceRule': (_isRecurring && _isBusiness) ? _buildRecurrenceRule() : null,
        // Capacity + waitlist are gated by _persistedCapacity so a 0 /
        // empty / non-numeric field can't sneak into Firestore — and
        // waitlist stays off when there's no real cap (waitlist
        // without a cap has no trigger to fire on).
        'capacity': _persistedCapacity,
        'allowPlusOnes': _allowPlusOnes,
        'maxPlusOnes': _allowPlusOnes ? _maxPlusOnes : null,
        'allowWaitlist': _persistedCapacity != null && _allowWaitlist,
        // Persist the in-memory items wholesale so per-item discriminators
        // (`kind`, `quantityNeeded`, etc.) and progress fields (`claims`,
        // `claimed`, `contributed`, `bought`) land on Firestore. The
        // earlier shape stripped everything except name+quantity / price,
        // so legacy events lost `kind` (broke Both-mode routing) and
        // never gained `quantityNeeded` (broke claim caps on the guest
        // screen).
        'wishlist': wishlistItems.map(_serializeItemForSave).toList(),
        // Registry links — host-curated external URLs (Zola, Amazon,
        // Babylist…). Independent of the wishlist editor; saved
        // wholesale so removals propagate.
        'registryLinks': _registryLinks,
      });
    } catch (_) {}
  }

  /// Normalises an in-memory wishlist item for Firestore persistence.
  /// Wraps the raw map so we can default missing optional fields and
  /// drop transient UI-only entries (none today, but the helper keeps
  /// future additions cleanly scoped).
  Map<String, dynamic> _serializeItemForSave(Map<String, dynamic> item) {
    final kind = (item['kind'] as String?) ??
        (listType == 'Checklist' ? 'checklist' : 'wishlist');
    final out = <String, dynamic>{
      'name': item['name'],
      'kind': kind,
    };
    if (kind == 'checklist') {
      out['quantity'] = item['quantity'] ?? '';
      if (item['quantityNeeded'] is num) {
        out['quantityNeeded'] = (item['quantityNeeded'] as num).toInt();
      }
      if (item['unlimited'] == true) out['unlimited'] = true;
      out['claimed'] = item['claimed'] ?? 0;
      out['claims']  = (item['claims'] as List?) ?? const [];
    } else {
      out['price']       = item['price']       ?? 0.0;
      out['contributed'] = item['contributed'] ?? 0.0;
      out['bought']      = item['bought']      ?? false;
      if (item['imageUrl'] is String) out['imageUrl'] = item['imageUrl'];
      if (item['url']      is String) out['url']      = item['url'];
    }
    return out;
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
    titleController.removeListener(_onTitleChanged);
    titleController.dispose();
    descController.dispose();
    locationController.removeListener(_scheduleDraftSave);
    locationController.dispose();
    locationDetailController.removeListener(_scheduleDraftSave);
    locationDetailController.dispose();
    _locationFocusNode.dispose();
    _itemNameFocusNode.dispose();
    _checklistNameFocusNode.dispose();
    _checklistQtyFocusNode.dispose();
    _wishlistPriceFocusNode.dispose();
    newItemNameController.dispose();
    newItemPriceController.dispose();
    newItemQtyController.dispose();
    _coHostEmailController.dispose();
    _capacityController.dispose();
    _customTypeCtrl.dispose();
    _registryLinkController.dispose();
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
        });
      }
    } catch (_) {/* silent — picker handles the empty list gracefully */}
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
        final migrated = migrateEventTypeName(typeName);
        selectedEventType = eventTypes.firstWhere((e) => e.name == migrated, orElse: () => eventTypes.last);
        if (selectedEventType?.name == 'Custom' && migrated.isNotEmpty && migrated != 'Custom') {
          _customTypeCtrl.text = migrated;
        } else {
          _customTypeCtrl.text = '';
        }
      }
      _coHosts.clear();
      final coHostEmails = List<String>.from(t['coHostEmails'] as List? ?? []);
      final coHostUids = List<String>.from(t['coHosts'] as List? ?? []);
      for (int i = 0; i < coHostUids.length && i < coHostEmails.length; i++) {
        _coHosts.add({'uid': coHostUids[i], 'email': coHostEmails[i]});
      }
      _templateRsvpOffsetDays = (t['rsvpDeadlineOffsetDays'] as int?) ?? 0;
      final rawTplRegistry = t['registryLinks'] as List<dynamic>? ?? [];
      _registryLinks
        ..clear()
        ..addAll(rawTplRegistry.whereType<String>());
      _rsvpDeadline = null;
      if (selectedEventType != null) currentStep = 1;
    });
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

  /// Retailer chip catalog — same five stores as [EditEventScreen]'s
  /// wishlist editor. Uses the canonical https URL rather than a custom
  /// URI scheme; modern retailer apps register these as Android App
  /// Links so launching with externalApplication hands off to the app
  /// when installed and falls through to the browser otherwise.
  static const _shopChips = <({String label, String emoji, String url})>[
    (label: 'Amazon',   emoji: '📦', url: 'https://www.amazon.com'),
    (label: 'Target',   emoji: '🎯', url: 'https://www.target.com'),
    (label: 'Etsy',     emoji: '🧶', url: 'https://www.etsy.com'),
    (label: 'Walmart',  emoji: '🛒', url: 'https://www.walmart.com'),
    (label: 'Best Buy', emoji: '🔌', url: 'https://www.bestbuy.com'),
    // Generic entry — launches the in-app browser at about:blank with
    // the address bar focused so the host can navigate anywhere.
    (label: 'Browse the web', emoji: '🌐', url: 'about:blank'),
  ];

  /// Opens the in-app [WishlistBrowserScreen] at [url] and waits for
  /// the host to tap "Add to Wishlist" inside it. The screen pops with
  /// a [WishlistBrowserResult] (or null on cancel); we append the
  /// extracted name/imageUrl/url to wishlistItems and return focus to
  /// the inline name field so the host can immediately edit the title
  /// or fill in a price.
  ///
  /// Replaces the prior `LaunchMode.externalApplication` flow that
  /// kicked the host out of the app to the retailer's native app or
  /// browser. Mirrors [EditEventScreen._openShop].
  Future<void> _openShop(String url) async {
    if (!mounted) return;
    final result = await Navigator.of(context).push<WishlistBrowserResult>(
      MaterialPageRoute(
        builder: (_) => WishlistBrowserScreen(initialUrl: url),
      ),
    );
    if (!mounted || result == null) return;
    // Use the extracted price when the WebView managed to parse one,
    // otherwise default to 0 so the host can fill it in. The result's
    // price field is already cleaned (currency / commas stripped),
    // so a single double.tryParse is enough here.
    final extractedPrice = double.tryParse(result.price) ?? 0.0;
    setState(() {
      wishlistItems.add({
        'name': result.name,
        'price': extractedPrice,
        'contributed': 0.0,
        'bought': false,
        'kind': 'wishlist',
        if (result.imageUrl.isNotEmpty) 'imageUrl': result.imageUrl,
        if (result.url.isNotEmpty) 'url': result.url,
      });
      // Clear the inline form fields after adding so the host sees
      // the form is ready for the next item. The earlier flow
      // pre-filled name + price with the extracted values for
      // post-add editing, but that caused duplicate adds — a host
      // who tapped + (thinking they hadn't added yet) would push a
      // second copy of the same item. The just-added card is
      // already visible in the items list below, so no editing
      // affordance is lost; the host can long-press / delete the
      // card to redo it instead.
      newItemNameController.clear();
      newItemPriceController.clear();
      newItemQtyController.clear();
    });
    _scheduleDraftSave();
    // Defer focus until after the popped route's transition finishes
    // — without the post-frame callback the keyboard sometimes opens
    // and closes back-to-back as the WebView screen tears down.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _itemNameFocusNode.requestFocus();
    });
  }

  /// Adds a new item of the given [kind] using whichever of the shared
  /// input controllers is relevant. The `kind` field is stamped on
  /// every item so a Both-mode event can route gifts vs. potluck items
  /// to their own tabs at render time.
  void _addItemOfKind(String kind) {
    if (newItemNameController.text.trim().isEmpty) return;
    setState(() {
      if (kind == 'checklist') {
        if (_newItemUnlimited) {
          // Unlimited item — `quantity` carries '∞' for legacy render
          // paths that show the raw string, no `quantityNeeded`,
          // `unlimited: true` for the guest screen's cap bypass.
          wishlistItems.add({
            'name': newItemNameController.text.trim(),
            'quantity': '∞',
            'unlimited': true,
            'claimed': 0,
            'claims': <Map<String, dynamic>>[],
            'kind': 'checklist',
          });
          _newItemUnlimited = false;
        } else {
          final qtyStr = newItemQtyController.text.trim();
          if (qtyStr.isEmpty) return;
          // Parse the qty input as an integer count needed. Stored as
          // `quantityNeeded` so the guest screen can cap claims and
          // chip choices to the unclaimed remainder. The original
          // `quantity` String is kept for back-compat (legacy rendering
          // paths that show "Qty: <free-form>") so existing items
          // don't lose their human label.
          final qtyNeeded = int.tryParse(qtyStr.replaceAll(RegExp(r'[^0-9]'), ''));
          wishlistItems.add({
            'name': newItemNameController.text.trim(),
            'quantity': qtyStr,
            if (qtyNeeded != null && qtyNeeded > 0) 'quantityNeeded': qtyNeeded,
            'claimed': 0,
            'claims': <Map<String, dynamic>>[],
            'kind': 'checklist',
          });
        }
      } else {
        if (newItemPriceController.text.trim().isEmpty) return;
        wishlistItems.add({
          'name': newItemNameController.text.trim(),
          'price': double.tryParse(newItemPriceController.text) ?? 0.0,
          'contributed': 0.0,
          'bought': false,
          'kind': 'wishlist',
        });
      }
      newItemNameController.clear();
      newItemPriceController.clear();
      newItemQtyController.clear();
    });
    _scheduleDraftSave();
    // Return focus to the section's name field so the host can type
    // the next item without re-tapping. Without this, the keyboard's
    // caret stays in whichever subfield (qty / price) the host last
    // touched, and entering a long potluck list becomes a tap-tap-
    // tap chore.
    (kind == 'checklist' ? _checklistNameFocusNode : _itemNameFocusNode)
        .requestFocus();
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
          style: TextStyle(fontWeight: FontWeight.w700, color: _fg),
        ),
        leading: currentStep > 0
            ? IconButton(icon: Icon(Icons.arrow_back, color: _fg), onPressed: () => setState(() => currentStep--))
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
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: Text("What's the occasion?", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _fg)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Text("Pick a type and we'll set the vibe", style: TextStyle(fontSize: 14, color: _muted)),
        ),
        Expanded(
          // Wait for the user-doc fetch (lines ~409-413) before
          // painting the grid. Without this, the picker rendered on
          // the first frame defaults to personalEventTypes for any
          // tier whose accountType hasn't loaded yet — businessPlus
          // owners briefly saw the personal list before the setState
          // flipped them to businessEventTypes. Loader is a no-op for
          // signed-out callers and resolves within a frame or two
          // for signed-in users.
          child: _accountType == null
              ? const Center(child: CircularProgressIndicator(color: _purple, strokeWidth: 2))
              : GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 0.95,
            ),
            itemCount: _tierEventTypes.length,
            itemBuilder: (context, index) {
              final type = _tierEventTypes[index];
              final isSelected = selectedEventType?.name == type.name;
              // Dark-mode-safe accent. Several event-type primaries
              // (Corporate, Graduation, Holiday, Divorce) are nearly
              // black and disappeared against the dark card surface
              // — Corporate especially. `onDarkSurface` lifts those
              // to a readable shade in dark mode and is a no-op in
              // light mode, so the original brand colors are
              // preserved on light backgrounds.
              final accent = onDarkSurface(type.primary, isDark: _isDark);
              return GestureDetector(
                onTap: () => setState(() {
                  selectedEventType = type;
                  // Plus ones is hidden for everything except Corporate/Wedding,
                  // so clear any stale flag from a prior selection. Without
                  // this, switching Wedding → Birthday would silently keep
                  // allowPlusOnes=true on the saved doc.
                  if (!_supportsPlusOnes) {
                    _allowPlusOnes = false;
                    _maxPlusOnes = 1;
                  }
                }),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  decoration: BoxDecoration(
                    color: isSelected ? accent.withValues(alpha: 0.18) : _card,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: isSelected ? accent : _border,
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        height: 48,
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                        ),
                        child: Center(child: Text(type.emoji, style: const TextStyle(fontSize: 26))),
                      ),
                      const SizedBox(height: 8),
                      // Label always uses the theme foreground (white
                      // in dark, AppColors.dark in light) regardless
                      // of selected state. The previous selected-state
                      // override painted the label in `type.primary`,
                      // which on dark mode was a near-black-on-near-
                      // black render and made the label invisible the
                      // moment a card was tapped.
                      Text(type.name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _fg)),
                      if (isSelected)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Icon(Icons.check_circle, color: accent, size: 16),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        if (selectedEventType?.name == 'Custom')
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: TextField(
              controller: _customTypeCtrl,
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => _scheduleDraftSave(),
              style: TextStyle(color: _fg, fontSize: 15),
              cursorColor: _purple,
              decoration: InputDecoration(
                hintText: 'Name your custom event type',
                hintStyle: TextStyle(color: _muted),
                prefixIcon: Icon(Icons.edit_outlined, size: 18, color: _muted),
                filled: true,
                fillColor: _card,
                border:        OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _border)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _border)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _purple, width: 1.5)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              ),
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
                  style: TextStyle(color: _fg),
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
            const SizedBox(height: 12),
            _fieldLabel('Room / Suite / Area (optional)'),
            _glowWrap(TextField(
              controller: locationDetailController,
              style: TextStyle(color: _fg),
              decoration: _inputDecoration('e.g. Library, Room 204, Main Stage').copyWith(
                prefixIcon: Icon(Icons.meeting_room_outlined, size: 18, color: _muted),
              ),
            )),
            const SizedBox(height: 16),
            _fieldLabel('Description'),
            _glowWrap(TextField(
              controller: descController,
              maxLines: 2,
              style: TextStyle(color: _fg),
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
                          Text('Make this event public', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _isPublic ? _purple : _fg)),
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
            // Outdoor toggle — drives the weather widget on the guest
            // screen. Off by default (most parties are indoor) so the
            // weather pill stays out of the way unless the host opts
            // in. A purple accent matches the public toggle above.
            Container(
              decoration: BoxDecoration(
                color: _card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _isOutdoor ? _purple : _border, width: _isOutdoor ? 1.5 : 1),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(Icons.wb_sunny_outlined, size: 16, color: _isOutdoor ? _purple : _muted),
                      const SizedBox(width: 6),
                      Text('Outdoor event', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _isOutdoor ? _purple : _fg)),
                    ]),
                    const SizedBox(height: 2),
                    Text('Shows the weather forecast on the event page', style: TextStyle(fontSize: 11, color: _muted)),
                  ]),
                ),
                Switch(
                  value: _isOutdoor,
                  onChanged: (v) { setState(() => _isOutdoor = v); _scheduleDraftSave(); },
                  activeTrackColor: _purple,
                  activeThumbColor: Colors.white,
                ),
              ]),
            ),
            const SizedBox(height: 10),
            // Event-date reference, shown only when the host has
            // already picked an event date. Gives them context when
            // setting an RSVP deadline so they're not picking a date
            // in the abstract — they can see "Event is on May 20"
            // right above the deadline tile.
            if (selectedDate != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6, left: 4),
                child: Row(children: [
                  Icon(Icons.event, size: 13, color: _muted),
                  const SizedBox(width: 6),
                  Text(
                    'Event is on ${const ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'][selectedDate!.month - 1]} ${selectedDate!.day}',
                    style: TextStyle(fontSize: 12, color: _muted, fontWeight: FontWeight.w600),
                  ),
                ]),
              ),
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
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _fg),
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

    // Step 3 layout — banner + scrollable middle + pinned generate
    // button. Earlier the middle was an `Expanded > ListView` and the
    // Lists toggles + BROWSE STORES sections were SIBLINGS of that
    // Expanded inside the outer Column. When the keyboard opened, the
    // fixed-height children (banner ~60 + toggles ~140 + browse ~120
    // + button ~88 = ~408) overran the keyboard-shrunken viewport and
    // Expanded got squeezed to negative — RenderFlex overflowed by
    // ~78px. Pulling everything-but-banner-and-button into one SCV
    // makes the whole middle scroll as one unit, so the keyboard can
    // never push the layout below zero remaining space.
    return Column(
      children: [
        // Themed banner — emoji-only now. Title text was removed
        // because the parent Scaffold's AppBar already shows the
        // step name ("Wishlist"), and the duplicated event name made
        // the top of Step 3 feel busy. Banner kept (still useful as
        // a colored accent that ties the step to the chosen event
        // type) but slimmed from 60→36 to suit the trimmed content.
        Container(
          height: 36,
          color: type.primary,
          child: Center(
            child: Text(type.emoji, style: const TextStyle(fontSize: 20)),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Lists section — two independent toggles. A host can enable
                // wishlist (gift contributions), checklist (potluck "I'll bring
                // X" claims), neither, or both. Internally this maps to
                // listType ∈ {No List, Wishlist, Checklist, Both} so legacy
                // readers (templates, analytics) still get a stable string.
                _glowWrap(Container(
                  color: _card,
                  // Slightly tighter than the prior 16/14/16/14: less
                  // bottom padding so the gap to the retailer chip
                  // row below feels like a continuation of the same
                  // section rather than a separate one.
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Lists', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _fg)),
                      const SizedBox(height: 4),
                      // Subtitle removed — the toggle labels and
                      // descriptions inside _listTypeToggle make the
                      // intent self-explanatory.
                      if (kWishlistEnabled)
                        _listTypeToggle(
                          type: type,
                          icon: Icons.card_giftcard_outlined,
                          label: 'Wishlist',
                          description: 'Guests contribute money or buy items',
                          value: _hasWishlist,
                          onChanged: _setHasWishlist,
                        ),
                      _listTypeToggle(
                        type: type,
                        icon: Icons.checklist_outlined,
                        label: 'Checklist',
                        description: "Guests claim items they'll bring (great for potlucks)",
                        value: _hasChecklist,
                        onChanged: _setHasChecklist,
                      ),
                    ],
                  ),
                )),
                // Retailer chips — wishlist mode only. Stripped down
                // from the prior layout: dropped the BROWSE STORES
                // label and the multi-line instruction text below, and
                // tightened the chip padding. Chips are self-explanatory
                // and the instruction text was paraphrasing what the
                // chips already imply. Saves ~85px of fixed-height
                // content per show, which on its own clears the
                // earlier 78px keyboard overflow on most phones.
                // Show chips whenever Wishlist is enabled, regardless
                // of whether Checklist is also on. Earlier this gated
                // on listType=='Wishlist' which excluded the 'Both'
                // mode — chips disappeared the moment the host turned
                // on Checklist alongside Wishlist.
                if (_hasWishlist)
                  Container(
                    color: _card,
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Tells the host what the chips actually do —
                        // tapping one opens the retailer in the in-app
                        // browser and lets them add items via the
                        // share sheet. Without context the icons just
                        // looked like decorative branding.
                        Padding(
                          padding: const EdgeInsets.only(left: 4, bottom: 6),
                          child: Text(
                            'Browse stores to add items:',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: _muted,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(children: [
                            for (final s in _shopChips) ...[
                              _shopChip(s),
                              const SizedBox(width: 6),
                            ],
                          ]),
                        ),
                      ],
                    ),
                  ),
                // Items area. When listType=='No List' show an empty-
                // state with a fixed minimum height so it doesn't
                // collapse to zero inside the SCV. Otherwise stack
                // one or both kind sections directly — the outer SCV
                // owns scrolling now, so this no longer needs its own
                // ListView.
                if (listType == 'No List')
                  SizedBox(
                    height: 240,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('🚫', style: TextStyle(fontSize: 48)),
                          const SizedBox(height: 12),
                          Text('No list for this event', style: TextStyle(fontSize: 16, color: _muted)),
                          const SizedBox(height: 4),
                          Text('Both tabs will be hidden from guests', style: TextStyle(fontSize: 13, color: _muted)),
                        ],
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_hasWishlist) _buildKindSection('wishlist', type),
                        if (_hasWishlist && _hasChecklist) const SizedBox(height: 18),
                        if (_hasChecklist) _buildKindSection('checklist', type),
                      ],
                    ),
                  ),
                // Registry Links — visible regardless of listType so a
                // host can attach Zola/Amazon/Babylist URLs even when
                // the event has 'No List'. Saved on a dedicated field
                // independent of the wishlist editor above.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: _buildRegistryLinksSection(type),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: _saving ? null : () async {
                // Required-field guard. Without this, an empty title
                // would race straight into the Firestore create which
                // rules reject with permission-denied (`title.size() > 0`),
                // and the only feedback was a transient default-duration
                // SnackBar from the catch block — easy to miss, hence
                // the "button highlights but nothing happens" report.
                final missing = <String>[];
                if (titleController.text.trim().isEmpty) missing.add('a title');
                if (selectedEventType == null) missing.add('an event type');
                if (selectedDate == null) missing.add('a date');
                if (missing.isNotEmpty) {
                  final list = missing.length == 1
                      ? missing.first
                      : missing.length == 2
                          ? '${missing[0]} and ${missing[1]}'
                          : '${missing.sublist(0, missing.length - 1).join(', ')}, and ${missing.last}';
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('Please add $list before generating a QR code.'),
                    backgroundColor: AppColors.gold,
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(seconds: 4),
                  ));
                  return;
                }
                final user = FirebaseAuth.instance.currentUser;
                if (user == null) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text("You're signed out. Sign in and try again."),
                    backgroundColor: Colors.redAccent,
                    behavior: SnackBarBehavior.floating,
                    duration: Duration(seconds: 4),
                  ));
                  return;
                }
                _draftTimer?.cancel();
                setState(() => _saving = true);
                try {
                  final isRecurring = _isRecurring && _isBusiness;
                  final recurrenceRule = isRecurring ? _buildRecurrenceRule() : null;
                  final seriesId = isRecurring
                      ? FirebaseFirestore.instance.collection('recurringEvents').doc().id
                      : null;
                  // Mirrors the draft-save serializer so fields like
                  // `kind`, `quantityNeeded`, `claims`, etc. survive
                  // the create write. Earlier the shape was stripped
                  // down to name+quantity / price and dropped every
                  // discriminator; now both paths use the same helper.
                  final wishlistData = wishlistItems.map(_serializeItemForSave).toList();
                  final finalData = {
                    'accountType': _accountType ?? 'personal',
                    'title': titleController.text,
                    'description': descController.text,
                    'location': locationController.text,
                    'locationDetail': locationDetailController.text.trim(),
                    'date': selectedDate != null ? Timestamp.fromDate(selectedDate!) : null,
                    'time': selectedTime != null ? '${selectedTime!.hour}:${selectedTime!.minute}' : null,
                    'eventType': _resolvedEventTypeName,
                    'eventEmoji': selectedEventType?.emoji,
                    'hostId': user.uid,
                    'hostName': user.displayName ?? 'Host',
                    'listType': listType,
                    'wishlist': wishlistData,
                    'registryLinks': _registryLinks,
                    'yes': 0,
                    'maybe': 0,
                    'no': 0,
                    'isPublic': _isPublic,
                    'isOutdoor': _isOutdoor,
                    'rsvpDeadline': _rsvpDeadline != null ? Timestamp.fromDate(_rsvpDeadline!) : null,
                    'coHosts': _coHosts.map((c) => c['uid'] as String).toList(),
                    'zipCode': _zipCode,
                    'isRecurring': isRecurring,
                    'recurringSeriesId': ?seriesId,
                    'recurrenceRule':    ?recurrenceRule,
                    // Same clamp as the draft-save path above — see
                    // _persistedCapacity getter for the rationale.
                    'capacity': _persistedCapacity,
                    'allowPlusOnes': _allowPlusOnes,
                    'maxPlusOnes': _allowPlusOnes ? _maxPlusOnes : null,
                    'allowWaitlist': _persistedCapacity != null && _allowWaitlist,
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
                        'locationDetail': locationDetailController.text.trim(),
                        'time': selectedTime != null ? '${selectedTime!.hour}:${selectedTime!.minute}' : null,
                        'eventType': _resolvedEventTypeName,
                        'eventEmoji': selectedEventType?.emoji,
                        'listType': listType,
                        'wishlist': wishlistData,
                        'registryLinks': _registryLinks,
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
                  if (!mounted) return;
                  // Prompt the host to order stickers / invitations before
                  // dropping them on the QR screen. Whichever option they
                  // pick (or skip), they always end up on the QR screen.
                  //
                  // While [kMerchOrderingEnabled] is false (beta gate),
                  // skip the prompt entirely and go straight to the QR
                  // screen — the prompt's only outcomes are merch flows
                  // that are themselves hidden right now.
                  final pick = kMerchOrderingEnabled
                      ? await _showPostEventMerchPrompt()
                      : null;
                  if (!mounted) return;
                  if (pick == 'sticker' || pick == 'invitation') {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(builder: (_) => GenerateQRCodeScreen(eventId: eventId, eventTitle: titleController.text)),
                    );
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        fullscreenDialog: true,
                        builder: (_) => OrderMerchScreen(
                          eventId: eventId,
                          eventTitle: titleController.text,
                          hostName: user.displayName ?? 'Host',
                          eventDate: selectedDate,
                          eventType: _resolvedEventTypeName,
                          initialProduct: pick == 'sticker'
                              ? MerchProduct.sticker
                              : MerchProduct.invitation,
                        ),
                      ),
                    );
                  } else {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(builder: (_) => GenerateQRCodeScreen(eventId: eventId, eventTitle: titleController.text)),
                    );
                  }
                } catch (e) {
                  // Surface the failure clearly. Default SnackBar
                  // duration is ~1.5s which is easy to miss and was
                  // part of why this looked like "nothing happened"
                  // when the underlying error was a rules rejection.
                  debugPrint('[CreateEvent] save/navigate failed: $e');
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('Error saving event: $e'),
                      backgroundColor: Colors.redAccent,
                      behavior: SnackBarBehavior.floating,
                      duration: const Duration(seconds: 6),
                    ));
                  }
                } finally {
                  // Reset _saving even on success — pushReplacement
                  // tears the screen down on the success path so the
                  // setState is a no-op there, but on any catch path
                  // we need the button re-enabled so the host can
                  // retry without backing out of the screen.
                  if (mounted) setState(() => _saving = false);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: type.primary,
                foregroundColor: Colors.white,
                disabledBackgroundColor: type.primary.withValues(alpha: 0.55),
                disabledForegroundColor: Colors.white.withValues(alpha: 0.85),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: _saving
                  ? const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.2),
                      ),
                      SizedBox(width: 12),
                      Text('Saving event…', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    ])
                  : const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
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

  /// Bottom sheet shown immediately after a host saves a new event.
  /// Returns the user's pick: `'sticker'`, `'invitation'`, or `null` (Maybe
  /// Later / dismissed). Caller routes accordingly.
  Future<String?> _showPostEventMerchPrompt() {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: _card,
      isScrollControlled: true,
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
                'Your event is ready! 🎉',
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'FredokaOne', fontSize: 24, color: _fg),
              ),
              const SizedBox(height: 8),
              Text(
                'Want printed merch with your QR code on it?',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: _muted, height: 1.4),
              ),
              const SizedBox(height: 22),
              SizedBox(
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.pop(sheetCtx, 'sticker'),
                  icon: const Text('🌟', style: TextStyle(fontSize: 18)),
                  label: const Text('Order Stickers',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _purple,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    elevation: 0,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.pop(sheetCtx, 'invitation'),
                  icon: const Text('💌', style: TextStyle(fontSize: 18)),
                  label: const Text('Order Invitations',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    elevation: 0,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              TextButton(
                onPressed: () => Navigator.pop(sheetCtx),
                child: Text(
                  'Maybe Later',
                  style: TextStyle(fontSize: 14, color: _muted, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Independent on/off row for the Wishlist or Checklist feature.
  /// Replaces the prior 3-chip mutually-exclusive selector so a host
  /// can enable both lists on the same event (e.g. potluck birthday
  /// where guests bring food AND contribute to a gift).
  Widget _listTypeToggle({
    required EventType type,
    required IconData icon,
    required String label,
    required String description,
    required bool value,
    required void Function(bool) onChanged,
  }) {
    // Settings-style row: small leading icon (no colored tile),
    // single-line label with description as a quiet trailing tail
    // on the same line, compact Switch. Total row height ~32 —
    // about half the previous 56. The colored emphasis comes from
    // the Switch when on; no separate tile needed.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: value ? type.primary : _muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: RichText(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              text: TextSpan(
                style: TextStyle(
                  fontFamily: 'Nunito', fontSize: 13.5,
                  fontWeight: FontWeight.w700, color: _fg,
                ),
                children: [
                  TextSpan(text: label),
                  TextSpan(
                    text: '  ·  $description',
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 12,
                      color: _muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Transform.scale(
            scale: 0.85,
            child: Switch(
              value: value,
              onChanged: onChanged,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              activeThumbColor: Colors.white,
              activeTrackColor: type.primary,
              inactiveThumbColor: _muted,
              inactiveTrackColor: _border,
            ),
          ),
        ],
      ),
    );
  }

  Widget _shopChip(({String label, String emoji, String url}) s) {
    return InkWell(
      onTap: () => _openShop(s.url),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        // Compacter padding (12/8 vs the original 14/10) and a tighter
        // emoji ↔ label gap (6 vs 8). Roughly 18% smaller per chip,
        // which adds up across 6 chips and helps Step 3 feel less
        // crowded under the toggle list.
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: _bg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(s.emoji, style: const TextStyle(fontSize: 15)),
          const SizedBox(width: 6),
          Text(
            s.label,
            style: TextStyle(
              fontFamily: 'Nunito', fontSize: 12.5, fontWeight: FontWeight.w800,
              color: _fg,
            ),
          ),
        ]),
      ),
    );
  }

  /// One section of the items area — either Wishlist or Checklist.
  /// Each section owns its own header, its own input row (the price
  /// vs. quantity field switches by [kind]), its own Add button, and
  /// its own filtered list of items. Items keep their original index
  /// in the master `wishlistItems` array so delete still finds the
  /// right entry.
  Widget _buildKindSection(String kind, EventType type) {
    final isChecklist = kind == 'checklist';
    final headerLabel = isChecklist ? 'Checklist' : 'Wishlist';
    final headerIcon = isChecklist ? Icons.checklist_outlined : Icons.card_giftcard_outlined;
    final emptyEmoji = isChecklist ? '📋' : '🎁';
    final emptyTitle = isChecklist ? 'No checklist items yet' : 'No wishlist items yet';
    final emptySub = isChecklist ? 'Add items for guests to claim' : 'Add items for guests to gift';

    final indices = <int>[];
    for (var i = 0; i < wishlistItems.length; i++) {
      if (_itemKind(wishlistItems[i]) == kind) indices.add(i);
    }

    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(headerIcon, size: 18, color: type.primary),
            const SizedBox(width: 8),
            Text(headerLabel,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _fg)),
          ]),
          const SizedBox(height: 10),
          // Input row — price for wishlist, quantity for checklist.
          // Controllers are shared across both sections; each Add
          // button clears them so jumping between sections is clean.
          // The name field's textInputAction is .next so tapping the
          // keyboard's Next button advances to the secondary field
          // (qty for checklist, price for wishlist) instead of
          // dismissing the keyboard.
          Row(children: [
            Expanded(
              child: TextField(
                controller: newItemNameController,
                focusNode: isChecklist ? _checklistNameFocusNode : _itemNameFocusNode,
                style: TextStyle(color: _fg),
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => (isChecklist ? _checklistQtyFocusNode : _wishlistPriceFocusNode).requestFocus(),
                decoration: _inputDecoration(isChecklist ? 'Item to bring' : 'Item name'),
              ),
            ),
            const SizedBox(width: 8),
            // Quantity slot. Three states:
            //   • wishlist → $ Price TextField (80 wide)
            //   • checklist + capped → × 12 TextField (80) + "Unlimited" outlined toggle
            //   • checklist + unlimited → "Unlimited ✓" filled chip, no TextField
            if (!isChecklist)
              SizedBox(
                width: 80,
                child: TextField(
                  controller: newItemPriceController,
                  focusNode: _wishlistPriceFocusNode,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _addItemOfKind(kind),
                  style: TextStyle(color: _fg),
                  decoration: _inputDecoration('\$ Price'),
                ),
              )
            else if (_newItemUnlimited)
              GestureDetector(
                onTap: () => setState(() => _newItemUnlimited = false),
                child: Container(
                  height: 48,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _purple,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'Unlimited ✓',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13),
                  ),
                ),
              )
            else ...[
              SizedBox(
                width: 80,
                child: TextField(
                  controller: newItemQtyController,
                  focusNode: _checklistQtyFocusNode,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _addItemOfKind(kind),
                  style: TextStyle(color: _fg),
                  // Hint shows × N convention so the host knows
                  // it's a count, not a free-form descriptor.
                  decoration: _inputDecoration('× 12'),
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () => setState(() {
                  _newItemUnlimited = true;
                  newItemQtyController.clear();
                }),
                child: Container(
                  height: 48,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _card,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _purple, width: 1.5),
                  ),
                  child: const Text(
                    'Unlimited',
                    style: TextStyle(color: _purple, fontWeight: FontWeight.w800, fontSize: 13),
                  ),
                ),
              ),
            ],
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: () => _addItemOfKind(kind),
              style: ElevatedButton.styleFrom(
                backgroundColor: type.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              ),
              child: const Icon(Icons.add),
            ),
          ]),
          if (isChecklist && _newItemUnlimited)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Text(
                'Anyone can claim — no limit',
                style: TextStyle(fontSize: 12, color: _muted),
              ),
            ),
          const SizedBox(height: 12),
          if (indices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Column(children: [
                  Text(emptyEmoji, style: const TextStyle(fontSize: 36)),
                  const SizedBox(height: 6),
                  Text(emptyTitle, style: TextStyle(fontSize: 14, color: _muted, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(emptySub, style: TextStyle(fontSize: 12, color: _muted)),
                ]),
              ),
            )
          else
            ...indices.map(_buildWishlistItem),
        ],
      ),
    );
  }

  Widget _buildWishlistItem(int index) {
    final item = wishlistItems[index];
    // Per-item kind beats the screen-level listType — when the host
    // has Both lists enabled, items still need to render with the
    // shape that matches THEIR kind, not the most recently selected
    // toggle. Falls back to the listType-based heuristic in
    // [_itemKind] for legacy items missing the field.
    final isChecklist = _itemKind(item) == 'checklist';
    final isUnlimited = item['unlimited'] == true;
    final subtitle = isChecklist
        ? (isUnlimited ? 'Qty needed: ∞' : 'Qty needed: ${item['quantity']}')
        : '\$${(item['price'] as double? ?? 0.0).toStringAsFixed(2)}';
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
                Text(item['name'] as String, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _fg)),
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

  // ── Registry Links ──────────────────────────────────────────
  /// Friendly label for a registry URL. Recognised registries get a
  /// branded name; everything else falls back to the bare host (with
  /// a leading `www.` stripped).
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

  /// Append the typed URL to [_registryLinks]. Best-effort prepends
  /// `https://` to a bare-domain paste so the saved string is launch-
  /// ready and [_registryLabel]'s `Uri.tryParse` has a scheme. Silent
  /// no-op on empties or duplicates.
  void _addRegistryLink() {
    final raw = _registryLinkController.text.trim();
    if (raw.isEmpty) return;
    final url = raw.startsWith('http') ? raw : 'https://$raw';
    if (_registryLinks.contains(url)) {
      _registryLinkController.clear();
      return;
    }
    setState(() {
      _registryLinks.add(url);
      _registryLinkController.clear();
    });
    _scheduleDraftSave();
  }

  Widget _buildRegistryLinksSection(EventType type) {
    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.card_giftcard_outlined, size: 18, color: type.primary),
            const SizedBox(width: 8),
            Text('Registry Links',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _fg)),
          ]),
          const SizedBox(height: 4),
          Text('Paste a registry URL — guests can tap through from the event page.',
              style: TextStyle(fontSize: 12, color: _muted)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _registryLinkController,
                keyboardType: TextInputType.url,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                style: TextStyle(color: _fg),
                onSubmitted: (_) => _addRegistryLink(),
                decoration: _inputDecoration('https://www.zola.com/...'),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _addRegistryLink,
              style: ElevatedButton.styleFrom(
                backgroundColor: type.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              ),
              child: const Icon(Icons.add),
            ),
          ]),
          if (_registryLinks.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (var i = 0; i < _registryLinks.length; i++) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: _bg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _border),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(children: [
                  Container(
                    width: 32, height: 32,
                    decoration: BoxDecoration(
                      color: _purple.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.card_giftcard_outlined, size: 16, color: _purple),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_registryLabel(_registryLinks[i]),
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _fg)),
                        Text(_registryLinks[i],
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: _muted)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.redAccent, size: 20),
                    onPressed: () {
                      setState(() => _registryLinks.removeAt(i));
                      _scheduleDraftSave();
                    },
                  ),
                ]),
              ),
            ],
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Paste another URL above and tap + to include more.',
                style: TextStyle(fontSize: 12, color: _muted, fontStyle: FontStyle.italic),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLocationField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _glowWrap(GooglePlaceAutoCompleteTextField(
          textEditingController: locationController,
          focusNode: _locationFocusNode,
          googleAPIKey: _placesApiKey,
          // 400ms — long enough to avoid burning billable autocomplete
          // requests on every keystroke, short enough to feel responsive.
          debounceTime: 400,
          // US-only — the rest of the address flow (state dropdown, ZIP)
          // assumes US addresses.
          countries: const ['us'],
          isLatLngRequired: false,
          textStyle: TextStyle(color: _fg, fontSize: 15),
          // Match the rest of the form's input styling.
          inputDecoration: _inputDecoration('e.g. 123 Celebration Lane, Seaside CA').copyWith(
            prefixIcon: Icon(Icons.location_on_outlined, size: 18, color: _muted),
          ),
          // Fired when the user taps a suggestion. The package writes the
          // full description into the controller; we kick off a place
          // details fetch so we can extract the postal code separately.
          itemClick: (Prediction p) {
            final desc = p.description ?? '';
            locationController.text = desc;
            locationController.selection = TextSelection.fromPosition(
              TextPosition(offset: desc.length),
            );
            setState(() => _zipCode = '');
            final placeId = p.placeId;
            if (placeId != null && placeId.isNotEmpty) {
              _fetchZipFromPlaceId(placeId);
            }
            _scheduleDraftSave();
            // iOS doesn't reliably close the autocomplete overlay on
            // focus loss alone — also nudge the system primary focus
            // so the keyboard drops. Microtask defers the unfocus past
            // the text assignment above so the package's internal
            // onChanged handler doesn't re-open the overlay.
            Future.microtask(() {
              _locationFocusNode.unfocus();
              FocusManager.instance.primaryFocus?.unfocus();
            });
          },
          // Render each suggestion with the same look as the old custom
          // list: pin icon + main text (street) + secondary (city/state).
          itemBuilder: (context, index, Prediction p) {
            final structured = p.structuredFormatting;
            final main = structured?.mainText ?? p.description ?? '';
            final secondary = structured?.secondaryText ?? '';
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              color: _card,
              child: Row(children: [
                const Icon(Icons.location_on_outlined, size: 16, color: _purple),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(main, style: TextStyle(fontSize: 14, color: _fg, fontWeight: FontWeight.w500)),
                      if (secondary.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(secondary, style: TextStyle(fontSize: 11, color: _muted)),
                      ],
                    ],
                  ),
                ),
              ]),
            );
          },
          seperatedBuilder: Divider(height: 1, color: _border, indent: 40),
        )),
        if (_zipCode.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              Icon(Icons.pin_drop_outlined, size: 13, color: _muted),
              const SizedBox(width: 4),
              Text('ZIP: $_zipCode', style: TextStyle(fontSize: 12, color: _muted)),
            ]),
          ),
      ],
    );
  }

  /// Fetches the place details for [placeId] and pulls the postal_code out
  /// of the address_components array. Mirrors what the old custom
  /// `_selectSuggestion` did — kept as a separate helper because the
  /// `google_places_flutter` widget hands us a `Prediction` without parsed
  /// components, so we still need a follow-up details call to populate ZIP.
  Future<void> _fetchZipFromPlaceId(String placeId) async {
    try {
      final uri = Uri.https('maps.googleapis.com', '/maps/api/place/details/json', {
        'place_id': placeId,
        'fields': 'address_components',
        'key': _placesApiKey,
      });
      final response = await http.get(uri);
      if (!mounted) return;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      // Surface API auth failures to the developer console — Google's
      // status string lives in `status`, the human-readable cause in
      // `error_message`. Without this, an expired key / disabled API /
      // wrong restriction silently returned nothing and the only
      // symptom was "autocomplete looks broken".
      final status = data['status'] as String?;
      if (status != null && status != 'OK' && status != 'ZERO_RESULTS') {
        debugPrint('[Places] details rejected: status=$status '
            'message=${data['error_message']} '
            '(see _placesApiKey comment for GCP setup pitfalls)');
      }
      final result = data['result'] as Map<String, dynamic>?;
      if (result == null) return;
      final comps = result['address_components'] as List? ?? [];
      for (final comp in comps) {
        final types = List<String>.from((comp as Map)['types'] as List? ?? []);
        if (types.contains('postal_code')) {
          setState(() => _zipCode = (comp['long_name'] as String?) ?? '');
          break;
        }
      }
    } catch (e) {
      debugPrint('[Places] details request failed: $e');
    }
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
                    Text('Set capacity limit', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _capacityEnabled ? _purple : _fg)),
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
            style: TextStyle(color: _fg),
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
                      Text('Allow waitlist', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _allowWaitlist ? _purple : _fg)),
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
        // Plus-ones is gated to Corporate and Wedding event types only.
        // For every other type the toggle and the count selector are
        // hidden entirely, and _allowPlusOnes stays false in the saved doc.
        if (_supportsPlusOnes) ...[
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
                      Text('Allow plus ones', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _allowPlusOnes ? _purple : _fg)),
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
                              color: _maxPlusOnes == opt.$1 ? _purple : _fg,
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
                  Text('Make this recurring', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _isRecurring ? _purple : _fg)),
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
                    Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: selected ? _purple : _fg)),
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
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _fg),
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
            style: TextStyle(color: _fg),
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
        child: Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _fg)),
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
          Text(text, style: TextStyle(fontSize: 14, color: _fg)),
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
  Color get _fg     => _isDark ? Colors.white : AppColors.dark;

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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const Icon(Icons.bookmark_outlined, color: _gold, size: 20),
                  const SizedBox(width: 8),
                  Text('Your Templates', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _fg)),
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
                                Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _fg)),
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
