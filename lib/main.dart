import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:app_links/app_links.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'utils.dart';
import 'screens/welcome_screen.dart';
import 'screens/guest_event_screen.dart';
import 'screens/home_router.dart';
import 'services/wishlist_share_handler.dart';
import 'widgets/share_to_wishlist_sheet.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: "AIzaSyDI8j_7H9VoIFMCwGdJzEij406ap_tRlcA",
          authDomain: "qrparty-6e648.firebaseapp.com",
          projectId: "qrparty-6e648",
          storageBucket: "qrparty-6e648.firebasestorage.app",
          messagingSenderId: "478022847809",
          appId: "1:478022847809:web:a75dfa45ddb28d043565c0",
        ),
      );
    }
  } catch (e) {
    print('Firebase init error: $e');
  }
  try {
    Stripe.publishableKey = 'pk_live_51TONnSP1UPrQlK3nOMMQFnrDtZFpTKbwiW607iVq3RZVn1aGI9B4EL0AWrXQZ0rWLMdK3NZMdz7iahPateMlIJNW00Sq9ckq3q';
    await Stripe.instance.applySettings();
    debugPrint('[Stripe] initialized successfully');
  } catch (e, st) {
    debugPrint('[Stripe] init error: $e\n$st');
  }
  await ThemeNotifier.init();
  await ViewPreferenceNotifier.init();
  // Capture any cold-start share intent (Android share sheet → QR Party)
  // before the first frame, so the handler has a `pending` URL ready when
  // the post-auth UI mounts and asks for it.
  await WishlistShareHandler.instance.init();
  runApp(const QRPartyApp());
}

final _navigatorKey = GlobalKey<NavigatorState>();

class QRPartyApp extends StatefulWidget {
  const QRPartyApp({super.key});
  @override
  State<QRPartyApp> createState() => _QRPartyAppState();
}

class _QRPartyAppState extends State<QRPartyApp> {
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;
  StreamSubscription<String>? _shareSub;

  @override
  void initState() {
    super.initState();
    _setupMessaging();
    _setupDeepLinks();
    _setupBilling();
    _setupSharedUrls();
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    _purchaseSub?.cancel();
    _shareSub?.cancel();
    super.dispose();
  }

