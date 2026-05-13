import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// Captures URLs shared INTO the app from other apps (Amazon, Target, Etsy,
/// the system browser's share sheet, etc.) and routes them to the
/// "Add to wishlist" bottom sheet.
///
/// Two delivery paths:
/// - **Cold start** (app launched by tapping the share target while killed):
///   `getInitialMedia()` returns the share that launched the app.
/// - **Warm start** (app already running, user shares again): the
///   `getMediaStream()` stream emits each incoming share.
///
/// The handler also holds a `pending` URL so the UI can pop the sheet at the
/// right moment (e.g. after sign-in completes) rather than racing the
/// initial frame. Call [consumePending] from the UI to read + clear it.
class WishlistShareHandler {
  WishlistShareHandler._();
  static final WishlistShareHandler instance = WishlistShareHandler._();

  final StreamController<String> _urls = StreamController<String>.broadcast();
  String? _pending;
  /// When `_pending` was captured. Pairs with `_pending` so
  /// `consumePending` can throw away stale entries that have been
  /// sitting around longer than `_pendingTtl`. Set every time
  /// `_pending` is assigned a non-null value, cleared in lockstep.
  DateTime? _pendingAt;
  bool _initialized = false;

  /// Pending URLs older than this are treated as stale and dropped.
  /// Anything that actually came from a share gesture lands at the
  /// next post-frame callback; if a value has been waiting around
  /// for half a minute, the user likely interacted with something
  /// else and the pending intent is no longer relevant.
  static const _pendingTtl = Duration(seconds: 30);

  /// Hosts treated as our own — incoming "shares" of these URLs
  /// are deep-link clicks (e.g. tapping a partywithqr.com/event/X
  /// link), NOT wishlist product shares. The OS sometimes delivers
  /// those through the share-receive intent path on Android, which
  /// in turn pops the wishlist sheet on top of whatever the user
  /// is doing. Filtering them at consumption time AND at stream
  /// arrival keeps both delivery paths clean.
  static const _ownHosts = <String>{
    'partywithqr.com',
    'www.partywithqr.com',
  };

  static bool _isOwnDomain(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return _ownHosts.contains(uri.host.toLowerCase());
  }

  /// Stream of shared URLs received while the app is running. Subscribe
  /// from the navigator-key holder so the listener survives screen rebuilds.
  Stream<String> get urls => _urls.stream;

  /// One-shot URL captured before any listener was ready (cold start, or
  /// warm share that fired before the post-auth UI was up). Always
  /// returns at most one value — the pending field is cleared eagerly
  /// at the top of every call so a second invocation can never
  /// re-deliver the same URL, regardless of whether the first call
  /// actually used it.
  ///
  /// Returns null when:
  ///   • Nothing was pending,
  ///   • The pending URL points at our own domain (treat as a deep
  ///     link, not a wishlist share — see `_ownHosts`), OR
  ///   • The pending URL is older than [_pendingTtl] (stale leftover
  ///     from a previous foregrounding / app-switch sequence).
  String? consumePending() {
    // Snapshot then clear immediately. If a caller invokes us twice
    // in quick succession, the second call always sees null — no
    // chance of re-firing the same URL on a navigation event.
    final snapshot = _pending;
    final snapshotAt = _pendingAt;
    _pending = null;
    _pendingAt = null;

    if (snapshot == null) return null;
    if (_isOwnDomain(snapshot)) {
      debugPrint('[WishlistShareHandler] consumePending dropped own-domain URL: $snapshot');
      return null;
    }
    if (snapshotAt != null) {
      final age = DateTime.now().difference(snapshotAt);
      if (age > _pendingTtl) {
        debugPrint('[WishlistShareHandler] consumePending dropped stale URL '
            '(age=${age.inSeconds}s > ${_pendingTtl.inSeconds}s): $snapshot');
        return null;
      }
    }
    return snapshot;
  }

  /// Wire the plugin streams. Idempotent — safe to call from main() once.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      // Cold start: app was launched by a share intent.
      final initial = await ReceiveSharingIntent.instance.getInitialMedia();
      final firstUrl = _firstUrl(initial);
      if (firstUrl != null) {
        if (_isOwnDomain(firstUrl)) {
          // Tapping a partywithqr.com link from another app comes
          // through the same share-receive intent on Android; don't
          // queue our own deep links as wishlist shares.
          debugPrint('[WishlistShareHandler] init dropped own-domain initial: $firstUrl');
        } else {
          _pending = firstUrl;
          _pendingAt = DateTime.now();
        }
        // Tell the plugin we've consumed the cold-start media so it won't
        // be re-delivered on the next foreground. Always reset, even when
        // we dropped the URL above — keeps state clean.
        ReceiveSharingIntent.instance.reset();
      }
    } catch (e) {
      debugPrint('[WishlistShareHandler] getInitialMedia failed: $e');
    }
    // Warm start: stream of subsequent shares while the app is alive.
    try {
      ReceiveSharingIntent.instance.getMediaStream().listen(
        (List<SharedMediaFile> media) {
          final url = _firstUrl(media);
          if (url == null) return;
          if (_isOwnDomain(url)) {
            // Same own-domain filter as the cold-start path — drop
            // partywithqr.com deep links so they don't surface the
            // wishlist sheet over whatever the user is doing.
            debugPrint('[WishlistShareHandler] stream dropped own-domain: $url');
            return;
          }
          if (_urls.hasListener) {
            _urls.add(url);
          } else {
            // No active listener yet — queue it so the UI can grab it
            // when it eventually mounts (e.g. user shared from lock screen,
            // app came up but the Navigator hasn't settled yet). Stamp
            // a timestamp alongside so consumePending can throw it
            // away if it's not picked up within the TTL window.
            _pending = url;
            _pendingAt = DateTime.now();
          }
        },
        onError: (e) => debugPrint('[WishlistShareHandler] stream error: $e'),
      );
    } catch (e) {
      debugPrint('[WishlistShareHandler] getMediaStream failed: $e');
    }
  }

  /// Picks the first URL out of the shared payload. The plugin gives us a
  /// list of [SharedMediaFile]s; for ACTION_SEND text intents the path
  /// field carries the raw shared string. We extract the first http(s) URL
  /// we find — most apps include extra context text alongside the URL.
  String? _firstUrl(List<SharedMediaFile> media) {
    for (final m in media) {
      // For text/plain shares the plugin populates `path` with the text.
      // For other shares (images, files) `path` is a file path — we ignore
      // those because the wishlist flow is URL-only.
      final candidate = (m.path).trim();
      final url = _extractUrl(candidate);
      if (url != null) return url;
    }
    return null;
  }

  /// Returns the first http(s) URL contained in [text], or null. Tolerates
  /// app share blurbs like "Check this out: https://amazon.com/dp/B0... – $19.99"
  /// by matching the URL pattern rather than requiring the whole string.
  static String? _extractUrl(String text) {
    if (text.isEmpty) return null;
    // Strict-ish URL match. Stops at whitespace or common trailing punctuation.
    final match = RegExp(r'https?://[^\s<>"‘’“”]+').firstMatch(text);
    if (match == null) return null;
    var url = match.group(0)!;
    // Trim trailing punctuation that's almost never part of a real URL.
    while (url.isNotEmpty && '.,);!?'.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// Test hook — lets unit tests push synthetic URLs without needing the
  /// platform plugin. Not used in production code paths.
  @visibleForTesting
  void debugInject(String url) => _urls.add(url);
}
