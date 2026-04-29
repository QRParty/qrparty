import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils.dart';

// ── Theme palette ──────────────────────────────────────────────
const _bgDark      = Color(0xFF2D3047); // dark-mode scaffold
const _bgLight     = Color(0xFFF8F7FC);
const _cardDark    = Color(0xFF383B56);
const _cardLight   = Colors.white;
const _borderDark  = Color(0xFF4A4E6B);
const _borderLight = Color(0xFFE0E8E0);
const _mutedDark   = Color(0xFFA9A6B8);
const _mutedLight  = Color(0xFF8892A4);

// ─── SCREEN 7 — HOST NOTIFICATIONS ───────────────────────────
class HostNotificationsScreen extends StatefulWidget {
  const HostNotificationsScreen({super.key});
  @override
  State<HostNotificationsScreen> createState() => _HostNotificationsScreenState();
}

class _HostNotificationsScreenState extends State<HostNotificationsScreen> {
  final TextEditingController _messageController = TextEditingController();

  List<Map<String, dynamic>> _events = [];
  String? _selectedEventId;
  String? _selectedEventTitle;
  String? _selectedEventEmoji;
  bool _loadingEvents = true;
  bool _sending = false;
  final List<Map<String, dynamic>> _sentHistory = [];

  final List<String> templates = [
    "🚗 Parking is on the street!",
    "⏰ Starting 30 mins late, see you soon!",
    "👙 Don't forget to bring a swimsuit!",
    "🎉 Can't wait to see you all!",
    "🍕 Food is ready, come hungry!",
    "📸 Photos are up on the wall!",
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
    _loadEvents();
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _loadEvents() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) { setState(() => _loadingEvents = false); return; }
    try {
      final snap = await FirebaseFirestore.instance
          .collection('events')
          .where('hostId', isEqualTo: user.uid)
          .orderBy('date')
          .get();
      final events = snap.docs
          .map((d) => {'id': d.id, 'title': (d.data()['title'] as String?) ?? 'Untitled', 'emoji': (d.data()['eventEmoji'] as String?) ?? '🎉'})
          .toList();
      setState(() {
        _events = events;
        if (events.isNotEmpty) {
          _selectedEventId = events.first['id'];
          _selectedEventTitle = events.first['title'];
          _selectedEventEmoji = events.first['emoji'];
        }
        _loadingEvents = false;
      });
    } catch (_) {
      setState(() => _loadingEvents = false);
    }
  }

  Future<void> _sendNotification() async {
    final msg = _messageController.text.trim();
    final eventId = _selectedEventId;
    if (msg.isEmpty || eventId == null) return;
    setState(() => _sending = true);
    try {
      // Fetch all Yes/Maybe RSVPs for the selected event
      final rsvpSnap = await FirebaseFirestore.instance
          .collection('events')
          .doc(eventId)
          .collection('rsvps')
          .where('status', whereIn: ['Yes', 'Maybe'])
          .get();

      // Walk each RSVP doc instead of throwing away everything except
      // the doc id. Web RSVPs (source: 'web') are doc-id'd by email
      // and HAVE an `email` field but NO matching `users/{uid}` doc —
      // they'd never get an fcmToken lookup. App RSVPs are doc-id'd
      // by the user uid and we look up `fcmToken` from the user doc.
      // Anyone we can push to gets a push; anyone we can't push to
      // but who has an email gets a Trigger Email fallback so guests
      // who RSVP'd from a browser still hear the announcement.
      final tokens = <String>[];
      final emails = <String>[];
      // Bucket the rsvp docs by lookup mode in one pass.
      final appUids = <String>[];
      final webEmails = <String>[];
      for (final d in rsvpSnap.docs) {
        final data = d.data();
        final source = data['source'] as String?;
        final emailField = (data['email'] as String?)?.trim();
        if (source == 'web') {
          if (emailField != null && emailField.isNotEmpty) {
            webEmails.add(emailField);
          }
        } else {
          // App RSVP — doc id is the user uid.
          appUids.add(d.id);
        }
      }

      // Fetch user docs for app RSVPs. fcmToken → push list; no
      // token but email present on the user doc → email fallback.
      if (appUids.isNotEmpty) {
        final userDocs = await Future.wait(
          appUids.map((uid) =>
              FirebaseFirestore.instance.collection('users').doc(uid).get()),
        );
        for (final doc in userDocs) {
          final data = doc.data() ?? const {};
          final token = data['fcmToken'] as String?;
          if (token != null && token.isNotEmpty) {
            tokens.add(token);
            continue;
          }
          final email = (data['email'] as String?)?.trim();
          if (email != null && email.isNotEmpty) emails.add(email);
        }
      }
      // All web RSVPs are emailed — they can't receive a push.
      emails.addAll(webEmails);

      await NotificationService.sendNotification(
        tokens,
        _selectedEventTitle ?? 'Event Update',
        msg,
        eventId: eventId,
      );

      // Email fallback via the Firebase Trigger Email extension. Each
      // mail doc carries `eventId` so the firestore.rules host check
      // can authorize the create. The extension watches the `mail`
      // collection and ignores extra fields, so the eventId tag is a
      // safe annotation. Failures here are best-effort: one bad email
      // shouldn't block the whole batch; we just log and continue.
      final eventTitle = _selectedEventTitle ?? 'Event Update';
      final dedupedEmails = emails.toSet().toList();
      var emailedCount = 0;
      if (dedupedEmails.isNotEmpty) {
        final mail = FirebaseFirestore.instance.collection('mail');
        final escapedMsg = msg
            .replaceAll('&', '&amp;')
            .replaceAll('<', '&lt;')
            .replaceAll('>', '&gt;')
            .replaceAll('\n', '<br>');
        for (final addr in dedupedEmails) {
          try {
            await mail.add({
              'eventId': eventId,
              'to': [addr],
              'message': {
                'subject': 'Update from $eventTitle',
                'text': msg,
                'html':
                    '<p>$escapedMsg</p>'
                    '<p style="color:#888;font-size:12px;margin-top:24px">'
                    'You\'re receiving this because you RSVP\'d to '
                    '"$eventTitle" on QR Party. '
                    '<a href="https://partywithqr.com/event/$eventId">View event</a>'
                    '</p>',
              },
            });
            emailedCount++;
          } catch (e) {
            debugPrint('[HostNotifications] mail write failed for $addr: $e');
          }
        }
      }

      final pushedCount = tokens.length;
      final reachedCount = pushedCount + emailedCount;
      setState(() {
        _sentHistory.insert(0, {
          'event': _selectedEventTitle,
          'message': msg,
          'time': 'Just now',
          'guests': reachedCount,
        });
        _messageController.clear();
      });

      if (mounted) {
        // Show a combined count + a small breakdown so the host knows
        // some recipients were reached via email rather than push.
        final breakdown = emailedCount > 0
            ? ' ($pushedCount push, $emailedCount email)'
            : '';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            'Notification queued for $reachedCount guest${reachedCount == 1 ? '' : 's'}!$breakdown',
          ),
          backgroundColor: AppColors.green,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to send: $e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fg = _isDark ? Colors.white : AppColors.dark;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _card,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: _selectedEventId != null && _selectedEventTitle != null
            ? Row(children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(color: AppColors.green.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                  child: Center(child: Text(_selectedEventEmoji ?? '🎉', style: const TextStyle(fontSize: 20))),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(_selectedEventTitle!, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: fg))),
              ])
            : Text('Notify Guests', style: TextStyle(fontWeight: FontWeight.w700, color: fg)),
      ),
      body: Column(
        children: [
          // Compose area
          Container(
            color: _card,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Event selector
                Text('Send to guests of', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _muted)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  decoration: BoxDecoration(color: _bg, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.black.withValues(alpha: 0.08))),
                  child: _loadingEvents
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.green))),
                        )
                      : _events.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Text('No events found', style: TextStyle(color: _muted, fontSize: 14)),
                            )
                          : DropdownButton<String>(
                              value: _selectedEventId,
                              isExpanded: true,
                              underline: const SizedBox(),
                              icon: Icon(Icons.keyboard_arrow_down, color: _muted),
                              items: _events.map((e) => DropdownMenuItem(
                                value: e['id'] as String,
                                child: Text(e['title'] as String, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: fg)),
                              )).toList(),
                              onChanged: (v) {
                                final evt = _events.firstWhere((e) => e['id'] == v);
                                setState(() {
                                  _selectedEventId = v;
                                  _selectedEventTitle = evt['title'] as String;
                                  _selectedEventEmoji = evt['emoji'] as String? ?? '🎉';
                                });
                              },
                            ),
                ),
                const SizedBox(height: 16),
                // Message input
                Text('Your message', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _muted)),
                const SizedBox(height: 8),
                TextField(
                  controller: _messageController,
                  maxLines: 3,
                  style: TextStyle(color: fg),
                  decoration: InputDecoration(
                    hintText: 'Type a message to all your guests...',
                    hintStyle: TextStyle(color: _muted),
                    filled: true,
                    fillColor: _bg,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.green, width: 1.5)),
                    contentPadding: const EdgeInsets.all(14),
                  ),
                ),
                const SizedBox(height: 12),
                // Quick templates
                Text('Quick templates', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _muted)),
                const SizedBox(height: 8),
                SizedBox(
                  height: 36,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: templates.length,
                    itemBuilder: (context, index) => GestureDetector(
                      onTap: () => setState(() => _messageController.text = templates[index]),
                      child: Container(
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppColors.purplePale,
                          borderRadius: BorderRadius.circular(100),
                          border: Border.all(color: AppColors.purple.withOpacity(0.2)),
                        ),
                        child: Text(templates[index], style: const TextStyle(fontSize: 12, color: AppColors.purple, fontWeight: FontWeight.w500)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Send button
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton.icon(
                    onPressed: _sendNotification,
                    icon: const Icon(Icons.send_rounded, size: 18),
                    label: const Text('Send to All Guests', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.green,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Sent history
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(children: [
              Text('Previously sent', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: fg)),
            ]),
          ),
          Expanded(
            child: _sentHistory.isEmpty
                ? Center(child: Text('No notifications sent yet', style: TextStyle(color: _muted)))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: _sentHistory.length,
                    itemBuilder: (context, index) {
                      final n = _sentHistory[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.black.withOpacity(0.05))),
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(color: AppColors.purplePale, borderRadius: BorderRadius.circular(100)),
                                  child: Text(n['event'] as String, style: const TextStyle(fontSize: 11, color: AppColors.purple, fontWeight: FontWeight.w600)),
                                ),
                                const Spacer(),
                                Text(n['time'] as String, style: TextStyle(fontSize: 11, color: _muted)),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(n['message'] as String, style: TextStyle(fontSize: 14, color: fg, fontWeight: FontWeight.w500)),
                            const SizedBox(height: 6),
                            Row(children: [
                              Icon(Icons.people_outline, size: 13, color: _muted),
                              const SizedBox(width: 4),
                              Text('Sent to ${n['guests']} guests', style: TextStyle(fontSize: 12, color: _muted)),
                            ]),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: debugLabel('Screen 7 — Host View'),
    );
  }
}
