import 'dart:async';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:app_links/app_links.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'utils.dart';
import 'screens/welcome_screen.dart';
import 'screens/guest_event_screen.dart';
import 'screens/home_router.dart';
import 'screens/public_org_screen.dart';
import 'services/wishlist_share_handler.dart';
import 'widgets/share_to_wishlist_sheet.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    if (Firebase.apps.isEmpty) {
      // Platform-specific options from `flutterfire configure`. The
      // previous hardcoded `:web:` appId crashed the iOS Firebase SDK
      // in `+[FIRApp addAppToAppDictionary:]` because the platform
      // marker in the appId didn't match the running runtime.
      // DefaultFirebaseOptions.currentPlatform returns the correct
      // appId per platform: web→…:web:…, android→…:android:…,
      // ios→…:ios:… (registered in Firebase project qrparty-6e648).
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
  } catch (e) {
    print('Firebase init error: $e');
  }

  // ── App Check ─────────────────────────────────────────────────
  // Silences the "missing reCAPTCHA token" warning that Firebase Auth
  // logs on Android during password-reset / sign-in flows, and gates
  // backend traffic to verified app instances. Debug builds use the
  // built-in debug provider — copy the debug token from logcat once on
  // first launch and register it under Firebase Console → App Check →
  // Apps → (Android app) → Manage debug tokens. Release builds use
  // Play Integrity (Android) / DeviceCheck (iOS), no manual setup.
  try {
    await FirebaseAppCheck.instance.activate(
      androidProvider: kDebugMode ? AndroidProvider.debug : AndroidProvider.playIntegrity,
      appleProvider:   kDebugMode ? AppleProvider.debug   : AppleProvider.deviceCheck,
    );
    debugPrint('[AppCheck] activated (debug=$kDebugMode)');
  } catch (e) {
    debugPrint('[AppCheck] activation failed: $e');
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
  // Provision the Android notification channel + initialize the local-
  // notifications plugin BEFORE runApp so the foreground onMessage
  // handler (registered later in QRPartyApp) has a ready channel to
  // post into. Without this, FCM data messages arrived but the system
  // tray silently dropped them on Android 8+.
  await NotificationBridge.instance.init();
  runApp(const QRPartyApp());
}

/// Bridges FCM messages to the device's notification tray. Firebase
/// Messaging on Android only auto-displays system notifications when
/// the app is BACKGROUNDED — foreground messages need to be posted via
/// flutter_local_notifications, and every notification on Android 8+
/// must reference a registered NotificationChannel by id. Both pieces
/// are wired here.
///
/// The channel id (`qrparty_default`) must match the value declared in
/// AndroidManifest.xml under
/// `com.google.firebase.messaging.default_notification_channel_id` so
/// background notifications (delivered directly by the FCM SDK without
/// our code in the loop) also land in this channel. The Cloud Function
/// payload sets `android.notification.channel_id: 'qrparty_default'`
/// to be doubly explicit.
class NotificationBridge {
  NotificationBridge._();
  static final NotificationBridge instance = NotificationBridge._();

