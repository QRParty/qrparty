import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils.dart';
import 'home_feed_screen.dart';
import 'business_home_feed_screen.dart';
import 'headquarters_home_feed_screen.dart';

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
          return _WelcomeGate(child: HomeFeedScreen(key: ValueKey('home-${user.uid}')));
        }

        final isBusinessLike = (accountType == 'business' || accountType == 'businessPlus') && !isTrialing;
        final isHeadquarters = accountType == 'businessPlus' && !isTrialing;
        // Business users can opt into the personal view via Settings → Switch Account.
        // Pref is stored locally via ViewPreferenceNotifier (SharedPreferences key 'preferBusinessView').
        return ValueListenableBuilder<bool>(
          valueListenable: ViewPreferenceNotifier.instance,
          builder: (context, preferBusiness, _) {
            final showBusiness = isBusinessLike && preferBusiness;
            // Key every home variant by uid so a sign-out → sign-in to a
            // different account forces a fresh State (and a fresh
            // _eventsSub scoped to the new user). Without this, Flutter's
            // element-tree reconciliation matches the same widget type +
            // null key in the same slot and REUSES the previous user's
            // _HomeFeedScreenState — leaking the prior user's drafts +
            // events into the new user's feed because initState (and
            // therefore _subscribeToEvents) never runs again.
            final homeKey = ValueKey('home-${user.uid}');
            final Widget home;
            if (showBusiness && isHeadquarters) {
              home = HeadquartersHomeFeedScreen(key: homeKey);
            } else if (showBusiness) {
              home = BusinessHomeFeedScreen(key: homeKey);
            } else {
              home = HomeFeedScreen(key: homeKey);
            }
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
            color: Colors.black.withValues(alpha: 0.55),
            child: Center(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 28),
                padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.green.withValues(alpha: 0.18),
                      blurRadius: 40,
                      offset: const Offset(0, 16),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Brand mark — wordmark + scannable QR. Mirrors the
                    // welcome_screen.dart logo card so the popup feels like
                    // a continuation of the sign-in experience.
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('QR',    style: TextStyle(fontSize: 36, fontWeight: FontWeight.w900, color: AppColors.dark, height: 1)),
                            Text('Party', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w300, color: AppColors.purple, height: 1)),
                          ],
                        ),
                        const SizedBox(width: 10),
                        Container(
                          width: 56, height: 56,
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(color: AppColors.dark, borderRadius: BorderRadius.circular(7)),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: QrImageView(
                              data: 'https://partywithqr.com',
                              version: QrVersions.auto,
                              backgroundColor: Colors.white,
                              padding: const EdgeInsets.all(2),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    const Text(
                      'One QR code.\nEvery RSVP handled.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        // DM Sans gives the headline a slightly geometric,
                        // editorial feel that pairs with the brand QR mark.
                        fontFamily: 'DM Sans',
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: AppColors.dark,
                        height: 1.25,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Create an event, share the code, watch RSVPs roll in.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        // Inter for body — most readable modern UI sans, sets
                        // the baseline tone for the rest of the popup.
                        fontFamily: 'Inter',
                        fontSize: 14,
                        color: AppColors.muted,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: _dismiss,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.green,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          elevation: 0,
                          textStyle: const TextStyle(fontFamily: 'Inter'),
                        ),
                        child: const Text(
                          'Get Started',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 0.2),
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
}
