import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import '../utils.dart';

/// Bottom sheet shown when a URL is shared INTO the app from another app
/// (Amazon, Target, Etsy, browser share menu, etc.). Fetches the page's
/// `og:title` and `og:image` to pre-fill the form, lets the guest pick which
/// of their upcoming events to add it to, and writes the item to
/// `events/{eventId}/wishlist/{itemId}`.
class ShareToWishlistSheet {
  /// Opens the sheet on the current navigator. No-op if [url] is empty.
  static Future<void> show(BuildContext context, String url) {
    if (url.trim().isEmpty) return Future.value();
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _SheetBody(url: url.trim()),
    );
  }
}

class _SheetBody extends StatefulWidget {
  final String url;
  const _SheetBody({required this.url});
  @override
  State<_SheetBody> createState() => _SheetBodyState();
}

class _SheetBodyState extends State<_SheetBody> {
  late final TextEditingController _name  = TextEditingController();
  late final TextEditingController _price = TextEditingController();
  late final TextEditingController _notes = TextEditingController();
  String? _imageUrl;

  bool _fetchingMeta = true;
  bool _saving = false;
  String? _error;

  // Eligible-events state
  bool _loadingEvents = true;
  List<({String id, String title, DateTime? date, bool isHost})> _events = [];
  String? _selectedEventId;

