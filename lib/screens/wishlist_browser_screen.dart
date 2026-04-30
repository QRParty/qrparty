import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../utils.dart';

// ── Theme palette ──────────────────────────────────────────────
const _bgDark      = Color(0xFF2D3047);
const _bgLight     = Color(0xFFF8F7FC);
const _cardDark    = Color(0xFF383B56);
const _cardLight   = Colors.white;
const _borderDark  = Color(0xFF4A4E6B);
const _borderLight = Color(0xFFE0E8E0);
const _mutedDark   = Color(0xFFA9A6B8);
const _mutedLight  = Color(0xFF8892A4);
const _purple      = Color(0xFF9C7FD4);
const _green       = AppColors.green;

/// Result returned via [Navigator.pop] when the host taps "Add to
/// Wishlist". The caller should:
///   1. Append a wishlist-shaped map (name + imageUrl + url + zero
///      price) to its in-memory items list.
///   2. Refocus the item-name TextField so the host can immediately
///      edit the auto-extracted title or set a price.
///
/// All three fields can be empty strings if the page didn't expose
/// the corresponding metadata; the caller decides how to handle that
/// (today: keep "Untitled item" as the name, leave imageUrl/url
/// blank).
class WishlistBrowserResult {
  final String name;
  final String imageUrl;
  final String url;
  const WishlistBrowserResult({
    required this.name,
    required this.imageUrl,
    required this.url,
  });
  Map<String, dynamic> toMap() => {
        'name': name,
        'imageUrl': imageUrl,
        'url': url,
      };
}

/// Seamless in-app browser used by the wishlist editor on
/// create_event_screen.dart and edit_event_screen.dart. Replaces the
/// old `LaunchMode.externalApplication` chip-tap behavior so the host
/// never leaves the app to add a wishlist item.
///
/// On tap of the floating "Add to Wishlist" button we run a small
/// piece of JavaScript inside the page to read the rendered DOM:
///   • `og:title` (or document.title fallback)
///   • `og:image`
///   • `window.location.href`
/// and pop the screen with a [WishlistBrowserResult]. Because the
/// extraction runs after the page has rendered, SPA-injected meta
/// tags work — which is the main edge case the existing share-sheet
/// regex flow ([share_to_wishlist_sheet.dart]) misses.
class WishlistBrowserScreen extends StatefulWidget {
  /// URL to load on first show. Typically the homepage of one of the
  /// retailer chips, but can be anything (e.g. about:blank for the
  /// generic "Browse the web" chip — the host then types into the
  /// address bar).
  final String initialUrl;
  const WishlistBrowserScreen({super.key, required this.initialUrl});

  @override
  State<WishlistBrowserScreen> createState() => _WishlistBrowserScreenState();
}

class _WishlistBrowserScreenState extends State<WishlistBrowserScreen> {
  late final WebViewController _ctl;
  final TextEditingController _addr = TextEditingController();
  final FocusNode _addrFocus = FocusNode();
  bool _loading = true;
  bool _adding = false;
  bool _canGoBack = false;

  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;
  Color get _fg     => _isDark ? Colors.white : AppColors.dark;

