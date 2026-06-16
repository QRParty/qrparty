import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../main.dart' show QRPartyAppState;
import '../utils.dart';
import 'guest_event_screen.dart';
import 'welcome_screen.dart';

/// Home shell for anonymous (signInAnonymously) deep-link guests.
/// Replaces [HomeRouter]'s personal home feed for these users so a
/// guest who taps "All Set" — or backs out of [GuestEventScreen] —
/// CANNOT land on the create-event FAB / Explore tab / past events
/// feed they have no business seeing.
///
/// Routing decision is made from a live `collectionGroup('rsvps')`
/// query scoped to `uid == currentUser.uid`:
///   • exactly 1 distinct event → render [GuestEventScreen] directly
///     for that event (same screen + same Firestore fetch the deep-
///     link path uses, so no duplicated load logic).
///   • >1 distinct events       → render a minimal picker list.
///   • 0 events                 → render the Enter Code / Sign Up
///     fallback so a guest who somehow lands here without an RSVP
///     still has a way forward.
///
/// **Signed-in users never reach this screen.** [HomeRouter] gates
/// entry on `user.isAnonymous == true`. Existing personal /
/// business / headquarters routing for real accounts is unchanged.
class AnonymousGuestHome extends StatelessWidget {
  const AnonymousGuestHome({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    // Defensive: HomeRouter shouldn't route here for a null user, but
    // a stream tear-down race could still land us here for one frame.
    if (user == null) {
      return const _ShellScaffold(
        child: Center(child: CircularProgressIndicator(color: AppColors.green)),
      );
    }
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collectionGroup('rsvps')
          .where('uid', isEqualTo: user.uid)
          .snapshots(),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const _ShellScaffold(
            child: Center(child: CircularProgressIndicator(color: AppColors.green)),
          );
        }
        if (snap.hasError) {
          // Surface the failure as the empty-state copy so the guest
          // still gets the Enter Code / Sign Up affordances.
          debugPrint('[AnonymousGuestHome] rsvps stream error: ${snap.error}');
          return const _ShellScaffold(child: _EmptyOrNoRsvpsBody());
        }
        final docs = snap.data?.docs ?? const <QueryDocumentSnapshot>[];
        // The collectionGroup query path is /events/{eventId}/rsvps/{rsvpId}.
        // doc.reference.parent.parent.id == eventId. De-dup so an
        // anon user with multiple status-change docs on the same
        // event (web path auto-IDs each submit) still renders the
        // event once.
        final eventIds = <String>{};
        for (final d in docs) {
          final eid = d.reference.parent.parent?.id;
          if (eid != null && eid.isNotEmpty) eventIds.add(eid);
        }
        if (eventIds.isEmpty) {
          return const _ShellScaffold(child: _EmptyOrNoRsvpsBody());
        }
        if (eventIds.length == 1) {
          // Direct render — no Scaffold wrapper, GuestEventScreen
          // owns its own. eventData is null so the screen runs its
          // lazy Firestore fetch (same path the deep-link handler
          // uses when only an eventId is known).
          return GuestEventScreen(eventId: eventIds.first);
        }
        return _ShellScaffold(child: _MultiEventList(eventIds: eventIds.toList()));
      },
    );
  }
}

/// Outer scaffold for the empty / multi-event states. GuestEventScreen
/// brings its own Scaffold, so this only wraps the non-direct-render
/// branches. Kept private to this file — there's no second consumer.
class _ShellScaffold extends StatelessWidget {
  final Widget child;
  const _ShellScaffold({required this.child});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF2D3047) : const Color(0xFFF8F7FC);
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(child: child),
    );
  }
}

