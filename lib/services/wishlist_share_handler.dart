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
  bool _initialized = false;

  /// Stream of shared URLs received while the app is running. Subscribe
  /// from the navigator-key holder so the listener survives screen rebuilds.
  Stream<String> get urls => _urls.stream;

  /// One-shot URL captured before any listener was ready (cold start, or
  /// warm share that fired before the post-auth UI was up). Consume once.
  String? consumePending() {
    final p = _pending;
    _pending = null;
    return p;
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
        _pending = firstUrl;
        // Tell the plugin we've consumed the cold-start media so it won't
        // be re-delivered on the next foreground.
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
          if (_urls.hasListener) {
            _urls.add(url);
          } else {
            // No active listener yet — queue it so the UI can grab it
            // when it eventually mounts (e.g. user shared from lock screen,
            // app came up but the Navigator hasn't settled yet).
            _pending = url;
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
