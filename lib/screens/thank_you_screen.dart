import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils.dart';

// ── Theme palette ──────────────────────────────────────────────
// Light + dark variants for the four surface colors; accents stay the same.
// Instance getters inside each State class pick the right variant from
// Theme.of(context) at build time, so the screen follows the ThemeNotifier.
const _bgDark      = Color(0xFF2D3047); // dark-mode scaffold
const _bgLight     = Color(0xFFF8F7FC);
const _cardDark    = Color(0xFF383B56);
const _cardLight   = Colors.white;
const _borderDark  = Color(0xFF4A4E6B);
const _borderLight = Color(0xFFE0E8E0);
const _mutedDark   = Color(0xFFA9A6B8);
const _mutedLight  = Color(0xFF8892A4);
const _purple      = Color(0xFF9C7FD4);
const _gold        = Color(0xFFC8922A);

// ─── SCREEN 8 — THANK YOU ────────────────────────────────────
class ThankYouScreen extends StatefulWidget {
  final String eventId;
  final String eventTitle;
  final String eventEmoji;
  const ThankYouScreen({super.key, required this.eventId, required this.eventTitle, required this.eventEmoji});
  @override
  State<ThankYouScreen> createState() => _ThankYouScreenState();
}

class _ThankYouScreenState extends State<ThankYouScreen> {
  bool _loading = true;
  bool _isBusiness = false;
  bool _isHeadquarters = false;
  List<Map<String, dynamic>> _guests = [];
  final Set<String> _sent = {};

  // Theme-aware color getters — resolve light vs dark variant from the current Theme.
  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;

  @override
  void initState() {
    super.initState();
    _loadGuests();
  }