  @override
  void initState() {
    super.initState();
    // about:blank means the host launched via the generic "Browse the
    // web" chip — they don't have a destination yet. Clear the
    // address bar (so the placeholder shows) and auto-focus it after
    // first frame so the keyboard pops up immediately and they can
    // type a URL or search query right away.
    final isBlank = widget.initialUrl == 'about:blank' || widget.initialUrl.isEmpty;
    _addr.text = isBlank ? '' : widget.initialUrl;
    if (isBlank) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _addrFocus.requestFocus();
      });
    }
    _ctl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Some retailer sites (Amazon especially) ship a stripped-down
      // mobile/m-dot experience to default WebView UAs that hides
      // og: tags and full product images. Pretending to be a desktop
      // Chrome dramatically improves extraction quality. Same UA as
      // share_to_wishlist_sheet.dart's HTTP fetch for parity.
      ..setUserAgent(
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36')
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          if (mounted) setState(() => _loading = true);
        },
        onPageFinished: (url) async {
          final canBack = await _ctl.canGoBack();
          if (!mounted) return;
          setState(() {
            _loading = false;
            _addr.text = url;
            _canGoBack = canBack;
          });
        },
      ))
      ..loadRequest(Uri.parse(_normalize(widget.initialUrl)));
  }

  @override
  void dispose() {
    _addr.dispose();
    _addrFocus.dispose();
    super.dispose();
  }

  /// Coerce a free-typed address-bar entry into a loadable URL.
  /// Bare hosts ("amazon.com") get https:// prepended; queries
  /// ("rainbow socks") become a Google search; anything that's
  /// already a fully-qualified URL passes through.
  String _normalize(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return 'about:blank';
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')
        || trimmed.startsWith('about:')) {
      return trimmed;
    }
    // Looks-like-a-URL heuristic: contains a dot AND no spaces.
    if (trimmed.contains('.') && !trimmed.contains(' ')) {
      return 'https://$trimmed';
    }
    return 'https://www.google.com/search?q=${Uri.encodeQueryComponent(trimmed)}';
  }

  Future<void> _go() async {
    final url = _normalize(_addr.text);
    _addrFocus.unfocus();
    await _ctl.loadRequest(Uri.parse(url));
  }

  Future<void> _reload() async => _ctl.reload();

  Future<void> _back() async {
    if (await _ctl.canGoBack()) await _ctl.goBack();
  }

  /// Extracts page metadata via JavaScript, pops with the result.
  /// Wraps the JS payload in `JSON.stringify` so we get back a
  /// predictable string — both Android and iOS implementations of
  /// `runJavaScriptReturningResult` then return that JSON string,
  /// though Android double-encodes it (wraps in extra quotes +
  /// escapes inner quotes) while iOS returns it raw. The decoder
  /// below handles both shapes.
  Future<void> _addToWishlist() async {
    if (_adding) return;
    setState(() => _adding = true);
    try {
      const js = r'''
        (function() {
          function meta(prop) {
            var sels = [
              'meta[property="' + prop + '"]',
              'meta[name="' + prop + '"]'
            ];
            for (var i = 0; i < sels.length; i++) {
              var m = document.querySelector(sels[i]);
              if (m) {
                var c = m.getAttribute('content');
                if (c) return c;
              }
            }
            return '';
          }
          // og:image:secure_url is the canonical https variant some
          // retailers (Target, Walmart) use; fall back to og:image
          // and finally to the first <img> with a usable src.
          var img = meta('og:image:secure_url') || meta('og:image');
          if (!img) {
            var imgs = document.getElementsByTagName('img');
            for (var i = 0; i < imgs.length; i++) {
              var src = imgs[i].getAttribute('src');
              if (src && /^https?:\/\//.test(src)) { img = src; break; }
            }
          }
          var title = meta('og:title') || document.title || '';
          return JSON.stringify({
            title: title.trim(),
            image: img || '',
            url: window.location.href || ''
          });
        })();
      ''';
      final raw = await _ctl.runJavaScriptReturningResult(js);
      final data = _decodeJsResult(raw);
      final name = (data['title'] as String? ?? '').trim();
      final result = WishlistBrowserResult(
        name: name.isEmpty ? 'Untitled item' : name,
        imageUrl: (data['image'] as String? ?? '').trim(),
        url: (data['url'] as String? ?? '').trim(),
      );
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      debugPrint('[WishlistBrowser] extract failed: $e');
      if (mounted) {
        setState(() => _adding = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not read this page: $e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  /// Normalize the JS return value into a `Map<String, dynamic>`.
  /// Android: `runJavaScriptReturningResult` returns a String that
  /// is itself a JSON-encoded string (i.e. wrapped in extra quotes,
  /// inner quotes escaped) — needs a double `jsonDecode`. iOS:
  /// returns the inner string directly, single decode is enough.
  /// Some platforms occasionally return a Map already (older API
  /// surface) — handled too.
  Map<String, dynamic> _decodeJsResult(Object? raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    var s = raw.toString();
    // Strip outer quoting if present (Android case).
    if (s.startsWith('"') && s.endsWith('"')) {
      try {
        final unwrapped = jsonDecode(s);
        if (unwrapped is String) s = unwrapped;
      } catch (_) {/* leave s as-is and try direct parse below */}
    }
    final decoded = jsonDecode(s);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw FormatException('Unexpected JS result shape: $raw');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(56),
        child: AppBar(
          backgroundColor: _card,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          leadingWidth: 40,
          leading: IconButton(
            icon: Icon(Icons.close, color: _fg),
            tooltip: 'Cancel',
            onPressed: () => Navigator.pop(context),
          ),
          titleSpacing: 0,
          title: Container(
            height: 38,
            decoration: BoxDecoration(
              color: _bg,
              borderRadius: BorderRadius.circular(19),
              border: Border.all(color: _border),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              Icon(_loading ? Icons.hourglass_empty : Icons.lock_outline,
                  size: 14, color: _muted),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _addr,
                  focusNode: _addrFocus,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  autocorrect: false,
                  style: TextStyle(
                    fontFamily: 'Nunito', fontSize: 13.5, color: _fg,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 8),
                    hintText: 'Search or type a URL',
                  ),
                  onSubmitted: (_) => _go(),
                ),
              ),
            ]),
          ),
          actions: [
            IconButton(
              icon: Icon(Icons.arrow_back_ios_new,
                  color: _canGoBack ? _fg : _muted, size: 18),
              tooltip: 'Back',
              onPressed: _canGoBack ? _back : null,
            ),
            IconButton(
              icon: Icon(Icons.refresh, color: _fg),
              tooltip: 'Reload',
              onPressed: _reload,
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
      body: Stack(children: [
        WebViewWidget(controller: _ctl),
        if (_loading)
          const Positioned(
            left: 0, right: 0, top: 0,
            child: LinearProgressIndicator(
              minHeight: 2,
              valueColor: AlwaysStoppedAnimation(_purple),
              backgroundColor: Color(0x22000000),
            ),
          ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _adding ? null : _addToWishlist,
        backgroundColor: _green,
        foregroundColor: Colors.white,
        icon: _adding
            ? const SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.2),
              )
            : const Icon(Icons.add_shopping_cart),
        label: Text(_adding ? 'Adding…' : 'Add to Wishlist',
            style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
    );
  }
}
