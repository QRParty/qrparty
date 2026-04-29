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

      // Fetch FCM tokens for all guests in parallel
      final guestUids = rsvpSnap.docs.map((d) => d.id).toList();
      final tokenDocs = await Future.wait(
        guestUids.map((uid) => FirebaseFirestore.instance.collection('users').doc(uid).get()),
      );
      final tokenByUid = <String, String>{};
      for (int i = 0; i < guestUids.length; i++) {
        final token = tokenDocs[i].data()?['fcmToken'] as String?;
        if (token != null) tokenByUid[guestUids[i]] = token;
      }

      final guests = rsvpSnap.docs.map((d) {
        final data = d.data();
        final uid = d.id;
        return <String, dynamic>{
          'uid': uid,
          'name': (data['name'] as String?) ?? 'Guest',
          'status': (data['status'] as String?) ?? 'Not Responded',
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
                                  Row(children: [
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
                                    if (hasChecklist) ...[
                                      const SizedBox(width: 6),
                                      Icon(Icons.shopping_bag_outlined, size: 11, color: _muted),
                                      const SizedBox(width: 2),
                                      Text('Brought items', style: TextStyle(fontSize: 11, color: _muted)),
                                    ] else if (hasContrib) ...[
                                      const SizedBox(width: 6),
                                      Icon(Icons.card_giftcard_outlined, size: 11, color: _muted),
                                      const SizedBox(width: 2),
                                      Text('Contributed', style: TextStyle(fontSize: 11, color: _muted)),
                                    ],
                                  ]),
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
      final token = widget.guest['fcmToken'] as String?;
      await NotificationService.sendNotification(
        token != null ? [token] : [],
        'Thank you from ${widget.eventTitle}',
        message,
        eventId: widget.eventId,
      );
      if (mounted) {
        Navigator.pop(context);
        widget.onSent();
      }
    } catch (_) {
      if (mounted) setState(() => _sending = false);
    }
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