  Future<void> _loadGuests() async {
    try {
      final hostUid = FirebaseAuth.instance.currentUser?.uid;

      // Start all fetches in parallel
      final fRsvp    = FirebaseFirestore.instance.collection('events').doc(widget.eventId).collection('rsvps').get();
      final fEvent   = FirebaseFirestore.instance.collection('events').doc(widget.eventId).get();
      final fContrib = FirebaseFirestore.instance.collection('events').doc(widget.eventId).collection('wishlist_contributions').get();
      Future<DocumentSnapshot<Map<String, dynamic>>>? fUser;
      if (hostUid != null) fUser = FirebaseFirestore.instance.collection('users').doc(hostUid).get();

      final rsvpSnap   = await fRsvp;
      final eventSnap  = await fEvent;
      final contribSnap = await fContrib;

      if (fUser != null) {
        final userSnap = await fUser;
        final d = userSnap.data() ?? {};
        // _isBusiness gates business-only thank-you affordances — both
        // tiers (Business + Headquarters) qualify. _isHeadquarters
        // separately differentiates the top tier so the AppBar badge
        // can read "HEADQUARTERS" instead of "PRO".
        final acct = d['accountType'];
        final activated = d['isTrialing'] != true;
        _isHeadquarters = acct == 'businessPlus' && activated;
        _isBusiness = activated && (acct == 'business' || acct == 'businessPlus');
      }

      // uid → checklist items claimed
      final checklistByUid = <String, List<String>>{};
      final rawWishlist = (eventSnap.data())?['wishlist'] as List<dynamic>? ?? [];
      for (final item in rawWishlist) {
        final m = item as Map<String, dynamic>;
        final itemName = (m['name'] as String?) ?? '';
        for (final claim in (m['claims'] as List<dynamic>? ?? [])) {
          final c = claim as Map<String, dynamic>;
          final uid = c['uid'] as String?;
          if (uid != null && itemName.isNotEmpty) {
            checklistByUid.putIfAbsent(uid, () => []).add(itemName);
          }
        }
      }

      // uid → wishlist contribution summary
      final contribByUid = <String, String>{};
      for (final doc in contribSnap.docs) {
        final items = doc.data()['items'] as Map<String, dynamic>? ?? {};
        final parts = items.entries
            .where((e) => (e.value as num? ?? 0) > 0)
            .map((e) => '\$${(e.value as num).toStringAsFixed(0)} toward ${e.key}')
            .toList();
        if (parts.isNotEmpty) contribByUid[doc.id] = parts.join(', ');
      }

      // Bucket the rsvp docs by channel: app guests have a doc id
      // == user uid (so the FCM token lives at users/{uid}); web
      // guests have an auto-id doc id and an `email` field on the
      // rsvp itself (no users/{uid} record). Looking up users/ for a
      // web guest's auto-id wastes a round-trip and always returns
      // empty, so partition first and only fetch tokens for app
      // guests.
      final appGuestUids = <String>[];
      for (final d in rsvpSnap.docs) {
        final src = d.data()['source'] as String?;
        if (src != 'web') appGuestUids.add(d.id);
      }
      final tokenDocs = await Future.wait(
        appGuestUids.map((uid) => FirebaseFirestore.instance.collection('users').doc(uid).get()),
      );
      final tokenByUid = <String, String>{};
      for (int i = 0; i < appGuestUids.length; i++) {
        final token = tokenDocs[i].data()?['fcmToken'] as String?;
        if (token != null) tokenByUid[appGuestUids[i]] = token;
      }

      final guests = rsvpSnap.docs.map((d) {
        final data = d.data();
        final uid = d.id;
        // Web guests carry source='web' + an email field stamped by
        // event.html at submit time. App guests have neither. The
        // `isWebGuest` flag drives the send-channel decision in
        // _ThankYouSheet._send (push for app, email for web) and
        // the badge on the guest tile.
        final isWebGuest = (data['source'] as String?) == 'web';
        return <String, dynamic>{
          'uid': uid,
          'name': (data['name'] as String?) ?? 'Guest',
          'status': (data['status'] as String?) ?? 'Not Responded',
          'email': (data['email'] as String?)?.trim(),
          'isWebGuest': isWebGuest,
          'checklist': checklistByUid[uid]?.join(', '),
          'contribution': contribByUid[uid],
          'fcmToken': tokenByUid[uid],
        };
      }).toList();

      guests.sort((a, b) {
        const order = {'Yes': 0, 'Maybe': 1, 'No': 2};
        return (order[a['status']] ?? 3).compareTo(order[b['status']] ?? 3);
      });

      if (mounted) setState(() { _guests = guests; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openThankYouSheet(Map<String, dynamic> guest) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ThankYouSheet(
        guest: guest,
        eventTitle: widget.eventTitle,
        eventId: widget.eventId,
        isBusiness: _isBusiness,
        onSent: () => setState(() => _sent.add(guest['uid'] as String)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final toThank = _guests.where((g) => g['status'] != 'No').toList();
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: _isDark ? Colors.white : AppColors.dark),
        title: Text('Thank You Notes', style: TextStyle(fontFamily: 'FredokaOne', fontSize: 22, color: _isDark ? Colors.white : AppColors.dark)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _purple))
          : Column(children: [
              // ── Event header ──────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: _card,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: _border),
                  ),
                  child: Row(children: [
                    Text(widget.eventEmoji, style: const TextStyle(fontSize: 32)),
                    const SizedBox(width: 14),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(widget.eventTitle,
                          style: TextStyle(fontFamily: 'FredokaOne', fontSize: 18, color: _isDark ? Colors.white : AppColors.dark)),
                      const SizedBox(height: 2),
                      Text(
                        toThank.isEmpty
                            ? 'No guests to thank yet'
                            : '${toThank.length} guest${toThank.length == 1 ? '' : 's'} to thank',
                        style: TextStyle(fontFamily: 'Nunito', fontSize: 13, color: _muted),
                      ),
                    ])),
                    if (_isBusiness)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _gold.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: _gold.withValues(alpha: 0.4)),
                        ),
                        child: Text(
                          _isHeadquarters ? 'HEADQUARTERS' : 'PRO',
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: _gold, letterSpacing: 0.5),
                        ),
                      ),
                  ]),
                ),
              ),
              // ── Guest list ────────────────────────────────────────
              Expanded(
                child: toThank.isEmpty
                    ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Text('💌', style: TextStyle(fontSize: 52)),
                        const SizedBox(height: 14),
                        Text('No guests yet', style: TextStyle(fontFamily: 'FredokaOne', fontSize: 24, color: _isDark ? Colors.white : AppColors.dark)),
                        const SizedBox(height: 6),
                        Text('Guests who RSVP\'d will appear here', style: TextStyle(fontFamily: 'Nunito', fontSize: 14, color: _muted)),
                      ]))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        itemCount: toThank.length,
                        itemBuilder: (context, index) {
                          final guest = toThank[index];
                          final uid = guest['uid'] as String;
                          final name = guest['name'] as String;
                          final firstName = name.split(' ').first;
                          final status = guest['status'] as String;
                          final hasChecklist = guest['checklist'] != null;
                          final hasContrib = guest['contribution'] != null;
                          final isWebGuest = guest['isWebGuest'] == true;
                          final guestEmail = (guest['email'] as String?)?.trim();
                          final hasFcmToken = guest['fcmToken'] != null;
                          final isSent = _sent.contains(uid);
                          final initials = name.split(' ').map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase();
                          const avatarColors = [_purple, _gold, AppColors.green, Color(0xFFE91E8C), Color(0xFF4FC3F7)];
                          final avatarColor = avatarColors[uid.hashCode.abs() % avatarColors.length];
                          final statusColor = status == 'Yes' ? AppColors.green : _gold;

                          return Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                            decoration: BoxDecoration(
                              color: _card,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: isSent ? _purple.withValues(alpha: 0.5) : _border),
                            ),
                            child: Row(children: [
                              Container(
                                width: 44, height: 44,
                                decoration: BoxDecoration(
                                  color: avatarColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Center(child: Text(initials, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: avatarColor))),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(name, style: TextStyle(fontFamily: 'Nunito', fontSize: 15, fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
                                  const SizedBox(height: 5),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 4,
                                    crossAxisAlignment: WrapCrossAlignment.center,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: statusColor.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(20),
                                        ),
                                        child: Text(
                                          status == 'Yes' ? 'Attended' : 'Maybe',
                                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: statusColor),
                                        ),
                                      ),
                                      // Channel pill — purple "App" when
                                      // the guest installed the app and
                                      // granted notifications, gold "Email"
                                      // when they RSVP'd via the web page,
                                      // muted "No channel" when there's
                                      // no way to reach them. Tells the
                                      // host at a glance which delivery
                                      // path Send Thanks will use.
                                      if (!isWebGuest && hasFcmToken)
                                        _channelPill(
                                          label: 'App',
                                          icon: Icons.smartphone,
                                          color: _purple,
                                        )
                                      else if (isWebGuest && guestEmail != null && guestEmail.isNotEmpty)
                                        _channelPill(
                                          label: 'Email',
                                          icon: Icons.mail_outline,
                                          color: _gold,
                                        )
                                      else
                                        _channelPill(
                                          label: 'No channel',
                                          icon: Icons.block,
                                          color: _muted,
                                        ),
                                      if (hasChecklist)
                                        Row(mainAxisSize: MainAxisSize.min, children: [
                                          Icon(Icons.shopping_bag_outlined, size: 11, color: _muted),
                                          const SizedBox(width: 2),
                                          Text('Brought items', style: TextStyle(fontSize: 11, color: _muted)),
                                        ])
                                      else if (hasContrib)
                                        Row(mainAxisSize: MainAxisSize.min, children: [
                                          Icon(Icons.card_giftcard_outlined, size: 11, color: _muted),
                                          const SizedBox(width: 2),
                                          Text('Contributed', style: TextStyle(fontSize: 11, color: _muted)),
                                        ]),
                                    ],
                                  ),
                                ]),
                              ),
                              const SizedBox(width: 10),
                              isSent
                                  ? Column(mainAxisSize: MainAxisSize.min, children: [
                                      const Icon(Icons.check_circle, size: 20, color: _gold),
                                      const SizedBox(height: 2),
                                      const Text('Sent', style: TextStyle(fontSize: 11, color: _gold, fontWeight: FontWeight.w600)),
                                    ])
                                  : ElevatedButton(
                                      onPressed: () => _openThankYouSheet(guest),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: _purple,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        minimumSize: Size.zero,
                                        elevation: 0,
                                      ),
                                      child: Text(
                                        _isBusiness ? 'Thank $firstName ✨' : 'Send Thanks',
                                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                                      ),
                                    ),
                            ]),
                          );
                        },
                      ),
              ),
            ]),
      bottomNavigationBar: debugLabel('Screen 8 — Host View'),
    );
  }

  /// Compact channel-indicator pill used on each guest tile. Tells
  /// the host which delivery path Send Thanks will use without
  /// requiring them to open the sheet first. Three states: App
  /// (purple), Email (gold), No channel (muted) — see the call site
  /// in the guest tile for the routing.
  Widget _channelPill({required String label, required IconData icon, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 10, color: color),
        const SizedBox(width: 3),
        Text(
          label,
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: color, letterSpacing: 0.2),
        ),
      ]),
    );
  }
}

