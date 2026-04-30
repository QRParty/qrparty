import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../utils.dart';
import 'wishlist_browser_screen.dart';

// ── Theme palette ──────────────────────────────────────────────
const _bgDark      = Color(0xFF2D3047); // dark-mode scaffold
const _bgLight     = Color(0xFFF8F7FC);
const _cardDark    = Color(0xFF383B56);
const _cardLight   = Colors.white;
const _borderDark  = Color(0xFF4A4E6B);
const _borderLight = Color(0xFFE0E8E0);
const _mutedDark   = Color(0xFFA9A6B8);
const _mutedLight  = Color(0xFF8892A4);
const _purple      = Color(0xFF9C7FD4);

// ─── SCREEN — EDIT EVENT ─────────────────────────────────────
class EditEventScreen extends StatefulWidget {
  final String eventId;
  final Map<String, dynamic> eventData;
  const EditEventScreen({super.key, required this.eventId, required this.eventData});
  @override
  State<EditEventScreen> createState() => _EditEventScreenState();
}

class _EditEventScreenState extends State<EditEventScreen> {
  late TextEditingController _titleController;
  late TextEditingController _locationController;
  late TextEditingController _descController;
  DateTime? _selectedDate;
  TimeOfDay? _selectedTime;
  bool _isPublic = false;
  DateTime? _rsvpDeadline;
  bool _saving = false;
  bool _isBusiness = false;
  bool _capacityEnabled = false;
  final TextEditingController _capacityController = TextEditingController();

  /// Single source of truth for the capacity that lands on Firestore.
  /// Returns null whenever the toggle is off or the parsed value isn't
  /// a positive integer — closes the `capacity: 0 → "Event is full"
  /// forever` bug at the data-layer entry point. Mirrors the same
  /// helper in create_event_screen.dart.
  int? get _persistedCapacity {
    if (!_capacityEnabled) return null;
    final n = int.tryParse(_capacityController.text.trim());
    return (n != null && n > 0) ? n : null;
  }
  bool _allowPlusOnes = false;
  int? _maxPlusOnes = 1;
  bool _allowWaitlist = true;
  final TextEditingController _coHostEmailController = TextEditingController();
  bool _lookingUpCoHost = false;
  String? _coHostError;
  final List<Map<String, dynamic>> _coHosts = [];

  // ── Wishlist state ────────────────────────────────────────────
  // Host-side wishlist editor: list of items + retailer shop chips +
  // inline Add Item form. Items here mirror the array stamped on the
  // event doc at creation time; the existing _save() flushes any
  // edits back to Firestore alongside the rest of the form.
  String _listType = 'Wishlist';
  final List<Map<String, dynamic>> _wishlistItems = [];
  final TextEditingController _newItemNameCtrl  = TextEditingController();
  final TextEditingController _newItemPriceCtrl = TextEditingController();
  final TextEditingController _newItemQtyCtrl   = TextEditingController();
  // Focus target for the item-name field — refocused after the in-app
  // browser returns so the host can immediately edit the auto-extracted
  // title. Mirrors the create-event screen.
  final FocusNode _itemNameFocus = FocusNode();

  /// Retailer chip catalog — uses the retailer's canonical https URL
  /// rather than a custom URI scheme. Most modern retailer apps register
  /// these as Android App Links / iOS Universal Links, so launching the
  /// https URL with `LaunchMode.externalApplication` lets the OS pick
  /// the registered app when installed and falls back to the browser
  /// otherwise. The custom-scheme `<intent>` queries in AndroidManifest
  /// stay too, since some apps still respond to those, but we don't
  /// need to fire them client-side anymore.
  static const _shopChips = <({String label, String emoji, String url})>[
    (label: 'Amazon',   emoji: '📦', url: 'https://www.amazon.com'),
    (label: 'Target',   emoji: '🎯', url: 'https://www.target.com'),
    (label: 'Etsy',     emoji: '🧶', url: 'https://www.etsy.com'),
    (label: 'Walmart',  emoji: '🛒', url: 'https://www.walmart.com'),
    (label: 'Best Buy', emoji: '🔌', url: 'https://www.bestbuy.com'),
    // Generic entry — opens the in-app browser at about:blank so the
    // host can navigate anywhere via the address bar.
    (label: 'Browse the web', emoji: '🌐', url: 'about:blank'),
  ];

