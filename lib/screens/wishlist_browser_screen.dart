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
  /// Numeric price string (e.g. "19.99") or empty when not detected.
  /// Already normalized: currency symbols and thousands separators
  /// stripped, comma decimals replaced with dots, so the caller can
  /// `double.tryParse` directly without further cleaning.
  final String price;
  const WishlistBrowserResult({
    required this.name,
    required this.imageUrl,
    required this.url,
    this.price = '',
  });
  Map<String, dynamic> toMap() => {
        'name': name,
        'imageUrl': imageUrl,
        'url': url,
        'price': price,
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
    // Retry budget for SPA hydration. Target / Walmart / many React-
    // built PDPs ship a near-empty initial HTML and inject the
    // JSON-LD product blocks (and sometimes og:price meta tags) after
    // their JS runs. If the host taps Add the moment the page first
    // paints, findPrice() walks an empty DOM and returns '' even
    // though the price WILL appear seconds later. Looping up to 6×
    // 500ms (= 3s wall-clock max) catches that hydration window.
    // The FAB stays in its "Adding…" spinner state for the whole
    // retry, which functions as the loading indicator.
    const maxAttempts = 6;
    const retryDelay = Duration(milliseconds: 500);
    Map<String, dynamic>? data;
    String price = '';
    try {
      // In-page JS extracts the four fields we want straight from
      // the rendered DOM. Doing it in JS (not Dart-side regex on the
      // raw HTML) is what makes this flow work for SPA-rendered
      // pages where meta tags get injected client-side after load.
      //
      // Price chain mirrors share_to_wishlist_sheet.dart's
      // _findJsonLdPrice + _findRetailerDomPrice + meta fallbacks,
      // adapted to live DOM:
      //   1. og:price:amount         → meta tag
      //   2. product:price:amount    → meta tag
      //   3. itemprop="price"        → element @content or text
      //   4. Amazon .a-price .a-offscreen → element text (canonical
      //      Amazon screenreader-only price element)
      //   5. JSON-LD <script>        → "price" / "lowPrice" regex
      //      tolerating "$" prefix and comma decimals
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

          // Diagnostic log array — every step of findPrice() pushes a
          // human-readable line in here, surfaced back to Dart via the
          // _diag field in the JSON return. Dart-side iterates and
          // debugPrints each line so we can see in logcat exactly
          // what the live DOM contained when the JS ran.
          var diag = [];
          function dlog(msg) { diag.push(String(msg).slice(0, 800)); }

          function findPrice() {
            // 1. og:price:amount meta tag
            var p1 = meta('og:price:amount');
            dlog('step1 og:price:amount → ' + (p1 ? '"' + p1 + '"' : 'MISS'));
            if (p1) return p1;

            // 2. product:price:amount meta tag
            var p2 = meta('product:price:amount');
            dlog('step2 product:price:amount → ' + (p2 ? '"' + p2 + '"' : 'MISS'));
            if (p2) return p2;

            // 3. itemprop="price" element — content attr, then text
            var ip = document.querySelector('[itemprop="price"]');
            if (ip) {
              var ipContent = ip.getAttribute('content');
              var ipText = (ip.textContent || '').trim();
              dlog('step3 [itemprop=price] FOUND — '
                + 'content=' + (ipContent ? '"' + ipContent + '"' : 'null')
                + ' text=' + (ipText ? '"' + ipText.slice(0, 80) + '"' : 'empty'));
              if (ipContent) return ipContent;
              if (ipText) return ipText;
            } else {
              dlog('step3 [itemprop=price] not present in DOM');
            }

            // 4. Amazon — .a-price .a-offscreen screenreader span
            var off = document.querySelector('.a-price .a-offscreen');
            if (off) {
              var offText = (off.textContent || '').trim();
              dlog('step4 .a-price .a-offscreen FOUND — text="'
                + offText.slice(0, 80) + '"');
              if (offText) return offText;
            } else {
              dlog('step4 .a-price .a-offscreen not present in DOM');
            }

            // 5. JSON-LD blocks. Dump first 500 chars of each block
            // before regexing so we can see what the page actually
            // ships even if our regex doesn't match it.
            var scripts = document.querySelectorAll(
              'script[type="application/ld+json"]'
            );
            dlog('step5 JSON-LD blocks found: ' + scripts.length);
            for (var i = 0; i < scripts.length; i++) {
              var raw = scripts[i].textContent || '';
              dlog('step5 block[' + i + '] length=' + raw.length
                + ' preview=' + JSON.stringify(raw.slice(0, 500)));
              var m = raw.match(
                /"(?:price|lowPrice)"\s*:\s*"?\$?([0-9]+(?:[.,][0-9]+)?)"?/
              );
              if (m) {
                dlog('step5 block[' + i + '] matched price=' + m[1]);
                return m[1];
              } else {
                dlog('step5 block[' + i + '] no price match');
              }
            }

            // 6. Target-specific fallbacks. Their React SPA fingerprints
            // WebView UAs and never hydrates the JSON-LD blocks (steps
            // 5 returns "blocks found: 0" on Target PDPs), but the
            // rendered price DOM and the bootstrapped data globals
            // are still present. We try four different angles in
            // increasing fragility:
            //   6a. data-test="product-price" — Target's stable
            //       attribute on their canonical price node.
            //   6b. data-test="buy-box-price" — alternate slot used
            //       on some PDP templates (multi-variant items, Tgt+).
            //   6c. emotion/styled-components classnames containing
            //       "h-text-bs" or "styles__CurrentPriceFraction" —
            //       Target's compiled CSS-in-JS class fragments. Less
            //       stable across Target deploys but covers PDP
            //       templates where data-test isn't present.
            //   6d. window.__PRELOADED_STATE__ / window.__TGT_DATA__
            //       — full product object the SPA boots from. Walk
            //       common shapes ({product:{price:{...}}}) and
            //       fall back to a JSON stringify + regex.
            // Whichever resolves first wins; each substep logs its
            // hit-or-miss so we can see in logcat which path Target
            // is currently shipping for the tested PDP.
            function nodePriceText(el) {
              if (!el) return '';
              // Prefer @content if microdata-tagged, else visible text.
              var c = el.getAttribute && el.getAttribute('content');
              if (c && c.trim()) return c.trim();
              var t = (el.textContent || '').trim();
              return t;
            }

            // 6a. [data-test="product-price"]
            var pp = document.querySelector('[data-test="product-price"]');
            if (pp) {
              var ppText = nodePriceText(pp);
              dlog('step6a [data-test=product-price] FOUND — text="'
                + ppText.slice(0, 80) + '"');
              if (ppText) return ppText;
            } else {
              dlog('step6a [data-test=product-price] not present in DOM');
            }

            // 6b. [data-test="buy-box-price"]
            var bb = document.querySelector('[data-test="buy-box-price"]');
            if (bb) {
              var bbText = nodePriceText(bb);
              dlog('step6b [data-test=buy-box-price] FOUND — text="'
                + bbText.slice(0, 80) + '"');
              if (bbText) return bbText;
            } else {
              dlog('step6b [data-test=buy-box-price] not present in DOM');
            }

            // 6c. Class-substring match on Target's compiled CSS-in-JS
            // class names. We use querySelectorAll('[class*="..."]')
            // which is a substring (not whole-word) match — exactly
            // what we want since the compiled classes look like
            // "styles__CurrentPriceFraction-sc-xyz123 h-text-bs".
            var classSelectors = [
              '[class*="styles__CurrentPriceFraction"]',
              '[class*="h-text-bs"]',
            ];
            var step6cMatched = false;
            for (var ci = 0; ci < classSelectors.length; ci++) {
              var els = document.querySelectorAll(classSelectors[ci]);
              if (els.length === 0) continue;
              for (var ei = 0; ei < els.length; ei++) {
                var elText = (els[ei].textContent || '').trim();
                // Only return if the text shape looks pricey — avoids
                // matching `h-text-bs` instances on category pills,
                // breadcrumbs, etc.
                if (/\$?\s*[0-9]+(?:[.,][0-9]+)?/.test(elText)) {
                  dlog('step6c "' + classSelectors[ci]
                    + '" matched — text="' + elText.slice(0, 80) + '"');
                  step6cMatched = true;
                  return elText;
                }
              }
            }
            if (!step6cMatched) {
              dlog('step6c class-substring selectors found no priced node');
            }

            // 6d. Bootstrapped state globals. Target ships at least
            // two: __PRELOADED_STATE__ (legacy SSR) and __TGT_DATA__
            // (newer SPA boot). Try a few canonical shapes first,
            // then fall back to JSON.stringify + regex on the full
            // object so we don't miss schema changes.
            function fromGlobal(globalName) {
              try {
                var g = window[globalName];
                if (!g) return null;
                // Common shape: g.product.price.current_retail
                var probe = g
                  && g.product
                  && g.product.price
                  && (g.product.price.current_retail
                      || g.product.price.formatted_current_price
                      || g.product.price.price);
                if (probe) {
                  dlog('step6d window.' + globalName
                    + '.product.price.* matched: ' + probe);
                  return String(probe);
                }
                // Fallback: stringify the whole object and regex.
                // Bounded to 100KB so we don't blow the WebView
                // bridge on huge state trees.
                var s;
                try { s = JSON.stringify(g); } catch (_) { s = ''; }
                if (!s) return null;
                if (s.length > 100000) s = s.slice(0, 100000);
                var m = s.match(
                  /"(?:current_retail|formatted_current_price|price|lowPrice)"\s*:\s*"?\$?([0-9]+(?:[.,][0-9]+)?)"?/
                );
                if (m) {
                  dlog('step6d window.' + globalName
                    + ' regex matched: ' + m[1]);
                  return m[1];
                }
                dlog('step6d window.' + globalName
                  + ' present but no price field matched (stringified '
                  + s.length + 'ch)');
                return null;
              } catch (e) {
                dlog('step6d window.' + globalName + ' threw: ' + e);
                return null;
              }
            }
            var globals = ['__PRELOADED_STATE__', '__TGT_DATA__', '__NEXT_DATA__'];
            for (var gi = 0; gi < globals.length; gi++) {
              if (typeof window[globals[gi]] === 'undefined') {
                dlog('step6d window.' + globals[gi] + ' undefined');
                continue;
              }
              var v = fromGlobal(globals[gi]);
              if (v) return v;
            }

            dlog('all 6 steps missed — returning empty');
            return '';
          }

          var priceResult = findPrice();
          return JSON.stringify({
            title: title.trim(),
            image: img || '',
            url: window.location.href || '',
            price: priceResult,
            _diag: diag
          });
        })();
      ''';
      // Run the extractor up to maxAttempts times, sleeping retryDelay
      // between attempts. We bail out early as soon as price comes
      // back non-empty — most static pages resolve on attempt 1, SPAs
      // typically resolve by attempt 2-4 once their hydration runs.
      // Title and image overwrite on each attempt too: if those also
      // hydrate late, the LAST attempt's values win.
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        final raw = await _ctl.runJavaScriptReturningResult(js);
        if (!mounted) return;
        data = _decodeJsResult(raw);

        // Diag printed on every attempt so we can see the hydration
        // progression in logcat — e.g. "JSON-LD blocks found: 0" on
        // attempt 1 → "JSON-LD blocks found: 2" on attempt 3.
        final diag = data['_diag'];
        debugPrint('[WishlistBrowser] attempt $attempt/$maxAttempts:');
        if (diag is List) {
          for (final line in diag) {
            debugPrint('[WishlistBrowser/JS] $line');
          }
        }

        price = (data['price'] as String? ?? '').trim();
        if (price.isNotEmpty) {
          debugPrint('[WishlistBrowser] price resolved on attempt $attempt');
          break;
        }
        if (attempt < maxAttempts) {
          await Future.delayed(retryDelay);
          if (!mounted) return;
        }
      }

      // After the loop, `data` is guaranteed non-null (the loop runs
      // at least once before `break` or completion). Local promotion
      // doesn't reach across the await chain, hence the `!`.
      final rawTitle = (data!['title'] as String? ?? '').trim();
      final rawPrice = price;

      // Apply the same retailer-aware cleanup the share-to-wishlist
      // sheet does on shared URLs — strips "Amazon.com:" / " - Target"
      // style noise, normalizes invisible Unicode hyphenation hints
      // back to spaces, caps at 80 chars at a word boundary.
      final cleanedName = _cleanTitle(rawTitle);
      // Normalize price: drop currency symbols / thousand separators,
      // turn comma decimal into dot decimal, so the caller can
      // double.tryParse() the result without re-cleaning.
      final cleanedPrice = rawPrice
          .replaceAll(',', '.')
          .replaceAll(RegExp(r'[^\d.]'), '');

      debugPrint('[WishlistBrowser] extracted '
          'title="$cleanedName" price="$cleanedPrice" '
          'image="${data['image'] ?? ''}"');

      final result = WishlistBrowserResult(
        name: cleanedName.isEmpty ? 'Untitled item' : cleanedName,
        imageUrl: (data['image'] as String? ?? '').trim(),
        url: (data['url'] as String? ?? '').trim(),
        price: cleanedPrice,
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

  /// Mirrors the cleanup used by share_to_wishlist_sheet.dart's
  /// `_cleanTitle`. Three steps:
  ///   1. Replace invisible Unicode (soft hyphen U+00AD, the
  ///      zero-width family U+200B–U+200F, word joiner U+2060,
  ///      BOM U+FEFF) with regular spaces, then collapse runs
  ///      of whitespace. Amazon embeds these between words for
  ///      hyphenation hints — they look like nothing in the
  ///      rendered title field but ARE characters in the string,
  ///      so visible words appear to run together.
  ///   2. Strip leading retailer prefix (`Amazon.com:`, `Target —`,
  ///      etc.) and trailing retailer suffix (` | Walmart.com`,
  ///      ` - Etsy`, etc.). Suffix separator requires whitespace
  ///      before it so the strip can never start mid-word.
  ///   3. Word-boundary cap at 80 chars with `…`.
  ///
  /// Inlined here rather than imported because share_to_wishlist_sheet
  /// is a private widget — extracting these helpers into a shared
  /// utility module is the right cleanup but out of scope for this
  /// bugfix. If a third place needs the same logic, lift to
  /// `lib/utils/scrape.dart` then.
  String _cleanTitle(String raw) {
    debugPrint('[WishlistBrowser] _cleanTitle in: ${raw.length}ch — "$raw"');
    var s = raw
        .replaceAll(RegExp('[­​-‏⁠﻿]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    s = s.replaceFirst(
      RegExp(
        r"^\s*(?:Amazon(?:\.com)?|Target|Walmart(?:\.com)?|Best\s*Buy|Etsy|eBay|Costco|Wayfair|Macy['’]?s|Nordstrom|Home\s*Depot|Lowe['’]?s)\s*[:\-—–|·]\s+",
        caseSensitive: false,
      ),
      '',
    );
    s = s.replaceFirst(
      RegExp(
        r"\s+[|\-—–:·]\s*(?:Amazon(?:\.com)?|Target|Walmart(?:\.com)?|Best\s*Buy|Etsy|eBay|Costco|Wayfair|Macy['’]?s|Nordstrom|Home\s*Depot|Lowe['’]?s)(?:\s*,?\s*(?:Inc|LLC|Corp)\.?)?\s*$",
        caseSensitive: false,
      ),
      '',
    );

    // Trailing house-brand suffix — `- Spritz™`, `- Hyperice®`,
    // `- Threshold™`, etc. Target especially likes to append
    // their house-brand after a dash with a trademark glyph. The
    // suffix is one or more letter-prefixed words ending in
    // ™ / ® / ©. Required `\s+` before the dash anchors at a real
    // word boundary so the strip never slices mid-word; `\s*$` at
    // the tail allows incidental trailing whitespace.
    s = s.replaceFirst(
      RegExp(r'\s+[\-—–]\s+[A-Za-z][A-Za-z0-9 ]*?[™®©]\s*$'),
      '',
    );

    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    // 50-char cap (down from 80) so titles fit in the inline name
    // field without being cut off mid-display. Cuts at the last
    // word boundary in the second half of the window so the cap
    // never lands mid-word.
    if (s.length > 50) {
      var cut = s.substring(0, 50);
      final lastSpace = cut.lastIndexOf(' ');
      if (lastSpace > 25) cut = cut.substring(0, lastSpace);
      s = '${cut.trimRight()}…';
    }
    debugPrint('[WishlistBrowser] _cleanTitle out: ${s.length}ch — "$s"');
    return s;
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