  static const String channelId = 'qrparty_default';
  static const String channelName = 'QR Party Notifications';
  static const String channelDescription = 'Event RSVPs, host announcements, and reminders.';

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      ),
    );
    await _plugin.initialize(initSettings);

    // Register the notification channel on Android 8+. Idempotent — the
    // OS no-ops re-registration of a channel that already exists.
    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(const AndroidNotificationChannel(
      channelId,
      channelName,
      description: channelDescription,
      importance: Importance.high,
      playSound: true,
    ));
    debugPrint('[NotificationBridge] channel `$channelId` ready');

    // Foreground messages — the OS does NOT auto-display these.
    // Convert the FCM payload to a local notification so the user sees
    // the same tray entry whether the app is open or not.
    FirebaseMessaging.onMessage.listen((RemoteMessage msg) {
      debugPrint('[FCM] foreground message id=${msg.messageId} title=${msg.notification?.title}');
      final n = msg.notification;
      final title = n?.title ?? msg.data['title'] as String? ?? 'QR Party';
      final body  = n?.body  ?? msg.data['body']  as String? ?? '';
      if (title.isEmpty && body.isEmpty) return;
      _plugin.show(
        msg.hashCode,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelName,
            channelDescription: channelDescription,
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        payload: msg.data['eventId'] as String?,
      );
    });
  }
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
  StreamSubscription<User?>? _authSub;

  /// Holds a deep-link target (shortCode or docId) that arrived while the
  /// user wasn't signed in yet. Drained by [_setupPendingDeepLinkDrain]
  /// the moment auth state flips to a non-null user, so the visitor lands
  /// on the right event screen automatically after login.
  String? _pendingDeepLinkEventLookup;

  /// Same pattern as [_pendingDeepLinkEventLookup] but for the
  /// `/org/{orgId}` deep link. Mutually exclusive in practice — a
  /// single incoming URL writes to one OR the other.
  String? _pendingDeepLinkOrgId;

  @override
  void initState() {
    super.initState();
    _setupMessaging();
    _setupDeepLinks();
    _setupBilling();
    _setupSharedUrls();
    _setupPendingDeepLinkDrain();
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    _purchaseSub?.cancel();
    _shareSub?.cancel();
    _authSub?.cancel();
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
    // Wishlist beta gate — drop incoming shared URLs on the floor when
    // the feature is hidden. The handler still queues them in case the
    // gate re-opens later in the same session, but no user-visible
    // bottom sheet appears for them in the meantime.
    if (!kWishlistEnabled) {
      debugPrint('[WishlistShare] dropped — kWishlistEnabled=false url=$url');
      return;
    }
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

  /// Watches the auth stream so we can re-fire a deep link that arrived
  /// Writes the device's FCM token to `users/{uid}.fcmToken` so the
  /// host-push paths (Running Late, RSVP confirmations, mass notifs)
  /// can find the right device. Fired on every sign-in via the auth
  /// listener below — runs regardless of which screen the user lands
  /// on, so deep-link-only users still register. Best-effort: any
  /// failure (denied permission, network blip, prefs unavailable) is
  /// swallowed so it can never block sign-in or app startup.
  Future<void> _registerFcmTokenForUser(User user) async {
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true, badge: true, sound: true,
      );
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) return;
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set({'fcmToken': token}, SetOptions(merge: true));
    } catch (_) {/* best-effort — see doc comment */}
  }

  /// while the user was on the welcome / login screen. When auth flips to
  /// a signed-in user we drain `_pendingDeepLinkEventLookup` once and
  /// route to the matching event. Harmless on warm-state sign-ins because
  /// the pending field stays null when no link is queued.
  void _setupPendingDeepLinkDrain() {
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) async {
      if (user == null) return;
      // Register the FCM token on every sign-in. Was previously gated
      // behind HomeFeedScreen.initState, which meant deep-link-only
      // users (deep link → guest event screen, never visiting the
      // home feed) silently never registered — they couldn't receive
      // host pushes like Running Late or RSVP confirmations.
      _registerFcmTokenForUser(user);
      final pendingEvent = _pendingDeepLinkEventLookup;
      final pendingOrg   = _pendingDeepLinkOrgId;
      if ((pendingEvent == null || pendingEvent.isEmpty) &&
          (pendingOrg   == null || pendingOrg.isEmpty)) return;
      _pendingDeepLinkEventLookup = null;
      _pendingDeepLinkOrgId       = null;
      // Defer one frame so HomeRouter has had a chance to mount —
      // otherwise the push lands on a still-rebuilding navigator.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (pendingEvent != null && pendingEvent.isNotEmpty) {
          _resolveAndPushEvent(pendingEvent);
        }
        if (pendingOrg != null && pendingOrg.isNotEmpty) {
          _pushOrgScreen(pendingOrg);
        }
      });
    });
  }

  /// Three URL shapes recognised here:
  ///   • Event (new): `https://partywithqr.com/event/{shortCode}` —
  ///     path-based, used by the QR encoder ([generate_qr_screen.dart])
  ///     and share buttons. shortCode is a 4–8 char uppercase alphanumeric.
  ///   • Event (legacy): `https://partywithqr.com/?id={docId}` —
  ///     querystring, kept around for older invitations / merch print
  ///     files that stamped the long-form URL.
  ///   • Org: `https://partywithqr.com/org/{orgId}` — public org page
  ///     reached by scanning an org QR sticker. Routes to
  ///     [PublicOrgScreen] which shows the org's upcoming events.
  /// On a hit we look up the target and push the matching screen. If
  /// the user isn't signed in yet we stash the lookup; the auth-drain
  /// listener routes them once they're in.
  Future<void> _handleDeepLink(Uri uri) async {
    if (uri.host != 'partywithqr.com') return;
    final segs = uri.pathSegments;
    debugPrint('[DeepLink] received uri=$uri segments=$segs');

    // Org path takes priority over the event-id resolver.
    if (segs.length >= 2 && segs[0] == 'org' && segs[1].isNotEmpty) {
      final orgId = segs[1];
      if (FirebaseAuth.instance.currentUser == null) {
        debugPrint('[DeepLink] org=$orgId — not signed in, queuing for drain');
        _pendingDeepLinkOrgId = orgId;
        return;
      }
      _pushOrgScreen(orgId);
      return;
    }

    // Event paths — new path form first, then legacy querystring.
    String? lookup;
    if (segs.length >= 2 && segs[0] == 'event' && segs[1].isNotEmpty) {
      lookup = segs[1];
    } else {
      lookup = uri.queryParameters['id'];
    }
    if (lookup == null || lookup.isEmpty) return;
    debugPrint('[DeepLink] event lookup=$lookup');

    if (FirebaseAuth.instance.currentUser == null) {
      debugPrint('[DeepLink] not signed in — queuing for post-login drain');
      _pendingDeepLinkEventLookup = lookup;
      return;
    }
    await _resolveAndPushEvent(lookup);
  }

  /// Pushes [PublicOrgScreen] for the given orgId. Org doc fetch and
  /// permission validation happen inside the screen itself — if the
  /// orgId is bogus or the doc was deleted, the screen renders an
  /// inline "Couldn't find that organization" empty state instead
  /// of a snackbar from here.
  void _pushOrgScreen(String orgId) {
    _navigatorKey.currentState?.push(MaterialPageRoute(
      builder: (_) => PublicOrgScreen(orgId: orgId),
    ));
  }

  /// shortCode → docId lookup. A 4–8 char uppercase alphanumeric input
  /// is almost certainly a shortCode, so the where() runs first; on a
  /// miss (or for any longer input) we fall back to a literal doc.get().
  Future<void> _resolveAndPushEvent(String input) async {
    try {
      final upper = input.toUpperCase();
      final looksLikeShortCode = RegExp(r'^[A-Z0-9]{4,8}$').hasMatch(upper);
      DocumentSnapshot? snap;
      if (looksLikeShortCode) {
        final qs = await FirebaseFirestore.instance
            .collection('events')
            .where('shortCode', isEqualTo: upper)
            .limit(1)
            .get();
        if (qs.docs.isNotEmpty) snap = qs.docs.first;
      }
      final resolved = snap
          ?? await FirebaseFirestore.instance.collection('events').doc(input).get();
      if (!resolved.exists) {
        debugPrint('[DeepLink] no event for input=$input (shortCode? $looksLikeShortCode)');
        return;
      }
      _navigatorKey.currentState?.push(MaterialPageRoute(
        builder: (_) => GuestEventScreen(
          eventId: resolved.id,
          eventData: resolved.data() as Map<String, dynamic>,
        ),
      ));
    } catch (e) {
      debugPrint('[DeepLink] resolve failed for input=$input: $e');
    }
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
        final delivered = await _deliverPurchase(purchase);
        final ctx = _navigatorKey.currentContext;
        if (delivered) {
          if (ctx != null && ctx.mounted) {
            ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
              content: Text(purchase.status == PurchaseStatus.restored
                  ? 'Purchase restored!'
                  : '🎉 Purchase successful!'),
              backgroundColor: AppColors.green,
            ));
          }
          // Acknowledge to Google ONLY after server-side validation
          // succeeded. Acknowledging before validation would let a
          // failed-validation purchase look "complete" to Google — the
          // queue would never replay it, and the user would be charged
          // without entitlement. Leaving it pending here means the
          // purchaseStream re-fires this same purchase on next app
          // launch, giving validation another chance.
          if (purchase.pendingCompletePurchase) {
            await InAppPurchase.instance.completePurchase(purchase);
          }
        } else {
          // CF said no — show a soft error and DO NOT call
          // completePurchase. See comment above for why we leave it
          // pending. The CF logs (firebase functions:log) will say
          // whether this was an auth issue, a Play API rejection,
          // or a productId mismatch.
          if (ctx != null && ctx.mounted) {
            ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
              content: Text("Couldn't verify your purchase — we'll retry on next launch. Contact support if this keeps happening."),
              backgroundColor: Colors.redAccent,
            ));
          }
        }
      } else if (purchase.status == PurchaseStatus.error) {
        final ctx = _navigatorKey.currentContext;
        if (ctx != null && ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
            content: Text(purchase.error?.message ?? 'Purchase failed'),
            backgroundColor: Colors.redAccent,
          ));
        }
        // Error / canceled — nothing to validate, ack so Google clears
        // the queue and doesn't replay the same failure on every launch.
        if (purchase.pendingCompletePurchase) {
          await InAppPurchase.instance.completePurchase(purchase);
        }
      }
    }
  }

  /// Hands the purchase off to the server-side validator
  /// (`verifyAndDeliverPurchase` CF), which:
  ///   1. Hits the Google Play Developer API to confirm the
  ///      purchaseToken is real, paid, and not refunded.
  ///   2. Acknowledges the purchase with Google (subscription or
  ///      product) within the 3-day acknowledgement window.
  ///   3. Writes the entitlement fields onto `users/{uid}` —
  ///      accountType / subscriptionTier / subscriptionExpiry for
  ///      subscriptions; archivedEventLimit / storagePurchase for
  ///      one-time storage upgrades; subscriptionPurchaseToken or
  ///      purchaseToken for the back-pointer.
  ///
  /// Returns true only when the CF responds with `{ok: true}`. Any
  /// auth, validation, network, or unexpected failure returns false
  /// so [_handlePurchases] can skip the [completePurchase] call and
  /// let Google replay the purchase on the next app launch.
  ///
  /// Replaces the previous client-side Firestore write. That older
  /// path trusted whatever the IAP plugin reported and would happily
  /// stamp `accountType: 'businessPlus'` on any uid that produced a
  /// `PurchaseStatus.purchased` event — including a spoofed one. The
  /// CF closes that trust gap.
  Future<bool> _deliverPurchase(PurchaseDetails purchase) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      debugPrint('[Purchase] no signed-in user — cannot verify productId=${purchase.productID}');
      return false;
    }
    final purchaseToken = purchase.verificationData.serverVerificationData;
    if (purchaseToken.isEmpty) {
      debugPrint('[Purchase] empty serverVerificationData for productId=${purchase.productID}');
      return false;
    }
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('verifyAndDeliverPurchase');
      final result = await callable.call({
        'productId':     purchase.productID,
        'purchaseToken': purchaseToken,
      });
      final data = (result.data as Map?)?.cast<String, dynamic>() ?? const {};
      final ok = data['ok'] == true;
      if (!ok) {
        debugPrint('[Purchase] CF non-ok response productId=${purchase.productID}: $data');
      }
      return ok;
    } on FirebaseFunctionsException catch (e) {
      // Surfaces the CF's HttpsError code (unauthenticated /
      // permission-denied / failed-precondition / invalid-argument /
      // not-found / internal). Specific codes guide support triage —
      // failed-precondition = subscription expired or refunded,
      // permission-denied = Play API rejected the token.
      debugPrint('[Purchase] verifyAndDeliverPurchase rejected productId=${purchase.productID} code=${e.code} message=${e.message}');
      return false;
    } catch (e) {
      debugPrint('[Purchase] verifyAndDeliverPurchase failed productId=${purchase.productID}: $e');
      return false;
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

  /// Builds the app-wide TextTheme: Inter for body / labels / small
  /// titles (the default reading font) and DM Sans for display /
  /// headline / titleLarge (the larger display font). Any widget that
  /// renders Text without overriding fontFamily picks these up via
  /// the active Theme — no per-widget changes needed. Hardcoded
  /// `fontFamily: 'FredokaOne'` / `'Nunito'` references in existing
  /// widgets continue to work; they're not bundled assets, so Flutter
  /// already falls back to the platform default for those, and this
  /// theme replaces that fallback with the Google Fonts pair.
  static TextTheme _appTextTheme(TextTheme base) {
    return GoogleFonts.interTextTheme(base).copyWith(
      displayLarge:   GoogleFonts.dmSans(textStyle: base.displayLarge),
      displayMedium:  GoogleFonts.dmSans(textStyle: base.displayMedium),
      displaySmall:   GoogleFonts.dmSans(textStyle: base.displaySmall),
      headlineLarge:  GoogleFonts.dmSans(textStyle: base.headlineLarge),
      headlineMedium: GoogleFonts.dmSans(textStyle: base.headlineMedium),
      headlineSmall:  GoogleFonts.dmSans(textStyle: base.headlineSmall),
      titleLarge:     GoogleFonts.dmSans(textStyle: base.titleLarge),
    );
  }

  static final _lightTheme = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF52796F),
      primary: const Color(0xFF52796F),
      secondary: const Color(0xFF84A98C),
    ),
    scaffoldBackgroundColor: const Color(0xFFF8F7FC),
    useMaterial3: true,
    textTheme: _appTextTheme(ThemeData.light().textTheme),
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
    textTheme: _appTextTheme(ThemeData.dark().textTheme),
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
