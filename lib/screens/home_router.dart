import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils.dart';
import 'home_feed_screen.dart';
import 'business_home_feed_screen.dart';

/// Routes a signed-in user to the right home feed based on their Firestore
/// profile (personal vs business vs business-plus, with promo-account expiry
/// handling), and overlays the first-login welcome card on top.
///
/// Public so post-signup / post-login flows in welcome_screen.dart can navigate
/// to it explicitly via `pushAndRemoveUntil` instead of relying on the auth
/// state stream rebuilding `MaterialApp.home` at the right moment.
class HomeRouter extends StatelessWidget {
  const HomeRouter({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      // Defensive — shouldn't happen because callers gate navigation on a
      // non-null currentUser, but render a loading spinner instead of
      // null-panicking if it ever does.
      return const Scaffold(
        backgroundColor: Color(0xFFF8F7FC),
        body: Center(child: CircularProgressIndicator(color: AppColors.green)),
      );
    }
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('users').doc(user.uid).snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: Color(0xFFF8F7FC),
            body: Center(child: CircularProgressIndicator(color: AppColors.green)),
          );
        }
        final data = snap.data?.data() as Map<String, dynamic>? ?? {};
        final accountType = data['accountType'] as String?;
        final isTrialing  = data['isTrialing'] == true;

        // Auto-downgrade expired promo accounts (businessExpiry in the past) to personal.
        final businessExpiry = (data['businessExpiry'] as Timestamp?)?.toDate();
        final expiredPromo = businessExpiry != null
            && businessExpiry.isBefore(DateTime.now())
            && (accountType == 'business' || accountType == 'businessPlus');
        if (expiredPromo) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            FirebaseFirestore.instance.collection('users').doc(user.uid).update({
              'accountType': 'personal',
              'businessExpiry': FieldValue.delete(),
            });
          });
          return const _WelcomeGate(child: HomeFeedScreen());
        }

        final isBusinessLike = (accountType == 'business' || accountType == 'businessPlus') && !isTrialing;
        // Business users can opt into the personal view via Settings → Switch Account.
        // Pref is stored locally via ViewPreferenceNotifier (SharedPreferences key 'preferBusinessView').
        return ValueListenableBuilder<bool>(
          valueListenable: ViewPreferenceNotifier.instance,
          builder: (context, preferBusiness, _) {
            final showBusiness = isBusinessLike && preferBusiness;
            final home = showBusiness ? const BusinessHomeFeedScreen() : const HomeFeedScreen();
            return _WelcomeGate(child: home);
          },
        );
      },
    );
  }
}

// ─── WELCOME OVERLAY (first login only) ──────────────────────
class _WelcomeGate extends StatefulWidget {
  final Widget child;
  const _WelcomeGate({required this.child});
  @override
  State<_WelcomeGate> createState() => _WelcomeGateState();
}

class _WelcomeGateState extends State<_WelcomeGate> {
  // The welcome popup is a once-per-device modal. `_checked` flips true after
  // the SharedPreferences read returns; `_show` is the runtime decision. If
  // the prefs read fails we default to "already seen" so we never pester
  // users on subsequent launches because of an environmental glitch.
  bool _checked = false;
  bool _show = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    var seen = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      seen = prefs.getBool('hasSeenWelcome') ?? false;
    } catch (e) {
      debugPrint('[WelcomeGate] prefs read failed; treating as seen: $e');
    }
    if (!mounted) return;
    setState(() { _checked = true; _show = !seen; });
  }

  Future<void> _dismiss() async {
    // Persist FIRST so the bool is on disk even if the widget unmounts
    // (e.g. user backgrounds the app) between the await and the setState.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('hasSeenWelcome', true);
    } catch (e) {
      debugPrint('[WelcomeGate] prefs write failed; popup may reappear: $e');
    }
    if (!mounted) return;
    setState(() => _show = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked || !_show) return widget.child;
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.7),
            child: Center(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 28),
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                decoration: BoxDecoration(
                  color: const Color(0xFF383B56),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF4A4E6B)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Welcome to QR Party! 🎉',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Fredoka One',
                        fontSize: 24,
                        color: Color(0xFFC8922A),
                      ),
                    ),
                    const SizedBox(height: 22),
                    _welcomeRow('Tap + to create your first event'),
                    const SizedBox(height: 12),
                    _welcomeRow('Tap the QR code icon to share it'),
                    const SizedBox(height: 12),
                    _welcomeRow('Guests scan and RSVP instantly'),
                    const SizedBox(height: 12),
                    _welcomeRow('Watch it all happen in real time'),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _dismiss,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF9C7FD4),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        child: const Text(
                          "Got it! Let's Party 🎉",
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _welcomeRow(String label) => Row(
        children: [
          const Text('✦', style: TextStyle(fontSize: 18, color: Color(0xFFC8922A))),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 15)),
          ),
        ],
      );
}