// ─── THANK YOU SHEET ─────────────────────────────────────────
class _ThankYouSheet extends StatefulWidget {
  final Map<String, dynamic> guest;
  final String eventTitle;
  final String eventId;
  final bool isBusiness;
  final VoidCallback onSent;
  const _ThankYouSheet({
    required this.guest,
    required this.eventTitle,
    required this.eventId,
    required this.isBusiness,
    required this.onSent,
  });
  @override
  State<_ThankYouSheet> createState() => _ThankYouSheetState();
}

class _ThankYouSheetState extends State<_ThankYouSheet> {
  late List<Map<String, String>> _options;
  int _selectedOption = 0;
  late TextEditingController _ctrl;
  bool _sending = false;

  // Theme-aware color getters — resolve light vs dark variant from the current Theme.
  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;

  @override
  void initState() {
    super.initState();
    _buildOptions();
    _ctrl = TextEditingController(text: _options[0]['message']);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _buildOptions() {
    final firstName = (widget.guest['name'] as String).split(' ').first;
    final checklist = widget.guest['checklist'] as String?;
    final contribution = widget.guest['contribution'] as String?;
    final event = widget.eventTitle;

    if (widget.isBusiness) {
      _options = [
        {
          'label': 'Warm Welcome',
          'message': 'Hey $firstName! 🎉 Thanks so much for coming to $event — it honestly wouldn\'t have been the same without you. So glad you were there!',
        },
      ];
      if (checklist != null) {
        _options.add({
          'label': 'Brought Items',
          'message': '$firstName, you\'re an absolute legend for bringing $checklist to $event! It made such a difference — seriously, thank you! 🙌',
        });
      }
      if (contribution != null) {
        _options.add({
          'label': 'Gift',
          'message': 'Wow, $firstName — your $contribution at $event was so incredibly thoughtful. We\'re genuinely blown away and so grateful! 💝',
        });
      }
    } else {
      _options = [
        {
          'label': 'General',
          'message': 'Thank you so much for coming to $event! Having you there made it truly special. We\'re so grateful for your presence! 💛',
        },
      ];
    }
  }

  Future<void> _send() async {
    final message = _ctrl.text.trim();
    if (message.isEmpty) return;
    setState(() => _sending = true);
    try {
      final isWebGuest = widget.guest['isWebGuest'] == true;
      final email = (widget.guest['email'] as String?)?.trim();
      final token = widget.guest['fcmToken'] as String?;
      // Channel routing:
      //   • Web guest with an email → write to the `mail` collection
      //     so the Trigger Email extension delivers it. They have no
      //     FCM token (never installed the app), so push isn't an
      //     option.
      //   • App guest with a token → existing push path via
      //     NotificationService → notificationQueue → Cloud Function.
      //   • Anyone else (app guest who never granted notification
      //     permission, web guest whose email field was somehow
      //     missing) → bail with a snack so the host knows the send
      //     didn't actually land.
      var delivered = false;
      if (isWebGuest && email != null && email.isNotEmpty) {
        await _sendThankYouEmail(email: email, message: message);
        delivered = true;
      } else if (!isWebGuest && token != null) {
        await NotificationService.sendNotification(
          [token],
          'Thank you from ${widget.eventTitle}',
          message,
          eventId: widget.eventId,
        );
        delivered = true;
      }

      if (!delivered) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(isWebGuest
                ? 'No email on file for this guest — can\'t send a thank you.'
                : 'This guest hasn\'t enabled push notifications yet.'),
            backgroundColor: Colors.redAccent,
          ));
          setState(() => _sending = false);
        }
        return;
      }

      if (mounted) {
        Navigator.pop(context);
        widget.onSent();
      }
    } catch (_) {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Writes a thank-you email into the `mail` collection consumed by
  /// the Firebase Trigger Email extension. Mirrors the host-
  /// notification fallback in HostNotificationsScreen — same
  /// firestore.rules path requires `eventId` so the create rule can
  /// verify the host owns the event. Plaintext escaped into HTML so
  /// emoji + line breaks survive the SMTP hop.
  Future<void> _sendThankYouEmail({required String email, required String message}) async {
    final escapedMsg = message
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('\n', '<br>');
    await FirebaseFirestore.instance.collection('mail').add({
      'eventId': widget.eventId,
      'to': [email],
      'message': {
        'subject': 'Thank you from ${widget.eventTitle}',
        'text': message,
        'html':
            '<p>$escapedMsg</p>'
            '<p style="color:#888;font-size:12px;margin-top:24px">'
            'You\'re receiving this because you RSVP\'d to '
            '"${widget.eventTitle}" on QR Party. '
            '<a href="https://partywithqr.com/event/${widget.eventId}">View event</a>'
            '</p>',
      },
    });
  }

  @override
  Widget build(BuildContext context) {
    final firstName = (widget.guest['name'] as String).split(' ').first;
    final showOptions = widget.isBusiness && _options.length > 1;
    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).viewInsets.bottom + 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(color: _border, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 20),
          // Heading
          Text(
            widget.isBusiness ? 'Thank $firstName 💌' : 'Send a Thank You 💌',
            style: TextStyle(fontFamily: 'FredokaOne', fontSize: 24, color: _isDark ? Colors.white : AppColors.dark),
          ),
          const SizedBox(height: 2),
          Text(
            widget.isBusiness
                ? 'Personalized just for $firstName'
                : 'A warm note for everyone who came',
            style: TextStyle(fontFamily: 'Nunito', fontSize: 13, color: _muted),
          ),
          const SizedBox(height: 16),
          // Message options (business with multiple options only)
          if (showOptions) ...[
            ..._options.asMap().entries.map((entry) {
              final i = entry.key;
              final opt = entry.value;
              final isSelected = _selectedOption == i;
              return GestureDetector(
                onTap: () => setState(() {
                  _selectedOption = i;
                  _ctrl.text = opt['message']!;
                }),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isSelected ? _purple.withValues(alpha: 0.12) : _bg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: isSelected ? _purple : _border, width: isSelected ? 1.5 : 1),
                  ),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      width: 18, height: 18,
                      margin: const EdgeInsets.only(top: 1),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSelected ? _purple : Colors.transparent,
                        border: Border.all(color: isSelected ? _purple : _border, width: 1.5),
                      ),
                      child: isSelected ? const Icon(Icons.check, size: 11, color: Colors.white) : null,
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        opt['label']!,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: isSelected ? _purple : _muted, letterSpacing: 0.3),
                      ),
                      const SizedBox(height: 3),
                      Text(opt['message']!, style: TextStyle(fontFamily: 'Nunito', fontSize: 13, color: _isDark ? Colors.white : AppColors.dark, height: 1.4)),
                    ])),
                  ]),
                ),
              );
            }),
            const SizedBox(height: 4),
          ],
          // Edit label
          Text(
            widget.isBusiness ? 'Edit message' : 'Your message',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _muted),
          ),
          const SizedBox(height: 6),
          // Text field
          TextField(
            controller: _ctrl,
            maxLines: 3,
            style: TextStyle(fontSize: 14, color: _isDark ? Colors.white : AppColors.dark, height: 1.5),
            decoration: InputDecoration(
              filled: true,
              fillColor: _bg,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _purple, width: 1.5)),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
          const SizedBox(height: 16),
          // Send button
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: _sending ? null : _send,
              style: ElevatedButton.styleFrom(
                backgroundColor: _purple,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: _sending
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(
                      widget.isBusiness ? 'Send to $firstName' : 'Send Thank You',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