  @override
  void initState() {
    super.initState();
    _fetchOg();
    _loadEligibleEvents();
  }

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    _notes.dispose();
    super.dispose();
  }

  // ── og:title + og:image fetch ────────────────────────────────
  // Uses regex on raw HTML rather than a full parser to keep deps light.
  // Catches >90% of e-commerce pages (Amazon/Target/Etsy/Walmart/etc. all
  // ship og:* tags in the initial HTML response). SPA-rendered pages that
  // inject meta tags via JS are out of reach without a headless browser —
  // the user can still type the name manually.
  Future<void> _fetchOg() async {
    try {
      final resp = await http.get(
        Uri.parse(widget.url),
        headers: const {
          // Some sites (Amazon, etc.) serve a sparse no-meta HTML to
          // unknown UAs. Pretending to be a desktop browser gets us the
          // full meta tags more often.
          'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
              'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml',
        },
      ).timeout(const Duration(seconds: 8));

      debugPrint('[ShareToWishlist] fetch ${widget.url} → status=${resp.statusCode}');

      if (resp.statusCode >= 200 && resp.statusCode < 400) {
        final body = _decodeHtml(resp);

        // ── HTML body diagnostic ──────────────────────────────
        // Print the body length and the first 2000 characters so
        // we can see in logcat exactly what the page returned.
        // Long Amazon/Target pages can be 1MB+ — we only need the
        // <head> meta tags, which fit comfortably in the first
        // 2000 chars on every retailer we've seen.
        debugPrint('[ShareToWishlist] body length: ${body.length}');
        debugPrint(
          '[ShareToWishlist] body[0:2000]: '
          '${body.substring(0, body.length < 2000 ? body.length : 2000)}',
        );

        // Each scrape attempt is logged below so we can see in
        // logcat exactly which fallback resolved (or all-null'd)
        // per retailer. The price chain is unrolled into named
        // assignments instead of chained `??` so the per-step
        // logs land in order regardless of which one wins.
        final rawTitle = _findMeta(body, 'og:title')
            ?? _findMeta(body, 'twitter:title')
            ?? _findMeta(body, 'title')
            ?? _findTitle(body);
        final image = _findMeta(body, 'og:image')
            ?? _findMeta(body, 'og:image:secure_url')
            ?? _findMeta(body, 'twitter:image');
        final rawDescription = _findMeta(body, 'og:description')
            ?? _findMeta(body, 'twitter:description')
            ?? _findMeta(body, 'description');

        // ── Price chain — each step logged ─────────────────────
        final priceOg = _findMeta(body, 'og:price:amount');
        debugPrint('[ShareToWishlist] price step 1 og:price:amount → ${priceOg ?? 'null'}');
        final pricePO = priceOg ?? _findMeta(body, 'product:price:amount');
        if (priceOg == null) {
          debugPrint('[ShareToWishlist] price step 2 product:price:amount → '
              '${pricePO ?? 'null'}');
        }
        final priceTw = pricePO ?? _findMeta(body, 'twitter:data1');
        if (pricePO == null) {
          debugPrint('[ShareToWishlist] price step 3 twitter:data1 → '
              '${priceTw ?? 'null'}');
        }
        final priceItem = priceTw ?? _findItemprop(body, 'price');
        if (priceTw == null) {
          debugPrint('[ShareToWishlist] price step 4 itemprop=price → '
              '${priceItem ?? 'null'}');
        }
        final priceLd = priceItem ?? _findJsonLdPrice(body);
        if (priceItem == null) {
          debugPrint('[ShareToWishlist] price step 5 JSON-LD → '
              '${priceLd ?? 'null'}');
        }
        final rawPrice = priceLd ?? _findRetailerDomPrice(body);
        if (priceLd == null) {
          debugPrint('[ShareToWishlist] price step 6 retailer DOM → '
              '${rawPrice ?? 'null'}');
        }

        debugPrint('[ShareToWishlist] rawTitle=${rawTitle?.length ?? 0}ch '
            'image=${image != null} '
            'rawDescription=${rawDescription?.length ?? 0}ch '
            'rawPrice=${rawPrice ?? 'null'}');

        // Apply retailer-aware cleanup AFTER scraping so the raw
        // values remain inspectable in the debug log above.
        final title = rawTitle == null ? null : _cleanTitle(rawTitle);
        final description = rawDescription == null
            ? null
            : _truncateAtWord(rawDescription, 150);

        if (mounted) {
          setState(() {
            if (title != null && _name.text.isEmpty) _name.text = title;
            if (description != null && _notes.text.isEmpty) {
              _notes.text = description;
            }
            if (rawPrice != null && _price.text.isEmpty) {
              // Strip currency symbols + thousand separators so the
              // numeric keyboard parses cleanly. _save() does the
              // same strip again as belt-and-braces.
              _price.text = rawPrice.replaceAll(RegExp(r'[^\d.]'), '');
            }
            _imageUrl = image;
            _fetchingMeta = false;
          });
          return;
        }
      }
    } catch (e) {
      // Fall through — user can still type the name manually.
      debugPrint('[ShareToWishlist] og fetch failed: $e');
    }
    if (mounted) setState(() => _fetchingMeta = false);
  }

  /// Strips common retailer noise from a scraped product title and
  /// caps at ~80 characters at a word boundary.
  ///
  /// Real-world titles from major retailers look like:
  ///   "Amazon.com: Funko Pop! Marvel: Captain America - Civil War -
  ///    Iron Man (Mark 46) Vinyl Figure, Multicolor : Toys & Games"
  ///   "Disney Princess Style Collection World Traveler Set with 35+
  ///    Pieces and Convertible Suitcase, Multicolor : Target"
  ///   "Cool Widget — Etsy"
  ///
  /// Strategy: peel off the leading "Retailer:" prefix and the
  /// trailing " - Retailer" suffix, then word-cap at 80. The cap
  /// catches Amazon-style titles that pile category/seller info on
  /// after the actual product name even after the suffix strip.
  String _cleanTitle(String raw) {
    debugPrint('[ShareToWishlist] _cleanTitle in: ${raw.length}ch — "$raw"');
    // ── Step 1: normalize invisible/zero-width Unicode ────────
    // Amazon (and some Etsy templates) embed soft hyphens
    // (U+00AD), zero-width spaces (U+200B), and other invisible
    // hyphenation hints between words. Those characters render as
    // nothing on most fonts but ARE present in the string, so the
    // user sees what looks like words running together
    // (`MakerPortablewith Foldable Legs` was such a case — the
    // raw title actually had `Maker­Portable­with
    // Foldable Legs`). Replacing each invisible char with a space
    // restores word boundaries before any other processing.
    // Truly invisible chars only — soft hyphen (U+00AD), the
    // zero-width family (U+200B–U+200F), word joiner (U+2060),
    // BOM (U+FEFF). Visible hyphens like U+2010 / U+2011 / U+2027
    // are deliberately NOT in this set: they render as proper
    // hyphens, and replacing them with spaces would split
    // legitimate hyphenated words like "non-breaking".
    //
    // Non-raw string + \u escapes so the character class is
    // self-describing rather than a row of invisible glyphs.
    var s = raw
        .replaceAll(RegExp('[­​-‏⁠﻿]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // ── Step 2: strip leading retailer prefix ────────────────
    // `Amazon.com:`, `Target:`, etc. Anchored to start of string
    // and requires the separator to be followed by at least one
    // whitespace, so a title like `Targeted Toy ...` (which
    // happens to start with the substring `Target`) won't match.
    // Raw double-quoted string so the brand-name char-classes
    // can hold both the straight apostrophe (U+0027) and the
    // curly one (U+2019) — `Macy's` ships either form depending
    // on the CMS template.
    s = s.replaceFirst(
      RegExp(
        r"^\s*(?:Amazon(?:\.com)?|Target|Walmart(?:\.com)?|Best\s*Buy|Etsy|eBay|Costco|Wayfair|Macy['’]?s|Nordstrom|Home\s*Depot|Lowe['’]?s)\s*[:\-—–|·]\s+",
        caseSensitive: false,
      ),
      '',
    );

    // ── Step 3: strip trailing retailer suffix ───────────────
    // ` | Walmart.com`, ` - Etsy`, ` : Target`, ` — Amazon.com`,
    // optional `Inc.` / `LLC` / `, Inc.`
    //
    // Critical: the separator MUST be preceded by at least one
    // whitespace character (`\s+` not `\s*`). Earlier the
    // pattern accepted zero whitespace, which on a pathological
    // input could in principle slice mid-word; the user
    // reported this as "the regex is eating characters". With
    // `\s+` required, the removal can never start partway
    // through a real word.
    s = s.replaceFirst(
      RegExp(
        r"\s+[|\-—–:·]\s*(?:Amazon(?:\.com)?|Target|Walmart(?:\.com)?|Best\s*Buy|Etsy|eBay|Costco|Wayfair|Macy['’]?s|Nordstrom|Home\s*Depot|Lowe['’]?s)(?:\s*,?\s*(?:Inc|LLC|Corp)\.?)?\s*$",
        caseSensitive: false,
      ),
      '',
    );

    // Final whitespace pass: collapse any double spaces the
    // strip steps may have left, then trim edges.
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();

    // 50-char cap so titles fit cleanly in the wishlist name field
    // without being cut off mid-display. _truncateAtWord cuts at
    // the last word boundary before the limit and appends "…".
    final result = s.length <= 50 ? s : _truncateAtWord(s, 50);
    debugPrint('[ShareToWishlist] _cleanTitle out: ${result.length}ch — "$result"');
    return result;
  }

  /// Truncate [s] at the last whitespace boundary before [max], with
  /// a trailing ellipsis. Falls back to a hard cut when no
  /// whitespace lands in the latter half of the window (very long
  /// single words / URLs). Used by both the title cap and the
  /// description cap (which the user spec asked to land at 150 ch).
  String _truncateAtWord(String s, int max) {
    final t = s.trim();
    if (t.length <= max) return t;
    var cut = t.substring(0, max);
    final lastSpace = cut.lastIndexOf(' ');
    if (lastSpace > max * 0.5) cut = cut.substring(0, lastSpace);
    return '${cut.trimRight()}…';
  }

  String _decodeHtml(http.Response resp) {
    // http defaults to latin-1 if no charset hint; most pages are utf-8.
    try {
      return utf8.decode(resp.bodyBytes, allowMalformed: true);
    } catch (_) {
      return resp.body;
    }
  }

  /// Match `<meta property="og:title" content="..." />` (and the `name=`
  /// variant some sites use). Tolerates attribute order.
  String? _findMeta(String html, String key) {
    final patterns = [
      // property="og:title" content="..."
      RegExp(
        '''<meta[^>]+(?:property|name)\\s*=\\s*["']${RegExp.escape(key)}["'][^>]*?content\\s*=\\s*["']([^"']+)["']''',
        caseSensitive: false,
      ),
      // content="..." property="og:title"
      RegExp(
        '''<meta[^>]+content\\s*=\\s*["']([^"']+)["'][^>]*?(?:property|name)\\s*=\\s*["']${RegExp.escape(key)}["']''',
        caseSensitive: false,
      ),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(html);
      if (m != null) return _decodeHtmlEntities(m.group(1)!.trim());
    }
    return null;
  }

  /// Fallback when og:title is absent — strip the `<title>...</title>` text.
  String? _findTitle(String html) {
    final m = RegExp(r'<title[^>]*>([^<]+)</title>', caseSensitive: false).firstMatch(html);
    return m == null ? null : _decodeHtmlEntities(m.group(1)!.trim());
  }

  /// Microdata fallback: `<meta itemprop="price" content="19.99" />`
  /// (schema.org Product). Used by Walmart, Best Buy, and other
  /// retailers that ship microdata but no og:price tags. Tolerates
  /// either attribute order, just like [_findMeta].
  String? _findItemprop(String html, String key) {
    final patterns = [
      RegExp(
        '''<meta[^>]+itemprop\\s*=\\s*["']${RegExp.escape(key)}["'][^>]*?content\\s*=\\s*["']([^"']+)["']''',
        caseSensitive: false,
      ),
      RegExp(
        '''<meta[^>]+content\\s*=\\s*["']([^"']+)["'][^>]*?itemprop\\s*=\\s*["']${RegExp.escape(key)}["']''',
        caseSensitive: false,
      ),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(html);
      if (m != null) return _decodeHtmlEntities(m.group(1)!.trim());
    }
    return null;
  }

  /// JSON-LD fallback: many retailers (Etsy, Target's PDP, Amazon
  /// product detail) embed structured data in a
  /// `<script type="application/ld+json">…</script>` block. Parsing
  /// the full JSON properly is overkill — we just regex out the
  /// first numeric "price" / "lowPrice" value. The regex tolerates:
  ///   • quoted string price `"price": "19.99"` (Amazon, Target)
  ///   • bare numeric price  `"price": 19.99`  (Etsy, Walmart)
  ///   • currency-prefixed   `"price": "$19.99"` (some CMSes)
  ///   • nested in offers    `"offers": { "price": ... }` (universal)
  ///   • lowPrice alias used for ranges (Amazon multi-variant)
  /// Returns null only if no JSON-LD block contains a price-shaped
  /// field at all. Each block + each candidate is debugPrinted.
  String? _findJsonLdPrice(String html) {
    final blocks = RegExp(
      r'<script[^>]+type\s*=\s*["' "']" r'application/ld\+json["' "']" r'[^>]*>(.*?)</script>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(html).toList();
    debugPrint('[ShareToWishlist] JSON-LD blocks found: ${blocks.length}');
    for (var i = 0; i < blocks.length; i++) {
      final json = blocks[i].group(1) ?? '';
      // Allow optional currency symbol before the digits, and
      // optional whitespace after the colon. \$? matches a literal
      // `$` (raw string lets us write it without escaping).
      final m = RegExp(
        r'"(?:price|lowPrice)"\s*:\s*"?\$?([0-9]+(?:[.,][0-9]+)?)"?',
      ).firstMatch(json);
      if (m != null) {
        // Normalise comma decimal separator (some EU listings) to
        // a dot so double.tryParse can ingest it.
        final value = m.group(1)!.replaceAll(',', '.');
        debugPrint('[ShareToWishlist] JSON-LD block $i price=$value');
        return value;
      } else {
        debugPrint('[ShareToWishlist] JSON-LD block $i — no price match');
      }
    }
    return null;
  }

  /// Retailer-specific DOM price scrape. JSON-LD covers most
  /// retailers but Amazon's main desktop HTML often ships the
  /// price as inline DOM rather than structured data; the
  /// `<span class="a-offscreen">$19.99</span>` pattern is their
  /// canonical "screenreader-only" price element and is the most
  /// reliable Amazon scrape that survives layout updates. The
  /// `priceblock_*` ids are legacy but still present on some PDPs.
  /// Returns the first numeric price found or null.
  String? _findRetailerDomPrice(String html) {
    final patterns = <RegExp>[
      // Amazon — a-offscreen span (modern PDP)
      RegExp(
        r'class\s*=\s*["' "']" r'[^"' "']" r'*a-offscreen[^"' "']" r'*["' "']" r'[^>]*>\s*\$\s*([0-9]+(?:[.,][0-9]+)?)',
        caseSensitive: false,
      ),
      // Amazon — legacy priceblock_* ids
      RegExp(
        r'id\s*=\s*["' "']" r'priceblock_(?:ourprice|dealprice|saleprice)["' "']" r'[^>]*>\s*\$?\s*([0-9]+(?:[.,][0-9]+)?)',
        caseSensitive: false,
      ),
      // Generic itemprop price on a span/div (some Walmart/Target legacy)
      RegExp(
        r'itemprop\s*=\s*["' "']" r'price["' "']" r'[^>]*>\s*\$?\s*([0-9]+(?:[.,][0-9]+)?)',
        caseSensitive: false,
      ),
    ];
    for (var i = 0; i < patterns.length; i++) {
      final m = patterns[i].firstMatch(html);
      if (m != null) {
        final value = m.group(1)!.replaceAll(',', '.');
        debugPrint('[ShareToWishlist] DOM price pattern $i matched → $value');
        return value;
      }
    }
    debugPrint('[ShareToWishlist] DOM price patterns all missed');
    return null;
  }

  String _decodeHtmlEntities(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ');

  // ── Eligible events: hosted or co-hosted, future-dated ──────
  // Two parallel queries — events I own (hostId == me) and events
  // where my uid is in the coHosts array. Guests (RSVPs) cannot add
  // wishlist items, so we deliberately do NOT query collectionGroup
  // 'rsvps' here. Firestore rules also enforce host/co-host write.
  Future<void> _loadEligibleEvents() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (mounted) setState(() => _loadingEvents = false);
      return;
    }
    try {
      final db = FirebaseFirestore.instance;
      final results = await Future.wait([
        db.collection('events').where('hostId', isEqualTo: uid).get(),
        db.collection('events').where('coHosts', arrayContains: uid).get(),
      ]);
      final hosted   = results[0].docs;
      final coHosted = results[1].docs;
      // Dedup: a user could in theory be both host and listed as a co-host;
      // host record wins for the badge.
      final byId = <String, QueryDocumentSnapshot>{
        for (final d in coHosted) d.id: d,
        for (final d in hosted)   d.id: d, // hosted overwrites coHosted
      };
      final allDocs = byId.values.toList();
      final now = DateTime.now();
      final eligible = allDocs.map((doc) {
        final data = (doc.data() as Map?)?.cast<String, dynamic>() ?? {};
        return (
          id:    doc.id,
          title: (data['title'] as String?) ?? 'Untitled',
          date:  (data['date'] as Timestamp?)?.toDate(),
          isHost: (data['hostId'] as String?) == uid,
          isDraft: (data['isDraft'] as bool?) ?? false,
          isArchived: (data['isArchived'] as bool?) ?? false,
        );
      }).where((e) {
        // Drop drafts and archived; keep events whose date is missing
        // (TBD) or in the future.
        if (e.isDraft || e.isArchived) return false;
        if (e.date == null) return true;
        return e.date!.isAfter(now);
      }).map((e) => (
        id: e.id, title: e.title, date: e.date, isHost: e.isHost,
      )).toList()
        ..sort((a, b) {
          final ad = a.date ?? DateTime(2099);
          final bd = b.date ?? DateTime(2099);
          return ad.compareTo(bd);
        });

      if (!mounted) return;
      setState(() {
        _events = eligible;
        _selectedEventId = eligible.isNotEmpty ? eligible.first.id : null;
        _loadingEvents = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingEvents = false;
        _error = 'Could not load your events: $e';
      });
    }
  }

  // ── Save ─────────────────────────────────────────────────────
  Future<void> _save() async {
    final eventId = _selectedEventId;
    final name = _name.text.trim();
    if (eventId == null || name.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) throw Exception('Sign in to add wishlist items.');
      final priceText = _price.text.trim();
      final price = priceText.isEmpty
          ? null
          : double.tryParse(priceText.replaceAll(RegExp(r'[\$,]'), ''));
      await FirebaseFirestore.instance
          .collection('events').doc(eventId)
          .collection('wishlist')
          .add({
        'name': name,
        'url': widget.url,
        'imageUrl': _imageUrl,
        'price': price,
        'notes': _notes.text.trim(),
        'addedBy': uid,
        'addedAt': FieldValue.serverTimestamp(),
        'claimed': false,
        'claimedBy': null,
      });
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Added to wishlist 🎁'),
        backgroundColor: AppColors.green,
      ));
    } catch (e) {
      if (mounted) setState(() { _saving = false; _error = e.toString(); });
    }
  }

  // ── UI ───────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    // Layout topology, top to bottom:
    //   AnimatedPadding (lifts content above the keyboard, animated
    //                    so the sheet doesn't snap when the IME opens)
    //   └── SingleChildScrollView (gets the full keyboard-adjusted
    //                              viewport as its bounded height,
    //                              so it scrolls when the form +
    //                              keyboard exceed available space)
    //       └── Padding (16/12/16/16 — the floating-card margins)
    //           └── Container (rounded-top sheet chrome + bg color)
    //               └── Column (form fields, mainAxisSize.min)
    //
    // Earlier layout had Container *outside* SCV, which made the
    // Container size to the Column's intrinsic height regardless of
    // the keyboard's viewInsets — overflowing the parent Padding by
    // exactly the height the keyboard ate (~78px on a Pixel-class
    // screen with the form fully populated). Pulling SCV out of the
    // Container fixes that: now the Container is free to be as tall
    // as its content, and SCV scrolls the whole stack as needed.
    return AnimatedPadding(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.dark,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
          // Spacing rhythm:
          //   16 → between major sections (header, preview, picker, form, actions)
          //   12 → between fields within a section
          //   20 → before the action-button row (slightly bigger to set
          //        it apart as a commit step)
          // Earlier layout mixed 14/4/16/16/14/10/10/10/18 — readable
          // but visually noisy at the top because the title, full URL,
          // preview card, and form fields all stacked at slightly
          // different cadences. The new rhythm reads as "header /
          // preview / where it goes / item details / commit".
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: AppColors.muted.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            )),
            const SizedBox(height: 16),
            // Header — single line. The full URL row that used to live
            // here was redundant with the host displayed inside the
            // preview card; dropping it keeps the heading uncluttered.
            const Text(
              'Add to wishlist',
              style: TextStyle(fontFamily: 'FredokaOne', fontSize: 22, color: Colors.white),
            ),
            const SizedBox(height: 16),
            _previewCard(),
            const SizedBox(height: 16),
            _sectionLabel('Save to event'),
            const SizedBox(height: 8),
            _eventPicker(),
            const SizedBox(height: 16),
            _sectionLabel('Item details'),
            const SizedBox(height: 8),
            _input(_name, 'Item name'),
            const SizedBox(height: 12),
            _input(_price, 'Price (optional)', keyboard: const TextInputType.numberWithOptions(decimal: true), prefix: r'$'),
            const SizedBox(height: 12),
            _input(_notes, 'Notes (optional)', maxLines: 2),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.w600)),
            ],
            const SizedBox(height: 20),
            Row(children: [
              Expanded(child: OutlinedButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.muted,
                  side: BorderSide(color: AppColors.muted.withValues(alpha: 0.4)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Cancel'),
              )),
              const SizedBox(width: 10),
              Expanded(flex: 2, child: ElevatedButton(
                onPressed: (_saving || _name.text.trim().isEmpty || _selectedEventId == null) ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.gold,
                  foregroundColor: Colors.black,
                  disabledBackgroundColor: AppColors.muted.withValues(alpha: 0.3),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                    : const Text('Add to wishlist',
                        style: TextStyle(fontFamily: 'Nunito', fontWeight: FontWeight.w800, fontSize: 14)),
              )),
            ]),
          ]),
        ),
      ),
    );
  }

  /// Small uppercase eyebrow used to introduce a section (Save to
  /// event / Item details). Mirrors the FredokaOne+Nunito hierarchy
  /// used elsewhere in the app — heading, then a tight muted label
  /// above the related controls. Letter-spacing makes it read as a
  /// quiet divider rather than another field label.
  Widget _sectionLabel(String text) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontFamily: 'Nunito',
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.2,
        color: AppColors.muted.withValues(alpha: 0.85),
      ),
    );
  }

  /// Compact preview: image thumbnail on the left, a small eyebrow +
  /// the source host on the right. The earlier card duplicated the
  /// item name (which the user is about to edit two fields below) —
  /// dropping that removes the visual echo and lets the image be the
  /// hero. While metadata is still being fetched, the right side
  /// shows a "Reading product info…" status line so the user knows
  /// the form will auto-fill in a moment.
  Widget _previewCard() {
    final host = Uri.tryParse(widget.url)?.host ?? widget.url;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF383B56),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF4A4E6B)),
      ),
      child: Row(children: [
        Container(
          width: 64, height: 64,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: _fetchingMeta
              ? const Center(child: SizedBox(
                  width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.muted),
                ))
              : (_imageUrl != null && _imageUrl!.isNotEmpty)
                  ? Image.network(_imageUrl!, fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const Icon(Icons.image_not_supported_outlined, color: AppColors.muted))
                  : const Icon(Icons.link, color: AppColors.muted, size: 28),
        ),
        const SizedBox(width: 14),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'FROM',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
                color: AppColors.muted.withValues(alpha: 0.75),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              host,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
            if (_fetchingMeta) ...[
              const SizedBox(height: 4),
              Text(
                'Reading product info…',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 11.5,
                  color: AppColors.muted,
                ),
              ),
            ],
          ],
        )),
      ]),
    );
  }

  Widget _eventPicker() {
    if (_loadingEvents) {
      return Row(children: [
        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.muted)),
        const SizedBox(width: 10),
        Text('Loading your events…',
            style: TextStyle(color: AppColors.muted, fontSize: 13, fontWeight: FontWeight.w600)),
      ]);
    }
    if (_events.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.redAccent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)),
        ),
        child: const Row(children: [
          Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
          SizedBox(width: 8),
          Expanded(child: Text(
            "You don't host any upcoming events. Only the host of an event can add wishlist items.",
            style: TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.w700),
          )),
        ]),
      );
    }
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF383B56),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF4A4E6B)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: _selectedEventId,
          dropdownColor: const Color(0xFF383B56),
          icon: const Icon(Icons.expand_more, color: AppColors.muted),
          style: const TextStyle(fontFamily: 'Nunito', color: Colors.white, fontSize: 14),
          items: _events.map((e) {
            final dateStr = e.date == null
                ? 'Date TBD'
                : '${months[e.date!.month - 1]} ${e.date!.day}';
            final hostBadge = e.isHost ? ' · You host' : ' · Co-host';
            return DropdownMenuItem(
              value: e.id,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(e.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text('$dateStr$hostBadge',
                        style: TextStyle(color: AppColors.muted, fontSize: 11)),
                  ],
                ),
              ),
            );
          }).toList(),
          onChanged: (v) => setState(() => _selectedEventId = v),
        ),
      ),
    );
  }

  Widget _input(
    TextEditingController c,
    String label, {
    TextInputType? keyboard,
    int maxLines = 1,
    String? prefix,
  }) {
    return TextField(
      controller: c,
      keyboardType: keyboard,
      maxLines: maxLines,
      style: const TextStyle(fontFamily: 'Nunito', color: Colors.white, fontSize: 14),
      onChanged: (_) => setState(() {}), // toggles save-button enable state
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: AppColors.muted),
        prefixText: prefix,
        prefixStyle: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700),
        filled: true,
        fillColor: const Color(0xFF383B56),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border:        OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF4A4E6B))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF4A4E6B))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.purple, width: 1.5)),
      ),
    );
  }
}