  // Theme-aware color getters — resolve light vs dark variant from the current Theme.
  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;

  @override
  void initState() {
    super.initState();
    final d = widget.eventData;
    _titleController = TextEditingController(text: (d['title'] as String?) ?? '');
    _locationController = TextEditingController(text: (d['location'] as String?) ?? '');
    _descController = TextEditingController(text: (d['description'] as String?) ?? '');
    _isPublic = (d['isPublic'] as bool?) ?? false;
    final ts = d['date'] as Timestamp?;
    if (ts != null) {
      _selectedDate = ts.toDate();
      final timeStr = d['time'] as String?;
      if (timeStr != null) {
        final parts = timeStr.split(':');
        if (parts.length == 2) _selectedTime = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
      }
    }
    final deadlineTs = d['rsvpDeadline'] as Timestamp?;
    if (deadlineTs != null) _rsvpDeadline = deadlineTs.toDate();
    final loadedCapacity = (d['capacity'] as num?)?.toInt();
    _capacityEnabled = loadedCapacity != null;
    if (loadedCapacity != null) _capacityController.text = '$loadedCapacity';
    _allowPlusOnes = (d['allowPlusOnes'] as bool?) ?? false;
    _maxPlusOnes   = (d['maxPlusOnes']   as num?)?.toInt();
    _allowWaitlist = (d['allowWaitlist'] as bool?) ?? true;

    // Hydrate the wishlist editor from whatever's on the event doc.
    // Preserves all existing fields (price/contributed/bought/quantity/
    // claimed) so saving doesn't clobber guest progress that's already
    // accumulated on the items.
    _listType = (d['listType'] as String?) ?? 'Wishlist';
    final raw = d['wishlist'] as List<dynamic>? ?? [];
    _wishlistItems
      ..clear()
      ..addAll(raw.map((e) => Map<String, dynamic>.from(e as Map)));

    _checkBusinessAccount();
  }

  @override
  void dispose() {
    _capacityController.dispose();
    _coHostEmailController.dispose();
    _titleController.dispose();
    _locationController.dispose();
    _descController.dispose();
    _newItemNameCtrl.dispose();
    _newItemPriceCtrl.dispose();
    _itemNameFocus.dispose();
    _newItemQtyCtrl.dispose();
    super.dispose();
  }

  // ── Retailer chip handler ──────────────────────────────────────
  /// Open the retailer's https URL with externalApplication mode so
  /// Android can hand off to the registered App Link handler (the
  /// retailer's app, when installed) instead of routing to the browser.
  /// Falls back to a Chrome Custom Tab if external launch fails (no
  /// browser, app missing, etc.). Custom URI schemes are no longer
  /// fired client-side — modern retailer apps respond to App Links.
  /// Opens [WishlistBrowserScreen] at [url], waits for the host to
  /// tap "Add to Wishlist" inside it, appends the extracted item to
  /// `_wishlistItems`, and refocuses the inline name field so the
  /// host can immediately tweak the title or fill in a price.
  ///
  /// Replaces the prior `LaunchMode.externalApplication` flow that
  /// kicked the host out to the retailer's native app or browser.
  /// Mirrors [CreateEventScreen._openShop].
  Future<void> _openShop(String url) async {
    if (!mounted) return;
    final result = await Navigator.of(context).push<WishlistBrowserResult>(
      MaterialPageRoute(
        builder: (_) => WishlistBrowserScreen(initialUrl: url),
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      _wishlistItems.add({
        'name': result.name,
        // Default price 0 — WebView extraction can't reliably parse a
        // price across retailers; the host edits it inline after we
        // refocus the name field below.
        'price': 0.0,
        'contributed': 0.0,
        'bought': false,
        if (result.imageUrl.isNotEmpty) 'imageUrl': result.imageUrl,
        if (result.url.isNotEmpty) 'url': result.url,
      });
      _newItemNameCtrl.text = result.name;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _itemNameFocus.requestFocus();
    });
  }

