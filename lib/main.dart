import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
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

/// Writes the device's FCM token to `users/{uid}.fcmToken` so the
/// host-push paths (Running Late, RSVP confirmations, mass notifs)
/// can find the right device. Fired on every non-anonymous sign-in
/// via the auth listener — runs regardless of which screen the user
/// lands on, so deep-link-only users still register. Best-effort:
/// any failure (denied permission, network blip, prefs unavailable)
/// is swallowed so it can never block sign-in or app startup.
///
/// Anonymous users are skipped on purpose — a deep-link guest
/// shouldn't see the iOS push-permission prompt the moment they tap
/// an invite, and Firestore would only end up with a throwaway
/// `users/{anonUid}` doc holding a single `fcmToken` field. When
/// the guest later upgrades to a real account via linkWithCredential
/// in welcome_screen.dart, that flow manually re-invokes this
/// function — linkWithCredential keeps the same User instance and
/// does NOT fire authStateChanges, so the auth-state listener
/// otherwise never sees the transition.
///
/// Top-level (not a State method) so welcome_screen.dart's link
/// path can call it without poking at private members on
/// QRPartyAppState.
Future<void> registerFcmTokenForUser(User user) async {
  if (user.isAnonymous) {
    debugPrint('[FCM] skipping token registration for anonymous user uid=${user.uid}');
    return;
  }
  try {
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true, badge: true, sound: true,
    );
    debugPrint('[FCM] permission uid=${user.uid} status=${settings.authorizationStatus}');

    // iOS: getToken() returns null until APNs has handed Firebase a
    // device token. Permission granted ≠ APNs ready — the OS does the
    // APNs handshake asynchronously after registerForRemoteNotifications.
    // Poll getAPNSToken with a short backoff so first-launch isn't a
    // race. Android has no equivalent dependency; skip the poll there.
    if (Platform.isIOS) {
      String? apns;
      for (int attempt = 1; attempt <= 6; attempt++) {
        apns = await FirebaseMessaging.instance.getAPNSToken();
        debugPrint('[FCM] APNs poll attempt=$attempt uid=${user.uid} apns=${apns == null || apns.isEmpty ? "null" : "ok"}');
        if (apns != null && apns.isNotEmpty) break;
        if (attempt < 6) await Future.delayed(const Duration(milliseconds: 500));
      }
      if (apns == null || apns.isEmpty) {
        debugPrint('[FCM] APNs token never arrived after 6 attempts uid=${user.uid} — skipping registration; onTokenRefresh will retry if it lands later');
        return;
      }
    }

    final token = await FirebaseMessaging.instance.getToken();
    if (token == null || token.isEmpty) {
      debugPrint('[FCM] getToken() returned null/empty uid=${user.uid} authStatus=${settings.authorizationStatus} — likely APNs not registered or permission denied');
      return;
    }
    debugPrint('[FCM] writing token uid=${user.uid} tokenLen=${token.length} tokenSuffix=…${token.length >= 8 ? token.substring(token.length - 8) : token}');
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .set({'fcmToken': token}, SetOptions(merge: true));
    debugPrint('[FCM] token write succeeded uid=${user.uid}');
  } catch (e, st) {
    debugPrint('[FCM] token registration FAILED uid=${user.uid}: $e\n$st');
  }
}

class QRPartyApp extends StatefulWidget {
  const QRPartyApp({super.key});
  @override
  State<QRPartyApp> createState() => QRPartyAppState();
}

class QRPartyAppState extends State<QRPartyApp> {
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;
  StreamSubscription<String>? _shareSub;
  StreamSubscription<User?>? _authSub;
  StreamSubscription<String>? _tokenRefreshSub;
  AppLifecycleListener? _lifecycleListener;

  /// Holds a deep-link target (shortCode or docId) that arrived while the
  /// user wasn't signed in yet. Drained by [_setupPendingDeepLinkDrain]
  /// the moment auth state flips to a non-null user, so the visitor lands
  /// on the right event screen automatically after login.
  String? _pendingDeepLinkEventLookup;

  /// Same pattern as [_pendingDeepLinkEventLookup] but for the
  /// `/org/{orgId}` deep link. Mutually exclusive in practice — a
  /// single incoming URL writes to one OR the other.
  String? _pendingDeepLinkOrgId;

  /// Last short-code we surfaced the clipboard-resume prompt for.
  /// Tracked so the same code doesn't re-prompt on every resume after
  /// the user has already decided (Open or Not now). Reset by app
  /// relaunch — not persisted, this is intentional.
  String? _lastClipboardCodePrompted;

  @override
  void initState() {
    super.initState();
    _setupMessaging();
    _setupTokenRefreshListener();
    _setupDeepLinks();
    _setupBilling();
    _setupSharedUrls();
    _setupPendingDeepLinkDrain();
    _setupLifecycleListener();
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    _purchaseSub?.cancel();
    _shareSub?.cancel();
    _authSub?.cancel();
    _tokenRefreshSub?.cancel();
    _lifecycleListener?.dispose();
    super.dispose();
  }