  /// Two delivery paths for shared URLs:
  /// 1. Cold start — `WishlistShareHandler.init()` already captured it into
  ///    `pending` before runApp(). We drain it after the first frame, but
  ///    only once a user is signed in (otherwise the welcome/login screen
  ///    is on top and a sheet would feel disconnected from the auth flow).
  /// 2. Warm start — listen on the handler's stream for shares that come
  ///    in while the app is alive.
  void _setupSharedUrls() {
    // Warm path.
    _shareSub = WishlistShareHandler.instance.urls.listen(_presentShareSheet);
    // Cold path — wait for first frame, then drain pending (deferred until
    // auth resolves; see _presentShareSheet).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = WishlistShareHandler.instance.consumePending();
      if (pending != null) _presentShareSheet(pending);
    });
  }

  /// Routes a shared URL into the bottom sheet on top of whatever's
  /// currently visible. If the user isn't signed in yet we re-queue the
  /// URL and wait for the next auth-state emission to flush it — the
  /// share is preserved across the sign-in flow.
  void _presentShareSheet(String url) {
    final ctx = _navigatorKey.currentContext;
    if (ctx == null) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      // Not signed in yet — listen once on the auth stream and retry as
      // soon as the user signs in. This preserves the shared URL across
      // the welcome → sign-in flow without losing it to a navigator pop.
      late final StreamSubscription<User?> sub;
      sub = FirebaseAuth.instance.authStateChanges().listen((u) {
        if (u == null) return;
        sub.cancel();
        // Defer one frame so HomeRouter has had a chance to mount.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final c = _navigatorKey.currentContext;
          if (c != null) ShareToWishlistSheet.show(c, url);
        });
      });
      return;
    }
    ShareToWishlistSheet.show(ctx, url);
  }

  Future<void> _setupMessaging() async {
    // Cold-start: app opened from terminated state by tapping a notification
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      // Delay until the widget tree and auth state are ready
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future.delayed(const Duration(milliseconds: 600));
        _handleNotificationTap(initial);
      });
    }
    // Background: app resumes from background via notification tap
    FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);
  }

  Future<void> _setupDeepLinks() async {
    // Cold start: app launched from a deep link while terminated
    try {
      final uri = await _appLinks.getInitialLink();
      if (uri != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          await Future.delayed(const Duration(milliseconds: 600));
          _handleDeepLink(uri);
        });
      }
    } catch (_) {}
    // Warm start: app resumes from background via deep link
    _linkSub = _appLinks.uriLinkStream.listen(_handleDeepLink, onError: (_) {});
  }

  Future<void> _handleDeepLink(Uri uri) async {
    if (uri.host != 'partywithqr.com') return;
    final eventId = uri.queryParameters['id'];
    if (eventId == null || eventId.isEmpty) return;
    try {
      final doc = await FirebaseFirestore.instance.collection('events').doc(eventId).get();
      if (!doc.exists) return;
      _navigatorKey.currentState?.push(MaterialPageRoute(
        builder: (_) => GuestEventScreen(
          eventId: eventId,
          eventData: doc.data() as Map<String, dynamic>,
        ),
      ));
    } catch (_) {}
  }

  Future<void> _setupBilling() async {
    final available = await InAppPurchase.instance.isAvailable();
    if (!available) return;
    _purchaseSub = InAppPurchase.instance.purchaseStream.listen(
      _handlePurchases,
      onError: (_) {},
    );
  }

  Future<void> _handlePurchases(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      if (purchase.status == PurchaseStatus.purchased ||
          purchase.status == PurchaseStatus.restored) {
        await _deliverPurchase(purchase);
        final ctx = _navigatorKey.currentContext;
        if (ctx != null && ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
            content: Text(purchase.status == PurchaseStatus.restored
                ? 'Purchase restored!'
                : '🎉 Purchase successful!'),
            backgroundColor: AppColors.green,
          ));
        }
      } else if (purchase.status == PurchaseStatus.error) {
        final ctx = _navigatorKey.currentContext;
        if (ctx != null && ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
            content: Text(purchase.error?.message ?? 'Purchase failed'),
            backgroundColor: Colors.redAccent,
          ));
        }
      }
      if (purchase.pendingCompletePurchase) {
        await InAppPurchase.instance.completePurchase(purchase);
      }
    }
  }

  Future<void> _deliverPurchase(PurchaseDetails purchase) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final token = purchase.verificationData.serverVerificationData;
    final ref = FirebaseFirestore.instance.collection('users').doc(uid);

    switch (purchase.productID) {
      case 'business_monthly':
        await ref.update({
          'accountType': 'business',
          'isTrialing': false,
          'subscriptionTier': 'monthly',
          'subscriptionExpiry': Timestamp.fromDate(DateTime.now().add(const Duration(days: 30))),
          'subscriptionPurchaseToken': token,
        });
      case 'business_yearly':
        await ref.update({
          'accountType': 'business',
          'isTrialing': false,
          'subscriptionTier': 'yearly',
          'subscriptionExpiry': Timestamp.fromDate(DateTime.now().add(const Duration(days: 365))),
          'subscriptionPurchaseToken': token,
        });
      case 'business_plus_monthly':
        await ref.update({
          'accountType': 'businessPlus',
          'isTrialing': false,
          'subscriptionTier': 'monthly_plus',
          'subscriptionExpiry': Timestamp.fromDate(DateTime.now().add(const Duration(days: 30))),
          'subscriptionPurchaseToken': token,
        });
      case 'business_plus_yearly':
        await ref.update({
          'accountType': 'businessPlus',
          'isTrialing': false,
          'subscriptionTier': 'yearly_plus',
          'subscriptionExpiry': Timestamp.fromDate(DateTime.now().add(const Duration(days: 365))),
          'subscriptionPurchaseToken': token,
        });
      case 'storage_25_events':
        await ref.update({
          'archivedEventLimit': 25,
          'storagePurchase': 'storage_25_events',
          'purchaseToken': token,
        });
      case 'storage_50_events':
        await ref.update({
          'archivedEventLimit': 50,
          'storagePurchase': 'storage_50_events',
          'purchaseToken': token,
        });
    }
  }

  Future<void> _handleNotificationTap(RemoteMessage message) async {
    final eventId = message.data['eventId'] as String?;
    if (eventId == null || eventId.isEmpty) return;
    try {
      final doc = await FirebaseFirestore.instance.collection('events').doc(eventId).get();
      if (!doc.exists) return;
      _navigatorKey.currentState?.push(MaterialPageRoute(
        builder: (_) => GuestEventScreen(
          eventId: eventId,
          eventData: doc.data() as Map<String, dynamic>,
        ),
      ));
    } catch (_) {}
  }

  static final _lightTheme = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF52796F),
      primary: const Color(0xFF52796F),
      secondary: const Color(0xFF84A98C),
    ),
    scaffoldBackgroundColor: const Color(0xFFF8F7FC),
    useMaterial3: true,
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      color: Colors.white,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
  );

  static final _darkTheme = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF9C7FD4),
      brightness: Brightness.dark,
      primary: const Color(0xFF9C7FD4),
      secondary: const Color(0xFFC8922A),
      surface: const Color(0xFF383B56),
    ),
    scaffoldBackgroundColor: const Color(0xFF2D3047),
    useMaterial3: true,
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      color: const Color(0xFF383B56),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF383B56),
      foregroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    dividerColor: const Color(0xFF4A4E6B),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeNotifier.instance,
      builder: (context, mode, _) {
        return MaterialApp(
          navigatorKey: _navigatorKey,
          title: 'QR Party',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: _lightTheme,
          darkTheme: _darkTheme,
          home: StreamBuilder<User?>(
            stream: FirebaseAuth.instance.authStateChanges(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Scaffold(
                  backgroundColor: Color(0xFFF8F7FC),
                  body: Center(child: CircularProgressIndicator(color: AppColors.green)),
                );
              }
              if (snapshot.hasData) return const HomeRouter();
              return const WelcomeScreen();
            },
          ),
        );
      },
    );
  }
}