/// Empty-state body shown when the anon guest has no RSVPs on file
/// yet (rare — usually they arrive via deep link and RSVP almost
/// immediately, but a guest who taps the banner OPEN and quits before
/// confirming a status could land here).
class _EmptyOrNoRsvpsBody extends StatelessWidget {
  const _EmptyOrNoRsvpsBody();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : AppColors.dark;
    final muted = isDark ? const Color(0xFFA9A6B8) : const Color(0xFF8892A4);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(),
          Center(
            child: Container(
              width: 72, height: 72,
              decoration: BoxDecoration(
                color: AppColors.purple.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Center(child: Text('🎉', style: TextStyle(fontSize: 34))),
            ),
          ),
          const SizedBox(height: 22),
          Text(
            'Welcome to QR Party',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'FredokaOne', fontSize: 26, color: fg, letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Got an invite code? Open the event below. Want to host your own? Create a free account.",
            textAlign: TextAlign.center,
            style: TextStyle(fontFamily: 'Nunito', fontSize: 14, height: 1.5, color: muted),
          ),
          const SizedBox(height: 32),
          // Enter Code — reuses the public openEventByCode on
          // QRPartyAppState so the prompt + resolver matches the
          // home-feed entry point exactly. Resolver pushes
          // GuestEventScreen via the root navigator; on this screen
          // a successful open replaces what's visible underneath.
          SizedBox(
            height: 52,
            child: ElevatedButton.icon(
              onPressed: () => _showEnterCodeDialog(context),
              icon: const Icon(Icons.dialpad, size: 18),
              label: const Text('Enter event code',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.purple,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Sign Up — routes through WelcomeScreen so the user
          // can pick Get Started OR Log in. The linkWithCredential
          // path in welcome_screen.dart's _signUp/_login carries
          // their anon UID + RSVP history forward, so anything they
          // did as a guest survives the upgrade.
          SizedBox(
            height: 52,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const WelcomeScreen()),
              ),
              icon: const Icon(Icons.person_outline, size: 18, color: AppColors.green),
              label: const Text('Create a free account',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.green)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.green, width: 1.5),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          const Spacer(flex: 2),
          Text(
            '© 2026 QR Party · www.partywithqr.com',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: muted),
          ),
        ],
      ),
    );
  }

  Future<void> _showEnterCodeDialog(BuildContext context) async {
    final controller = TextEditingController();
    String? error;
    final code = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (innerCtx, setLocal) {
          void submit() {
            final trimmed = controller.text.trim();
            if (trimmed.isEmpty) {
              setLocal(() => error = 'Please enter a code');
              return;
            }
            Navigator.of(dialogCtx).pop(trimmed);
          }
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text('Enter event code'),
            content: TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => submit(),
              decoration: InputDecoration(
                hintText: 'e.g. EUZTA2',
                errorText: error,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: submit,
                child: const Text(
                  'Open Event',
                  style: TextStyle(color: AppColors.purple, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (code == null || code.isEmpty || !context.mounted) return;
    final state = context.findAncestorStateOfType<QRPartyAppState>();
    await state?.openEventByCode(code);
  }
}

/// Picker list shown when the anon guest has RSVPs on more than one
/// event. Each row pulls its own event doc (title + emoji) via a
/// FutureBuilder — events read is permitted for any signed-in user,
/// including anon, so these gets succeed.
class _MultiEventList extends StatelessWidget {
  final List<String> eventIds;
  const _MultiEventList({required this.eventIds});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : AppColors.dark;
    final muted = isDark ? const Color(0xFFA9A6B8) : const Color(0xFF8892A4);
    final card = isDark ? const Color(0xFF383B56) : Colors.white;
    final border = isDark ? const Color(0xFF4A4E6B) : const Color(0xFFE0E8E0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Your events',
            style: TextStyle(
              fontFamily: 'FredokaOne', fontSize: 26, color: fg, letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Tap one to see the details.',
            style: TextStyle(fontFamily: 'Nunito', fontSize: 13, color: muted),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView.separated(
              itemCount: eventIds.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (ctx, i) => _MultiEventRow(
                eventId: eventIds[i],
                cardColor: card,
                borderColor: border,
                fg: fg,
                muted: muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MultiEventRow extends StatelessWidget {
  final String eventId;
  final Color cardColor;
  final Color borderColor;
  final Color fg;
  final Color muted;
  const _MultiEventRow({
    required this.eventId,
    required this.cardColor,
    required this.borderColor,
    required this.fg,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance.collection('events').doc(eventId).get(),
      builder: (ctx, snap) {
        final data = snap.data?.data() as Map<String, dynamic>?;
        final title = (data?['title'] as String?) ?? 'Event';
        final emoji = (data?['eventEmoji'] as String?) ?? '🎉';
        final dateStr = _formatShortDate(data?['date']);
        return Material(
          color: cardColor,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: data == null
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => GuestEventScreen(
                          eventId: eventId,
                          eventData: data,
                        ),
                      ),
                    ),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: borderColor),
              ),
              child: Row(children: [
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.purple.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(child: Text(emoji, style: const TextStyle(fontSize: 22))),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: fg),
                      ),
                      if (dateStr.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(dateStr, style: TextStyle(fontSize: 12, color: muted)),
                      ],
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, size: 20, color: muted),
              ]),
            ),
          ),
        );
      },
    );
  }

  String _formatShortDate(dynamic raw) {
    if (raw is! Timestamp) return '';
    final d = raw.toDate();
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}