  /// Refreshes the cached FirebaseAuth user object every time the app
  /// resumes from background. Fixes a stale-auth class of bugs that
  /// shows up after TestFlight / Play Store auto-updates: the cached
  /// User object survives the swap, but its claims, custom token, and
  /// disabled-state become stale relative to the server. Without this,
  /// users hit "permission denied" on operations that should work, and
  /// the only workaround was sign-out + back in. `currentUser?.reload()`
  /// pulls the fresh user record on resume so the cached object catches
  /// up silently.
  ///
  /// Best-effort: any failure (network blip, token expired, user
  /// deleted server-side) is logged and swallowed. The auth-state
  /// listener handles user-deleted as a separate sign-out flow.
  void _setupLifecycleListener() {
    _lifecycleListener = AppLifecycleListener(
      onResume: () async {
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          try {
            await user.reload();
            debugPrint('[Lifecycle] resumed — reloaded auth for uid=${user.uid}');
          } catch (e) {
            debugPrint('[Lifecycle] resume reload FAILED uid=${user.uid}: $e');
          }
        }
        // Peek the clipboard for a partywithqr.com/event/<code> URL or
        // a bare 4–8 char alphanumeric. If found AND we haven't already
        // prompted for the same code this session, surface a confirm
        // dialog. Failures are swallowed inside the helper.
        await _maybePromptFromClipboard();
      },
    );
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

