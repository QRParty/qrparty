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

      if (resp.statusCode >= 200 && resp.statusCode < 400) {
        final body = _decodeHtml(resp);
        final title = _findMeta(body, 'og:title') ?? _findTitle(body);
        final image = _findMeta(body, 'og:image');
        if (mounted) {
          setState(() {
            if (title != null && _name.text.isEmpty) _name.text = title;
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
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.dark,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: AppColors.muted.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            )),
            const SizedBox(height: 14),
            const Text(
              'Add to wishlist',
              style: TextStyle(fontFamily: 'FredokaOne', fontSize: 22, color: Colors.white),
            ),
            const SizedBox(height: 4),
            Text(
              widget.url,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Nunito', fontSize: 12, color: AppColors.muted, fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            _previewCard(),
            const SizedBox(height: 16),
            _eventPicker(),
            const SizedBox(height: 14),
            _input(_name, 'Item name'),
            const SizedBox(height: 10),
            _input(_price, 'Price (optional)', keyboard: const TextInputType.numberWithOptions(decimal: true), prefix: r'$'),
            const SizedBox(height: 10),
            _input(_notes, 'Notes (optional)', maxLines: 2),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.w600)),
            ],
            const SizedBox(height: 18),
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

  Widget _previewCard() {
    return Container(
      padding: const EdgeInsets.all(12),
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
            borderRadius: BorderRadius.circular(10),
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
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            _fetchingMeta
                ? 'Reading product info…'
                : (_name.text.isEmpty ? 'Type a name below' : _name.text),
            maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Nunito', fontSize: 13.5, fontWeight: FontWeight.w800, color: Colors.white,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            Uri.tryParse(widget.url)?.host ?? widget.url,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: 'Nunito', fontSize: 11, color: AppColors.muted),
          ),
        ])),
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