  // ── Wishlist add/remove ────────────────────────────────────────
  void _addWishlistItem() {
    final name = _newItemNameCtrl.text.trim();
    if (name.isEmpty) return;
    setState(() {
      if (_listType == 'Checklist') {
        _wishlistItems.add({
          'name': name,
          'quantity': _newItemQtyCtrl.text.trim(),
          'claimed': 0,
          'claims': <Map<String, dynamic>>[],
        });
      } else {
        final price = double.tryParse(_newItemPriceCtrl.text.trim()) ?? 0.0;
        _wishlistItems.add({
          'name': name,
          'price': price,
          'contributed': 0.0,
          'bought': false,
        });
      }
      _newItemNameCtrl.clear();
      _newItemPriceCtrl.clear();
      _newItemQtyCtrl.clear();
    });
    // Return focus to the name field so the host can type the next
    // item without re-tapping. Without this, the keyboard's caret
    // stays in whichever subfield (qty / price) the host last
    // touched, and they have to tap the name field every time —
    // friction that adds up when entering a long potluck list.
    _itemNameFocus.requestFocus();
  }

  void _removeWishlistItem(int index) {
    setState(() => _wishlistItems.removeAt(index));
  }

  Future<void> _checkBusinessAccount() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final snap = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final data = snap.data();
    if (data == null) return;
    final isBiz = data['accountType'] == 'business' && data['isTrialing'] != true;
    if (isBiz && mounted) {
      setState(() => _isBusiness = true);
      await _loadCoHosts();
    }
  }

  Future<void> _loadCoHosts() async {
    final rawCoHosts = widget.eventData['coHosts'];
    if (rawCoHosts == null) return;
    final uids = List<String>.from(rawCoHosts as List);
    if (uids.isEmpty) return;
    final snaps = await Future.wait(
      uids.map((uid) => FirebaseFirestore.instance.collection('users').doc(uid).get()),
    );
    final loaded = snaps
        .where((s) => s.exists)
        .map((s) => {'uid': s.id, 'email': (s.data()?['email'] as String?) ?? s.id})
        .toList();
    if (mounted) setState(() => _coHosts.addAll(loaded));
  }

  Future<void> _addCoHost() async {
    final email = _coHostEmailController.text.trim().toLowerCase();
    if (email.isEmpty) return;
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (_coHosts.any((c) => c['email'] == email)) {
      setState(() => _coHostError = 'Already added');
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
        setState(() => _coHostError = 'No account found');
        return;
      }
      final doc = snap.docs.first;
      if (doc.id == currentUid) {
        setState(() => _coHostError = "That's you");
        return;
      }
      setState(() {
        _coHosts.add({'uid': doc.id, 'email': email});
        _coHostEmailController.clear();
      });
    } catch (e) {
      setState(() => _coHostError = 'Error looking up user');
    } finally {
      if (mounted) setState(() => _lookingUpCoHost = false);
    }
  }

  Future<String?> _askEditScope() async {
    return showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [
          Icon(Icons.repeat, size: 22, color: _purple),
          SizedBox(width: 8),
          Text('Recurring event'),
        ]),
        content: const Text(
          'Apply these changes to just this occurrence, or to all future events in the series?',
          style: TextStyle(fontSize: 14, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: _muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'just_this'),
            child: const Text('Just this event'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'all_future'),
            child: const Text(
              'All future events',
              style: TextStyle(fontWeight: FontWeight.w700, color: _purple),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    if (_titleController.text.trim().isEmpty) return;

    final seriesId = widget.eventData['recurringSeriesId'] as String?;
    String scope = 'just_this';
    if (seriesId != null) {
      final choice = await _askEditScope();
      if (choice == null) return; // user cancelled
      scope = choice;
    }

    setState(() => _saving = true);

    final d = widget.eventData;
    final oldDate = (d['date'] as Timestamp?)?.toDate();
    final oldTimeStr = d['time'] as String?;
    final oldLocation = (d['location'] as String?) ?? '';

    final newTimeStr = _selectedTime != null ? '${_selectedTime!.hour}:${_selectedTime!.minute}' : null;
    final dateChanged = _selectedDate != null && oldDate != null && !_selectedDate!.isAtSameMomentAs(oldDate);
    final timeChanged = newTimeStr != oldTimeStr;
    final locationChanged = _locationController.text.trim() != oldLocation.trim();
    final needsNotification = dateChanged || timeChanged || locationChanged;

    try {
      await FirebaseFirestore.instance.collection('events').doc(widget.eventId).update({
        'title': _titleController.text.trim(),
        'description': _descController.text.trim(),
        'location': _locationController.text.trim(),
        'date': _selectedDate != null ? Timestamp.fromDate(_selectedDate!) : d['date'],
        'time': newTimeStr,
        'isPublic': _isPublic,
        'rsvpDeadline': _rsvpDeadline != null ? Timestamp.fromDate(_rsvpDeadline!) : null,
        'coHosts': _coHosts.map((c) => c['uid'] as String).toList(),
        // Capacity + waitlist are gated by _persistedCapacity so a 0 /
        // empty / non-numeric capacity field can't sneak into Firestore
        // — and waitlist stays off when there's no real cap (waitlist
        // without a cap has no trigger to fire on).
        'capacity': _persistedCapacity,
        'allowPlusOnes': _allowPlusOnes,
        'maxPlusOnes': _allowPlusOnes ? _maxPlusOnes : null,
        'allowWaitlist': _persistedCapacity != null && _allowWaitlist,
        // Persist any wishlist add/remove edits made via the host-side
        // editor below. We write the full list back wholesale so removals
        // take effect; existing item fields (price/contributed/bought/
        // claimed) are preserved when the host doesn't touch them.
        'wishlist': _wishlistItems,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Propagate changes to the series template so future auto-generated events inherit them
      if (scope == 'all_future' && seriesId != null) {
        await FirebaseFirestore.instance.collection('recurringEvents').doc(seriesId).update({
          'eventTemplate.title':       _titleController.text.trim(),
          'eventTemplate.description': _descController.text.trim(),
          'eventTemplate.location':    _locationController.text.trim(),
          'eventTemplate.time':        newTimeStr,
          'eventTemplate.isPublic':    _isPublic,
          'eventTemplate.coHosts':     _coHosts.map((c) => c['uid'] as String).toList(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      if (needsNotification) {
        final rsvpSnap = await FirebaseFirestore.instance
            .collection('events')
            .doc(widget.eventId)
            .collection('rsvps')
            .get();
        final guestUids = rsvpSnap.docs
            .where((doc) {
              final status = doc.data()['status'] as String?;
              return status == 'yes' || status == 'maybe';
            })
            .map((doc) => doc.id)
            .toList();
        if (guestUids.isNotEmpty) {
          await FirebaseFirestore.instance.collection('notificationTasks').add({
            'type': 'event_updated',
            'eventId': widget.eventId,
            'eventTitle': _titleController.text.trim(),
            'message': '${_titleController.text.trim()} has been updated — check the event for details.',
            'guestUids': guestUids,
            'status': 'pending',
            'createdAt': FieldValue.serverTimestamp(),
          });
        }
      }

      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _saving = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error saving: $e'), backgroundColor: Colors.redAccent));
    }
  }

  Widget _buildCapacitySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionCard(
          child: Row(children: [
            Icon(Icons.groups_outlined, size: 18, color: _capacityEnabled ? _purple : _muted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Capacity limit', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : AppColors.dark)),
                Text('Cap how many guests can RSVP Yes', style: TextStyle(fontSize: 11, color: _muted)),
              ]),
            ),
            Switch(
              value: _capacityEnabled,
              onChanged: (v) => setState(() {
                _capacityEnabled = v;
                if (!v) _capacityController.clear();
              }),
              activeTrackColor: _purple,
              activeThumbColor: Colors.white,
            ),
          ]),
        ),
        if (_capacityEnabled) ...[
          const SizedBox(height: 10),
          TextField(
            controller: _capacityController,
            keyboardType: TextInputType.number,
            style: TextStyle(color: _isDark ? Colors.white : AppColors.dark),
            decoration: InputDecoration(
              hintText: 'Max guests (e.g. 50)',
              hintStyle: TextStyle(color: _muted, fontSize: 13),
              prefixIcon: Icon(Icons.numbers, size: 18, color: _muted),
              filled: true,
              fillColor: _card,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _border)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _border)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.green, width: 1.5)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          _sectionCard(
            child: Row(children: [
              Icon(Icons.hourglass_bottom, size: 18, color: _allowWaitlist ? _purple : _muted),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Allow waitlist', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : AppColors.dark)),
                  Text('Notify the next person when a spot opens', style: TextStyle(fontSize: 11, color: _muted)),
                ]),
              ),
              Switch(
                value: _allowWaitlist,
                onChanged: (v) => setState(() => _allowWaitlist = v),
                activeTrackColor: _purple,
                activeThumbColor: Colors.white,
              ),
            ]),
          ),
        ],
        const SizedBox(height: 10),
        _sectionCard(
          child: Row(children: [
            Icon(Icons.person_add_alt, size: 18, color: _allowPlusOnes ? _purple : _muted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Allow plus ones', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : AppColors.dark)),
                Text('Let guests bring extra people', style: TextStyle(fontSize: 11, color: _muted)),
              ]),
            ),
            Switch(
              value: _allowPlusOnes,
              onChanged: (v) => setState(() => _allowPlusOnes = v),
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
                    onTap: () => setState(() => _maxPlusOnes = opt.$1),
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
                            color: _maxPlusOnes == opt.$1 ? _purple : (_isDark ? Colors.white : AppColors.dark),
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

  Widget _buildCoHostSection() {
    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Co-hosts', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : AppColors.dark)),
          const SizedBox(height: 2),
          Text('Co-hosts can manage RSVPs and photos', style: TextStyle(fontSize: 11, color: _muted)),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _coHostEmailController,
                  keyboardType: TextInputType.emailAddress,
                  style: TextStyle(fontSize: 14, color: _isDark ? Colors.white : AppColors.dark),
                  decoration: InputDecoration(
                    hintText: 'Guest email address',
                    hintStyle: TextStyle(color: _muted, fontSize: 13),
                    filled: true,
                    fillColor: _card,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: _border)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: _border)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.green, width: 1.5)),
                    errorText: _coHostError,
                    errorStyle: const TextStyle(fontSize: 11),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 40,
                child: ElevatedButton(
                  onPressed: _lookingUpCoHost ? null : _addCoHost,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  child: _lookingUpCoHost
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Add', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
          if (_coHosts.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _coHosts.map((c) => Chip(
                label: Text(c['email'] as String, style: const TextStyle(fontSize: 12, color: Colors.white)),
                backgroundColor: _purple,
                deleteIcon: const Icon(Icons.close, size: 14, color: Colors.white70),
                onDeleted: () => setState(() => _coHosts.removeWhere((x) => x['uid'] == c['uid'])),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 4),
              )).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? DateTime.now().add(const Duration(days: 7)),
      firstDate: DateTime.now(),
      lastDate: DateTime(2030),
    );
    if (picked != null) setState(() => _selectedDate = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime ?? const TimeOfDay(hour: 18, minute: 0),
    );
    if (picked != null) setState(() => _selectedTime = picked);
  }

  Future<void> _pickDeadline() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _rsvpDeadline ?? (_selectedDate != null ? _selectedDate!.subtract(const Duration(days: 1)) : DateTime.now().add(const Duration(days: 6))),
      firstDate: DateTime.now(),
      lastDate: _selectedDate ?? DateTime(2030),
      helpText: 'RSVP Deadline',
    );
    if (picked != null) setState(() => _rsvpDeadline = picked);
  }

  @override
  Widget build(BuildContext context) {
    final months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final dateLabel = _selectedDate != null ? '${months[_selectedDate!.month - 1]} ${_selectedDate!.day}, ${_selectedDate!.year}' : 'Pick a date';
    final timeLabel = _selectedTime != null ? _selectedTime!.format(context) : 'Pick a time';
    final deadlineLabel = _rsvpDeadline != null ? '${months[_rsvpDeadline!.month - 1]} ${_rsvpDeadline!.day}, ${_rsvpDeadline!.year}' : 'No deadline';

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _card,
        elevation: 0,
        leading: IconButton(icon: Icon(Icons.close, color: _isDark ? Colors.white : AppColors.dark), onPressed: () => Navigator.pop(context)),
        title: (() {
          final emoji = (widget.eventData['eventEmoji'] as String?) ?? '🎉';
          final typeName = (widget.eventData['eventType'] as String?) ?? '';
          final eventColor = eventTypes.firstWhere((t) => t.name == typeName, orElse: () => eventTypes.last).primary;
          return Row(children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(color: eventColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
              child: Center(child: Text(emoji, style: const TextStyle(fontSize: 20))),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(widget.eventData['title'] as String? ?? 'Edit Event', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark))),
          ]);
        })(),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.green))
                  : const Text('Save', style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w700, fontSize: 15)),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _editField('Event Title', _titleController, Icons.title),
          const SizedBox(height: 14),
          _editField('Location', _locationController, Icons.location_on_outlined),
          const SizedBox(height: 14),
          _editField('Description', _descController, Icons.notes, maxLines: 3),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: _dateTile('Date', dateLabel, Icons.calendar_today_outlined, _pickDate)),
            const SizedBox(width: 10),
            Expanded(child: _dateTile('Time', timeLabel, Icons.access_time_outlined, _pickTime)),
          ]),
          const SizedBox(height: 14),
          _sectionCard(
            child: Row(children: [
              Icon(Icons.how_to_vote_outlined, size: 18, color: _muted),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('RSVP Deadline', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : AppColors.dark)),
                  Text(deadlineLabel, style: TextStyle(fontSize: 12, color: _muted)),
                ]),
              ),
              Row(children: [
                if (_rsvpDeadline != null)
                  GestureDetector(
                    onTap: () => setState(() => _rsvpDeadline = null),
                    child: Icon(Icons.close, size: 16, color: _muted),
                  ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _pickDeadline,
                  child: const Icon(Icons.edit_outlined, size: 16, color: AppColors.green),
                ),
              ]),
            ]),
          ),
          const SizedBox(height: 14),
          if (_isBusiness) ...[
            _buildCoHostSection(),
            const SizedBox(height: 14),
          ],
          // Wishlist / Checklist editor — only relevant when the event
          // has a list. Hidden entirely for `'No List'` events, and
          // also hidden for `'Wishlist'` events while the Wishlist beta
          // gate is closed (`kWishlistEnabled = false`) so the host
          // can't add wishlist items via this screen during beta. The
          // existing wishlist array on the event doc is preserved
          // either way; the editor section just doesn't render.
          if (_listType == 'Checklist' ||
              (_listType == 'Wishlist' && kWishlistEnabled)) ...[
            _buildWishlistSection(),
            const SizedBox(height: 14),
          ],
          _buildCapacitySection(),
          const SizedBox(height: 14),
          _sectionCard(
            child: Row(children: [
              Icon(_isPublic ? Icons.public : Icons.lock_outline, size: 18, color: _isPublic ? AppColors.green : _muted),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Visibility', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : AppColors.dark)),
                  Text(_isPublic ? 'Public — visible in Explore' : 'Private — only visible via link', style: TextStyle(fontSize: 12, color: _muted)),
                ]),
              ),
              Switch(
                value: _isPublic,
                onChanged: (v) => setState(() => _isPublic = v),
                activeTrackColor: AppColors.green,
                activeThumbColor: Colors.white,
              ),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _editField(String label, TextEditingController ctrl, IconData icon, {int maxLines = 1}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _muted, letterSpacing: 0.5)),
      const SizedBox(height: 6),
      TextField(
        controller: ctrl,
        maxLines: maxLines,
        style: TextStyle(color: _isDark ? Colors.white : AppColors.dark),
        decoration: InputDecoration(
          prefixIcon: Icon(icon, size: 18, color: _muted),
          filled: true,
          fillColor: _card,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _border)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _border)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.green, width: 1.5)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      ),
    ],
  );

  Widget _dateTile(String label, String value, IconData icon, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: _sectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _muted, letterSpacing: 0.5)),
        const SizedBox(height: 4),
        Row(children: [
          Icon(icon, size: 15, color: AppColors.green),
          const SizedBox(width: 6),
          Flexible(child: Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : AppColors.dark))),
        ]),
      ]),
    ),
  );

  Widget _sectionCard({required Widget child}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14), border: Border.all(color: _border)),
    child: child,
  );

  // ── Wishlist section ──────────────────────────────────────────
  // Three blocks stacked: retailer chips at the top, the existing item
  // list with per-row remove buttons in the middle, and an inline Add
  // Item form at the bottom. Edits are kept in memory until the host
  // hits Save in the AppBar — the existing _save() flushes _wishlistItems
  // back to the events doc as the canonical wishlist array.
  Widget _buildWishlistSection() {
    final fg = _isDark ? Colors.white : AppColors.dark;
    final isChecklist = _listType == 'Checklist';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isChecklist ? 'CHECKLIST' : 'WISHLIST',
          style: TextStyle(
            fontFamily: 'Nunito', fontSize: 11, fontWeight: FontWeight.w800,
            letterSpacing: 1.4, color: _muted,
          ),
        ),
        const SizedBox(height: 8),
        // Retailer chips — tap opens the store's app or web fallback so
        // the host can browse, then come back and add an item below
        // (or use the system share sheet → "Add to QR Party" to push a
        // shared product into the event's wishlist subcollection).
        if (!isChecklist) ...[
          _sectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Browse stores',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final s in _shopChips) ...[
                      _shopChip(s),
                      const SizedBox(width: 8),
                    ],
                  ]),
                ),
                const SizedBox(height: 8),
                Text(
                  'Tap a store, find an item, then use the share menu → "Add to QR Party" — or add manually below.',
                  style: TextStyle(fontSize: 11, color: _muted, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
        // Existing items + per-row remove. Empty state shows a quiet
        // hint so the host knows where to add.
        if (_wishlistItems.isEmpty)
          _sectionCard(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                isChecklist
                    ? 'No checklist items yet — add one below.'
                    : 'No wishlist items yet — browse a store above or add manually.',
                style: TextStyle(fontSize: 12.5, color: _muted),
              ),
            ),
          )
        else
          Column(children: [
            for (int i = 0; i < _wishlistItems.length; i++) ...[
              _sectionCard(
                child: Row(children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (_wishlistItems[i]['name'] as String?) ?? '',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: fg),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isChecklist
                              ? ((_wishlistItems[i]['quantity'] as String?)?.isNotEmpty == true
                                  ? 'Qty: ${_wishlistItems[i]['quantity']}'
                                  : 'No quantity set')
                              : '\$${(((_wishlistItems[i]['price'] as num?) ?? 0).toDouble()).toStringAsFixed(2)}',
                          style: TextStyle(fontSize: 12, color: _muted),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                    tooltip: 'Remove',
                    onPressed: () => _removeWishlistItem(i),
                  ),
                ]),
              ),
              if (i < _wishlistItems.length - 1) const SizedBox(height: 8),
            ],
          ]),
        const SizedBox(height: 10),
        // Inline add form — name + (price OR quantity depending on
        // listType) + green plus button.
        _sectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Add ${isChecklist ? 'a checklist item' : 'a wishlist item'}',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _newItemNameCtrl,
                    focusNode: _itemNameFocus,
                    style: TextStyle(color: fg),
                    onSubmitted: (_) => _addWishlistItem(),
                    decoration: InputDecoration(
                      hintText: isChecklist ? 'Item to bring' : 'Item name',
                      hintStyle: TextStyle(color: _muted, fontSize: 13),
                      isDense: true,
                      filled: true,
                      fillColor: _bg,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: _border)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: _border)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.green, width: 1.5)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 92,
                  child: TextField(
                    controller: isChecklist ? _newItemQtyCtrl : _newItemPriceCtrl,
                    keyboardType: isChecklist
                        ? TextInputType.text
                        : const TextInputType.numberWithOptions(decimal: true),
                    style: TextStyle(color: fg),
                    onSubmitted: (_) => _addWishlistItem(),
                    decoration: InputDecoration(
                      hintText: isChecklist ? '2 bags' : r'$ 0.00',
                      hintStyle: TextStyle(color: _muted, fontSize: 13),
                      isDense: true,
                      filled: true,
                      fillColor: _bg,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: _border)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: _border)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.green, width: 1.5)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.add_circle, color: AppColors.green, size: 28),
                  tooltip: 'Add item',
                  onPressed: _addWishlistItem,
                ),
              ]),
            ],
          ),
        ),
      ],
    );
  }

  Widget _shopChip(({String label, String emoji, String url}) s) {
    return InkWell(
      onTap: () => _openShop(s.url),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _bg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(s.emoji, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 8),
          Text(
            s.label,
            style: TextStyle(
              fontFamily: 'Nunito', fontSize: 13, fontWeight: FontWeight.w800,
              color: _isDark ? Colors.white : AppColors.dark,
            ),
          ),
        ]),
      ),
    );
  }
}