  /// Catches FCM tokens that arrive after the initial registration —
  /// most commonly on iOS when getToken() lost the APNs race in
  /// registerFcmTokenForUser, or when Firebase rotates the token. The
  /// listener is global (set up once in initState), so it captures
  /// refreshes for whatever user happens to be signed in at the time.
  /// Best-effort: failures are logged, never thrown.
  void _setupTokenRefreshListener() {
    _tokenRefreshSub = FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('[FCM] onTokenRefresh fired but no user signed in — skipping write tokenSuffix=…${token.length >= 8 ? token.substring(token.length - 8) : token}');
        return;
      }
      if (token.isEmpty) {
        debugPrint('[FCM] onTokenRefresh fired with empty token uid=${user.uid} — skipping');
        return;
      }
      debugPrint('[FCM] onTokenRefresh writing token uid=${user.uid} tokenLen=${token.length} tokenSuffix=…${token.length >= 8 ? token.substring(token.length - 8) : token}');
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .set({'fcmToken': token}, SetOptions(merge: true));
        debugPrint('[FCM] onTokenRefresh write succeeded uid=${user.uid}');
      } catch (e, st) {
        debugPrint('[FCM] onTokenRefresh write FAILED uid=${user.uid}: $e\n$st');
      }
    });
  }

  /// Watches the auth stream so we can re-fire a deep link that arrived
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
      // host pushes like Running Late or RSVP confirmations. Anonymous
      // users are no-op'd inside registerFcmTokenForUser; their post-
      // link transition is handled manually in welcome_screen.dart.
      registerFcmTokenForUser(user);
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
        final signedIn = await _signInAnonymouslyForDeepLink();
        if (!signedIn) {
          debugPrint('[DeepLink] org=$orgId — anon sign-in failed, queuing for drain');
          _pendingDeepLinkOrgId = orgId;
          return;
        }
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
      final signedIn = await _signInAnonymouslyForDeepLink();
      if (!signedIn) {
        debugPrint('[DeepLink] event lookup=$lookup — anon sign-in failed, queuing for post-login drain');
        _pendingDeepLinkEventLookup = lookup;
        return;
      }
    }
    await _resolveAndPushEvent(lookup);
  }

  /// Silently signs the guest in as an anonymous Firebase user so a
  /// deep link can resolve + push the event without an account. Mirrors
  /// what event.html does on the web (no sign-up wall for invited
  /// guests). Returns true on success — the caller should then proceed
  /// to resolve and push as if the user had always been signed in.
  /// Returns false if anonymous auth is unavailable (offline / Firebase
  /// outage / not enabled in console); the caller falls back to the
  /// pending-queue drain so the link isn't lost when the user later
  /// signs up the long way.
  ///
  /// The auth-state listener in [_setupPendingDeepLinkDrain] fires the
  /// moment this succeeds, which would normally drain the pending
  /// queue — but we only populate the queue when this returns false,
  /// so the drain is a no-op on the happy path and we avoid a double
  /// resolve/push.
  Future<bool> _signInAnonymouslyForDeepLink() async {
    try {
      final cred = await FirebaseAuth.instance.signInAnonymously();
      debugPrint('[DeepLink] anonymous sign-in ok uid=${cred.user?.uid}');
      return cred.user != null;
    } catch (e) {
      debugPrint('[DeepLink] anonymous sign-in FAILED: $e');
      return false;
    }
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

  /// Deep-link entry point — kept for the existing handler call sites
  /// (`_handleDeepLink`, `_setupPendingDeepLinkDrain`). The actual
  /// shortCode → docId → push logic lives in [openEventByCode] so the
  /// home-feed "Enter Code" dialog and the clipboard-resume prompt
  /// can reuse it without duplicating the Firestore queries.
  Future<void> _resolveAndPushEvent(String input) => openEventByCode(input);

  /// Public shortCode → event resolver. Accepts either a 4–8 char
  /// uppercase alphanumeric shortCode OR a literal Firestore doc id.
  /// Whitespace is trimmed and the shortCode regex check runs against
  /// the uppercased form, so callers don't need to normalize first.
  ///
  /// On success pushes [GuestEventScreen] onto the root navigator. On
  /// any failure (not found, permission-denied, exception) logs and
  /// returns silently — never throws to the caller.
  ///
  /// Reused by:
  ///   • [_resolveAndPushEvent] — deep link handler
  ///   • [_maybePromptFromClipboard] — clipboard-resume prompt
  ///   • home_feed_screen.dart "Enter Code" dialog — via
  ///     `context.findAncestorStateOfType<QRPartyAppState>()`
  Future<void> openEventByCode(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return;
    try {
      final upper = trimmed.toUpperCase();
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
          ?? await FirebaseFirestore.instance.collection('events').doc(trimmed).get();
      if (!resolved.exists) {
        debugPrint('[EventResolver] no event for input=$trimmed (shortCode? $looksLikeShortCode)');
        return;
      }
      _navigatorKey.currentState?.push(MaterialPageRoute(
        builder: (_) => GuestEventScreen(
          eventId: resolved.id,
          eventData: resolved.data() as Map<String, dynamic>,
        ),
      ));
    } catch (e) {
      debugPrint('[EventResolver] resolve failed for input=$trimmed: $e');
    }
  }

  /// Foreground-resume clipboard peek. Called from the lifecycle
  /// listener's `onResume:` callback. Workflow:
  ///   1. Bail if no navigator is mounted (no UI to attach a dialog to).
  ///   2. `Clipboard.hasStrings()` first — silent on iOS 14+, avoids
  ///      the "QR Party pasted from X" toast when the clipboard is
  ///      empty or non-text.
  ///   3. If there IS text, `getData()` — this DOES surface the paste
  ///      toast on iOS, which is acceptable because we're about to
  ///      prompt the user anyway.
  ///   4. Parse for either `partywithqr.com/event/<code>` or a bare
  ///      4–8 char alphanumeric.
  ///   5. De-dupe against [_lastClipboardCodePrompted] so the same
  ///      code doesn't re-prompt every resume.
  ///   6. Show a confirmation dialog — never silent navigation.
  ///   7. On user confirm, hand off to [openEventByCode].
  /// All errors are caught and swallowed — a clipboard read failure
  /// must never block the rest of the resume path.
  Future<void> _maybePromptFromClipboard() async {
    try {
      if (_navigatorKey.currentState == null) return;
      final hasStrings = await Clipboard.hasStrings();
      if (!hasStrings) return;
      final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();
      if (text == null || text.isEmpty) return;

      // Try URL form first, fall back to bare token.
      String? code;
      final uri = Uri.tryParse(text);
      if (uri != null && uri.host == 'partywithqr.com') {
        final segs = uri.pathSegments;
        if (segs.length >= 2 && segs[0] == 'event' && segs[1].isNotEmpty) {
          code = segs[1].trim().toUpperCase();
        }
      }
      if (code == null) {
        final upper = text.toUpperCase();
        if (RegExp(r'^[A-Z0-9]{4,8}$').hasMatch(upper)) {
          code = upper;
        }
      }
      if (code == null) return;

      // De-dupe: don't re-prompt for the same code on every resume.
      if (code == _lastClipboardCodePrompted) return;
      _lastClipboardCodePrompted = code;

      final ctx = _navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      final confirmed = await showDialog<bool>(
        context: ctx,
        builder: (dialogCtx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Open this event?'),
          content: Text('We found an event code in your clipboard: $code'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: const Text('Not now'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(true),
              child: const Text(
                'Open',
                style: TextStyle(color: AppColors.purple, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await openEventByCode(code);
      }
    } catch (e) {
      debugPrint('[Clipboard] prompt error: $e');
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
        // Explicit platform tag — lets the CF route to the App Store
        // Server API (iOS) vs the Google Play Developer API (Android)
        // without falling back to its token-shape heuristic. The
        // heuristic works for StoreKit 2 transaction IDs but
        // misclassifies StoreKit 1 base64 receipts as Android, so
        // sending the tag explicitly is the safe path.
        'platform':      Platform.isIOS ? 'ios' : 'android',
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
