import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:gal/gal.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import '../utils.dart';
import '../models/merch_order.dart';
import '../services/merch_order_service.dart';
import '../widgets/theme_card.dart';
import '../widgets/invitation_preview.dart';

// Theme-aware palette. The State class reads these via getters that pick
// dark / light based on Theme.of(context). `_purple` and `_gold` look
// fine on either background so they stay tier-neutral.
const _bgDark      = Color(0xFF2D3047);
const _bgLight     = Color(0xFFF8F7FC);
const _cardDark    = Color(0xFF383B56);
const _cardLight   = Colors.white;
const _borderDark  = Color(0xFF4A4E6B);
const _borderLight = Color(0xFFE0E8E0);
const _mutedDark   = Color(0xFFA9A6B8);
const _mutedLight  = Color(0xFF8892A4);
const _purple      = Color(0xFF9C7FD4);
const _gold        = Color(0xFFC8922A);

/// Theme catalog keys allowed when the birthday sub-category is Kids.
/// Mirrors the Phase 1 themed designs in invitation_preview.dart — keep
/// these in sync with [_kidsThemeFromKey] there.
const _kidsAllowedThemeKeys = <String>{
  'dinosaur', 'space', 'unicorn', 'sports',
  'animals', 'circus', 'mermaids', 'princess',
};

class OrderMerchScreen extends StatefulWidget {
  final String eventId;
  final String eventTitle;
  final String hostName;
  final DateTime? eventDate;
  final MerchProduct initialProduct;
  /// Event-type name from the source event doc (e.g. 'Birthday', 'Wedding').
  /// Drives the optional age-range sub-selector before theme picking.
  final String? eventType;
  /// 6-char short code stamped on the event doc at creation. Forwarded to
  /// the invitation preview so it can render the typeable fallback URL.
  final String? shortCode;

  const OrderMerchScreen({
    super.key,
    required this.eventId,
    required this.eventTitle,
    required this.hostName,
    required this.initialProduct,
    this.eventDate,
    this.eventType,
    this.shortCode,
  });

  @override
  State<OrderMerchScreen> createState() => _OrderMerchScreenState();
}

class _OrderMerchScreenState extends State<OrderMerchScreen> {
  // Step kinds — listed in the order they appear when ALL are present.
  // The actual flow filters this list (see [_steps]) so birthday-only steps
  // can be skipped entirely for other event types.
  // _step indexes into _steps; values >= _steps.length mean "confirmation".
  int _step = 0;
  late final MerchProduct _product = widget.initialProduct;

  /// Optional birthday sub-category — only collected when the event type
  /// is birthday. Mirrors Vistaprint's birthday catalog so the print
  /// template can be picked once category-specific designs land. Today
  /// the picker still shows the same 8 themes regardless of selection.
  _BirthdaySubCategory? _birthdaySubCategory;

  // Theme selection — Classic is the safe default and ships with no extra
  // setup. Custom uploads were removed per spec; we're not a print service.
  String _themeKey = 'classic';
  int _themeVariant = 0;

  // Pack
  int? _packSize;

  // Address
  final _name  = TextEditingController();
  final _line1 = TextEditingController();
  final _line2 = TextEditingController();
  final _city  = TextEditingController();
  String? _stateAbbr;
  final _zip   = TextEditingController();

  // 50 US states + DC. The shipping form is US-only today (see _stepAddress
  // copy), so this is the canonical pick list. Two-letter abbreviations are
  // what gets stored on the order doc + sent to the print fulfillment vendor.
  static const _usStates = <String>[
    'AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA',
    'HI','ID','IL','IN','IA','KS','KY','LA','ME','MD',
    'MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ',
    'NM','NY','NC','ND','OH','OK','OR','PA','RI','SC',
    'SD','TN','TX','UT','VT','VA','WA','WV','WI','WY',
    'DC',
  ];

  MerchShipping _shipping = MerchShipping.standard;

  // Stripe card form on the summary step. The controller's details.complete
  // gates the Pay button via _canContinue. A listener in initState forces
  // a rebuild on every card-field edit so the gate is reactive — without
  // it _canContinue is only re-evaluated when something else triggers a
  // setState, which would leave Pay disabled after a valid card is typed.
  final _cardController = CardFormEditController();

  bool _placing = false;
  String? _orderId;
  DateTime? _estDelivery;

  // Theme-aware palette getters. Resolve dark vs light variant from
  // Theme.of(context). Mirrors the pattern used in business_home_feed_screen
  // / generate_qr_screen — the order flow used to be hardcoded dark only,
  // which made it stand out as a black surface inside a light-themed app.
  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;
  Color get _fg     => _isDark ? Colors.white : AppColors.dark;

  String _accountTier = 'personal';
  // Cached for the invitation preview when the user is on Business Plus.
  // Falls back to the QR Party wordmark inside InvitationPreviewSheet if null.
  String? _orgLogoUrl;

  // Resolved short code for the invitation preview's typeable URL line.
  // Seeded from widget.shortCode if the caller passed one (the
  // generate_qr_screen path does); otherwise fetched from the event doc
  // in [_resolveShortCode] so the popup-from-create-event path lands on
  // an identical preview. Without this, the popup-launched preview was
  // missing the partywithqr.com/event/XXXXXX line that the QR-page-launched
  // preview always shows — same screen, two different visuals.
  String? _shortCode;

  // ── Vistaprint hand-off (invitations only) ───────────────────
  // Anchors the QR repaint boundary in the invitation flow so we can
  // capture pixels for the "Download QR Code" button. Sticker flow
  // never reads this — it doesn't render a capturable QR on screen.
  final GlobalKey _vistaprintQrKey = GlobalKey();
  bool _busyQrDownload = false;

  @override
  void initState() {
    super.initState();
    _shortCode = widget.shortCode;
    _loadAccountTierAndPrefill();
    if (_shortCode == null || _shortCode!.isEmpty) {
      _resolveShortCode();
    }
    // Force the bottom bar to re-evaluate _canContinue() each time the
    // card form updates so the Pay button enables as soon as the card
    // becomes complete.
    _cardController.addListener(_onCardChanged);
  }

  void _onCardChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _resolveShortCode() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('events').doc(widget.eventId).get();
      if (!mounted) return;
      final code = snap.data()?['shortCode'] as String?;
      if (code != null && code.isNotEmpty) {
        setState(() => _shortCode = code);
      }
    } catch (_) {/* preview falls back to no typeable URL — non-fatal */}
  }

  @override
  void dispose() {
    _name.dispose(); _line1.dispose(); _line2.dispose();
    _city.dispose(); _zip.dispose();
    _cardController.removeListener(_onCardChanged);
    _cardController.dispose();
    super.dispose();
  }

  Future<void> _loadAccountTierAndPrefill() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final snap = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    if (!mounted) return;
    final data = snap.data() ?? {};
    final acct = data['accountType'] as String?;
    final tier = (acct == 'business' || acct == 'businessPlus') ? acct! : 'personal';
    setState(() => _accountTier = tier);
    final addr = data['shippingAddress'] as Map<String, dynamic>?;
    if (addr != null) {
      _name.text  = (addr['name']  as String?) ?? '';
      _line1.text = (addr['line1'] as String?) ?? '';
      _line2.text = (addr['line2'] as String?) ?? '';
      _city.text  = (addr['city']  as String?) ?? '';
      final addrState = (addr['state'] as String?)?.toUpperCase();
      _stateAbbr = (addrState != null && _usStates.contains(addrState)) ? addrState : null;
      _zip.text   = (addr['zip']   as String?) ?? '';
    }

    // Business Plus accounts get the org logo on their invitation preview.
    // One read here is cheaper than re-fetching every time the sheet opens.
    if (tier == 'businessPlus') {
      try {
        final orgQuery = await FirebaseFirestore.instance
            .collection('organizations')
            .where('ownerId', isEqualTo: uid)
            .limit(1)
            .get();
        if (!mounted) return;
        if (orgQuery.docs.isNotEmpty) {
          setState(() => _orgLogoUrl = orgQuery.docs.first.data()['logoUrl'] as String?);
        }
      } catch (_) {/* silent — preview falls back to wordmark */}
    }
  }

  MerchAddress get _address => MerchAddress(
    name:  _name.text.trim(),
    line1: _line1.text.trim(),
    line2: _line2.text.trim(),
    city:  _city.text.trim(),
    state: _stateAbbr ?? '',
    zip:   _zip.text.trim(),
  );

  int get _subtotalCents =>
      _packSize == null ? 0 : (MerchPricing.subtotalCents(product: _product, packSize: _packSize!) ?? 0);
  int get _shippingCents => MerchPricing.shippingCents(_shipping);
  int get _totalCents => _subtotalCents + _shippingCents;

  String get _productLabel => _product == MerchProduct.invitation ? 'Invitations' : 'Stickers';

  bool get _isBirthday =>
      (widget.eventType ?? '').toLowerCase() == 'birthday';

  // ── Vistaprint hand-off for invitations ──────────────────────
  /// Vistaprint catalog landing page for invitations. Previously
  /// branched per event type (birthday / wedding / baby shower /
  /// generic party) but Vistaprint retired the per-category URLs and
  /// every old path now 404s; the single /cards-stationery/invitations
  /// page is the working entry point. Function shape preserved so
  /// callers don't need to change and so per-type branching can be
  /// restored if Vistaprint brings the category URLs back.
  String _vistaprintUrlForEventType() {
    return 'https://www.vistaprint.com/cards-stationery/invitations';
  }

  /// Captures the rendered QR widget (via the [_vistaprintQrKey]
  /// RepaintBoundary) as a 3×-density PNG and writes it to the device
  /// gallery via Gal. Mirrors the same capture pipeline used in
  /// generate_qr_screen.dart and organization_screen.dart so a host
  /// who's already saved an event QR there gets the exact same image
  /// in their photos. Requests gallery permission lazily — the
  /// permission prompt only fires the first time on iOS / on Android
  /// 13+.
  Future<void> _downloadQrToGallery() async {
    if (_busyQrDownload) return;
    setState(() => _busyQrDownload = true);
    try {
      final boundary = _vistaprintQrKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) throw Exception('QR not ready — please try again');
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData?.buffer.asUint8List();
      if (bytes == null) throw Exception('Could not capture QR image');
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) throw Exception('Gallery access denied');
      }
      // Filename built from a safe-ASCII slug of the event title so the
      // saved file is recognisable in Photos / Files. Falls back to the
      // eventId when the title is empty / all-symbols.
      final safeName = widget.eventTitle
          .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
          .toLowerCase();
      final name = safeName.isEmpty
          ? 'qrparty_event_${widget.eventId}'
          : 'qrparty_$safeName';
      await Gal.putImageBytes(bytes, name: name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('📸 QR code saved to your photos. Add it to your Vistaprint design next!'),
          backgroundColor: AppColors.green,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not save QR: $e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _busyQrDownload = false);
    }
  }

  /// Hands off to the device's default browser with the right Vistaprint
  /// catalog URL. externalApplication mode (rather than
  /// inAppBrowserView) keeps Vistaprint's session / cart / design
  /// state in the user's real browser — they almost certainly already
  /// have an account there and want everything persisted across the
  /// long design session.
  Future<void> _launchVistaprint() async {
    final url = _vistaprintUrlForEventType();
    final uri = Uri.parse(url);
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not open Vistaprint. Copy this URL: $url'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to open browser: $e'),
          backgroundColor: Colors.redAccent,
        ));
      }
    }
  }

  /// Sub-categories that use the Kids theme set + Phase 1 themed previews.
  /// Currently kids and firstBirthday share the same designs; centralised
  /// here so `_stepTheme`, the subcategory-tile reset, and the preview
  /// dispatch all stay in agreement.
  bool _kidsThemesFor(_BirthdaySubCategory? c) =>
      c == _BirthdaySubCategory.kids
          || c == _BirthdaySubCategory.firstBirthday;

  /// Steps that are part of the interactive flow (excludes confirmation).
  /// Birthday events get an extra age-range step before theme selection.
  /// Stickers skip the theme + birthdaySubCategory steps entirely — those
  /// only drive the invitation art catalog, and stickers ship with the QR
  /// over a fixed brand mark regardless of theme.
  List<_StepKind> get _steps => [
    if (_isBirthday && _product == MerchProduct.invitation) _StepKind.birthdaySubCategory,
    if (_product == MerchProduct.invitation) _StepKind.theme,
    _StepKind.pack,
    _StepKind.address,
    _StepKind.shipping,
    _StepKind.summary,
  ];

  /// Resolves the current `_step` int into a step kind. Out-of-range
  /// indices (post-order) collapse to confirmation.
  _StepKind get _currentStep =>
      _step < _steps.length ? _steps[_step] : _StepKind.confirmation;

  String _stepEyebrowText() => 'Step ${_step + 1} of ${_steps.length}';

  bool _canContinue() {
    switch (_currentStep) {
      case _StepKind.birthdaySubCategory: return _birthdaySubCategory != null;
      case _StepKind.theme:    return _themeKey.isNotEmpty;
      case _StepKind.pack:     return _packSize != null;
      case _StepKind.address:  return _address.isComplete;
      case _StepKind.summary:  return _cardController.details.complete;
      case _StepKind.shipping:
      case _StepKind.confirmation:
        return true;
    }
  }

  void _next() { if (_canContinue() && _step < _steps.length - 1) setState(() => _step++); }
  void _back() { if (_step > 0) setState(() => _step--); }

  Future<void> _saveAddressToProfile() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'shippingAddress': _address.toMap(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  Future<void> _placeOrder() async {
    if (_placing || _packSize == null) return;
    setState(() => _placing = true);
    try {
      final clientSecret = await MerchOrderService.createPaymentIntent(_totalCents);
      final paymentIntentId = await MerchOrderService.confirmPayment(
        clientSecret: clientSecret, billingAddress: _address,
      );

      await _saveAddressToProfile();

      final res = await MerchOrderService.createOrder(
        eventId: widget.eventId,
        productType: _product,
        packSize: _packSize!,
        themeKey: _themeKey,
        themeVariant: _themeVariant,
        shippingAddress: _address,
        shippingSpeed: _shipping,
        paymentIntentId: paymentIntentId,
      );
      if (!mounted) return;
      _orderId = res['orderId'] as String?;
      final estTs = res['estimatedDelivery'];
      if (estTs is int) {
        _estDelivery = DateTime.fromMillisecondsSinceEpoch(estTs);
      } else {
        // 3 processing + standard 5–7 / expedited 2–3
        final ship = _shipping == MerchShipping.expedited ? 3 : 7;
        _estDelivery = DateTime.now().add(Duration(days: 3 + ship));
      }
      setState(() => _step = _steps.length);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Order failed: $e'), backgroundColor: Colors.redAccent,
        ));
      }
    } finally {
      if (mounted) setState(() => _placing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Invitation flow: skip the multi-step Stripe path entirely and
    // hand off to Vistaprint. The host downloads their event QR, then
    // launches Vistaprint's catalog page in the system browser and
    // designs the card there. The multi-step Stripe / themed-print
    // flow below is retained ONLY for stickers — which we still
    // fulfill in-house via createMerchOrder + the Phase 3 print
    // renderer.
    if (_product == MerchProduct.invitation) {
      return _buildInvitationVistaprintFlow();
    }
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: Icon(Icons.close, color: _fg),
          onPressed: () => Navigator.of(context).pop(_orderId),
        ),
        title: Text('Order $_productLabel',
            style: TextStyle(color: _fg, fontWeight: FontWeight.w700, fontSize: 17)),
      ),
      body: SafeArea(
        child: Column(children: [
          if (_currentStep != _StepKind.confirmation) _progressBar(),
          Expanded(child: _buildStep()),
          // Variant selector is pinned ABOVE the Continue bar on the theme
          // step so it stays visible no matter how far the grid is scrolled.
          if (_currentStep == _StepKind.theme) _pinnedVariantBar(),
          if (_currentStep != _StepKind.confirmation) _bottomBar(),
        ]),
      ),
    );
  }

  /// Vistaprint hand-off screen body. Visually a focused "bottom-sheet
  /// style" card (rounded top, handle bar, brand pill, explanation,
  /// QR preview, two CTAs) filling the screen so we don't have to
  /// stack a modal over the screen the caller just pushed.
  ///
  /// The QR rendered here is wrapped in a [RepaintBoundary] keyed by
  /// [_vistaprintQrKey] so [_downloadQrToGallery] can capture and
  /// save the exact pixels the host previews. The QR's data string
  /// mirrors `_eventQrUrl(shortCode)` from invitation_preview.dart —
  /// same canonical short-code URL the in-app preview encodes.
  Widget _buildInvitationVistaprintFlow() {
    final code = _shortCode;
    final qrData = (code != null && code.isNotEmpty)
        ? 'https://partywithqr.com/event/$code'
        : null;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: Icon(Icons.close, color: _fg),
          onPressed: () => Navigator.of(context).pop(_orderId),
        ),
        title: Text('Order Invitations',
            style: TextStyle(color: _fg, fontWeight: FontWeight.w700, fontSize: 17)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _border),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // Handle bar — mirrors the visual signature of a modal
              // bottom sheet so the screen reads as a focused dialog
              // rather than another full step in the flow.
              Center(child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: _border,
                  borderRadius: BorderRadius.circular(2),
                ),
              )),
              const SizedBox(height: 18),
              // Vistaprint hero badge — orange/red brand-ish stripe so
              // the user understands they're handing off, not finishing
              // an in-app purchase.
              Center(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _gold.withValues(alpha: 0.45)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.print_outlined, size: 16, color: _gold),
                  const SizedBox(width: 6),
                  Text('VISTAPRINT',
                      style: TextStyle(
                        color: _gold, fontSize: 11,
                        fontWeight: FontWeight.w800, letterSpacing: 1.4,
                      )),
                ]),
              )),
              const SizedBox(height: 16),
              Text('Design your invitation',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: 'FredokaOne', fontSize: 24, color: _fg)),
              const SizedBox(height: 8),
              Text(
                "You'll design your invitation on Vistaprint. Download your "
                "event's QR code first to add it to your design.",
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted, fontSize: 13.5, height: 1.55),
              ),
              const SizedBox(height: 22),
              // QR preview, wrapped in a RepaintBoundary so we can
              // capture pixels for "Download QR Code". The
              // `_shortCode == null` window can briefly show a blank
              // placeholder while _resolveShortCode resolves; the
              // Download button is disabled in that state.
              Center(
                child: RepaintBoundary(
                  key: _vistaprintQrKey,
                  child: Container(
                    width: 180, height: 180,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _border),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 14, offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: qrData != null
                        ? QrImageView(
                            data: qrData,
                            version: QrVersions.auto,
                            backgroundColor: Colors.white,
                          )
                        : const Center(child: CircularProgressIndicator(
                            color: _purple, strokeWidth: 2,
                          )),
                  ),
                ),
              ),
              if (qrData != null) ...[
                const SizedBox(height: 8),
                Center(child: Text(
                  'partywithqr.com/event/$code',
                  style: TextStyle(
                    color: _muted, fontSize: 11,
                    fontFamily: 'Nunito', fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                )),
              ],
              const SizedBox(height: 22),
              // Download QR — outlined / secondary so Continue reads
              // as the primary action. Disabled while the QR is still
              // resolving or a save is in flight.
              SizedBox(
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: (qrData == null || _busyQrDownload)
                      ? null
                      : _downloadQrToGallery,
                  icon: _busyQrDownload
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(color: _purple, strokeWidth: 2))
                      : const Icon(Icons.download_outlined, size: 18),
                  label: Text(
                    _busyQrDownload ? 'Saving…' : 'Download QR Code',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _purple,
                    side: const BorderSide(color: _purple, width: 1.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // Continue to Vistaprint — primary action.
              SizedBox(
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: _launchVistaprint,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text(
                    'Continue to Vistaprint',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _purple,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Footnote — sets expectations so users don't expect
              // Vistaprint orders to surface in QR Party's order list.
              Text(
                "Orders + tracking happen on Vistaprint. We'll keep your "
                "event QR ready for you.",
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted, fontSize: 11.5, height: 1.5),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _progressBar() {
    final n = _steps.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
      child: Row(children: List.generate(n, (i) {
        final filled = i <= _step;
        return Expanded(child: Container(
          margin: EdgeInsets.only(right: i < n - 1 ? 4 : 0),
          height: 4,
          decoration: BoxDecoration(
            color: filled ? _purple : _border,
            borderRadius: BorderRadius.circular(2),
          ),
        ));
      })),
    );
  }

  Widget _bottomBar() {
    final canGo = _canContinue();
    final isFinal = _currentStep == _StepKind.summary;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: _border))),
      child: Row(children: [
        if (_step > 0)
          OutlinedButton(
            onPressed: _placing ? null : _back,
            style: OutlinedButton.styleFrom(
              foregroundColor: _muted, side: BorderSide(color: _border),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Back'),
          ),
        if (_step > 0) const SizedBox(width: 10),
        Expanded(
          child: ElevatedButton(
            onPressed: !canGo || _placing ? null : (isFinal ? _placeOrder : _next),
            style: ElevatedButton.styleFrom(
              backgroundColor: isFinal ? _gold : _purple,
              foregroundColor: isFinal ? Colors.black : Colors.white,
              disabledBackgroundColor: _border, disabledForegroundColor: _muted,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: _placing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : Text(
                    isFinal
                        ? (kTestingMode ? 'Place test order' : 'Pay ${MerchPricing.format(_totalCents)}')
                        : 'Continue',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
          ),
        ),
      ]),
    );
  }

  Widget _buildStep() => switch (_currentStep) {
    _StepKind.birthdaySubCategory => _stepBirthdaySubCategory(),
    _StepKind.theme        => _stepTheme(),
    _StepKind.pack         => _stepPack(),
    _StepKind.address      => _stepAddress(),
    _StepKind.shipping     => _stepShipping(),
    _StepKind.summary      => _stepSummary(),
    _StepKind.confirmation => _stepConfirmation(),
  };

  // ── Birthday-only: sub-category ──────────────────────────────
  Widget _stepBirthdaySubCategory() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: [
        _eyebrow(_stepEyebrowText()),
        _title('What kind of birthday?'),
        _desc('Pick the closest match — we\'ll tailor the design on the next step.'),
        const SizedBox(height: 18),
        for (final c in _BirthdaySubCategory.values) _subCategoryTile(c),
      ],
    );
  }

  Widget _subCategoryTile(_BirthdaySubCategory c) {
    final selected = _birthdaySubCategory == c;
    return GestureDetector(
      onTap: () => setState(() {
        _birthdaySubCategory = c;
        // Switching INTO a Kids-theme-set category (kids or firstBirthday)
        // with a non-Kids theme selected (default 'classic') would leave the
        // picker showing no selection. Reset to the first Kids-allowed theme
        // so the next step opens valid.
        if (_kidsThemesFor(c)
            && !_kidsAllowedThemeKeys.contains(_themeKey)) {
          _themeKey = 'dinosaur';
          _themeVariant = 0;
        }
      }),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _card, borderRadius: BorderRadius.circular(16),
          border: Border.all(color: selected ? _purple : _border, width: selected ? 1.6 : 1),
        ),
        child: Row(children: [
          Container(
            width: 22, height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: selected ? _purple : _border, width: 2),
              color: selected ? _purple : Colors.transparent,
            ),
            child: selected ? const Icon(Icons.check, color: Colors.white, size: 14) : null,
          ),
          const SizedBox(width: 14),
          Text(c.emoji, style: const TextStyle(fontSize: 26)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              c.label,
              style: TextStyle(
                fontFamily: 'FredokaOne',
                color: _fg, fontSize: 17, height: 1.1,
              ),
            ),
          ),
        ]),
      ),
    );
  }

  // ── Step: theme ──────────────────────────────────────────────
  Widget _stepTheme() {
    // Kids and 1st Birthday sub-categories restrict the catalog to the 8
    // themes that have Phase 1 designs in invitation_preview.dart. Everyone
    // else sees the full set.
    final showKidsOnly = _isBirthday && _kidsThemesFor(_birthdaySubCategory);
    final themes = showKidsOnly
        ? merchThemes.where((t) => _kidsAllowedThemeKeys.contains(t.key)).toList(growable: false)
        : merchThemes;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: [
        _eyebrow(_stepEyebrowText()),
        _title('Pick a theme'),
        _desc('All theme art is original. Pick from ${themes.length} built-in themes — each comes with three color variants.'),
        const SizedBox(height: 18),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          // 0.7 ≈ 4/6 invitation aspect — gives each tile enough vertical
          // room to render the full mini design instead of cropping it.
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.7,
          ),
          itemCount: themes.length,
          itemBuilder: (_, i) {
            final t = themes[i];
            return ThemeCard(
              theme: t,
              variantIndex: t.key == _themeKey ? _themeVariant : 0,
              selected: t.key == _themeKey,
              isKidsBirthday: showKidsOnly,
              onTap: () => setState(() {
                _themeKey = t.key;
                _themeVariant = 0;
              }),
            );
          },
        ),
      ],
    );
  }

  /// Variant chooser pinned at the bottom of the theme step. Sits above
  /// `_bottomBar` and below the scrollable grid so it stays visible no
  /// matter how far the user has scrolled.
  Widget _pinnedVariantBar() {
    final theme = themeByKey(_themeKey);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      decoration: BoxDecoration(
        color: _bg,
        border: Border(top: BorderSide(color: _border)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${theme.name.toUpperCase()} VARIANT',
            style: TextStyle(color: _muted, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
        const SizedBox(height: 8),
        Row(children: [
          for (int i = 0; i < theme.variants.length; i++) ...[
            Expanded(child: GestureDetector(
              onTap: () => setState(() => _themeVariant = i),
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: theme.variants[i].bg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _themeVariant == i ? _gold : _border,
                    width: _themeVariant == i ? 2 : 1,
                  ),
                ),
                child: Center(
                  child: Text(theme.variants[i].name,
                      style: TextStyle(
                        color: theme.variants[i].text, fontSize: 12,
                        fontWeight: FontWeight.w800, letterSpacing: 0.5,
                      )),
                ),
              ),
            )),
            if (i < theme.variants.length - 1) const SizedBox(width: 8),
          ],
        ]),
      ]),
    );
  }

  // ── Step 1: pack ──────────────────────────────────────────────
  Widget _stepPack() {
    final sizes = MerchPricing.packsFor(_product);
    final isKidsBirthday = _isBirthday && _kidsThemesFor(_birthdaySubCategory);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: [
        _eyebrow(_stepEyebrowText()),
        _title('How many?'),
        _desc(_product == MerchProduct.invitation
            ? 'Invitations ship as 4×6 cards with envelopes.'
            : 'Stickers ship pre-printed on a single sheet, ready to peel.'),
        // Show a blank preview of the chosen theme above the pack tiles so
        // the user sees what their invitation looks like before committing
        // to a pack size. Stickers skip this — their preview is trivial.
        if (_product == MerchProduct.invitation) ...[
          const SizedBox(height: 16),
          Center(
            child: SizedBox(
              width: 220,
              child: AspectRatio(
                aspectRatio: 4 / 6,
                child: ThemeMiniPreview(
                  theme: themeByKey(_themeKey),
                  variantIndex: _themeVariant,
                  isKidsBirthday: isKidsBirthday,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: Text(
              'Preview · ${themeByKey(_themeKey).name}',
              style: TextStyle(
                fontFamily: 'Nunito', fontSize: 11, fontWeight: FontWeight.w700,
                color: _muted, letterSpacing: 1.2,
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        for (final s in sizes) _packTile(s),
      ],
    );
  }

  Widget _packTile(int size) {
    final cents = MerchPricing.subtotalCents(product: _product, packSize: size);
    final selected = _packSize == size;
    return GestureDetector(
      onTap: () {
        setState(() => _packSize = size);
        // Invitations get a "what will this look like?" sheet on every pack
        // tap. Stickers don't — their preview is already trivial (QR + brand).
        if (_product == MerchProduct.invitation) {
          _showInvitationPreview(size);
        }
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _card, borderRadius: BorderRadius.circular(16),
          border: Border.all(color: selected ? _purple : _border, width: selected ? 1.6 : 1),
        ),
        child: Row(children: [
          Container(
            width: 22, height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: selected ? _purple : _border, width: 2),
              color: selected ? _purple : Colors.transparent,
            ),
            child: selected ? const Icon(Icons.check, color: Colors.white, size: 14) : null,
          ),
          const SizedBox(width: 14),
          Expanded(child: Text('$size pack',
              style: TextStyle(color: _fg, fontSize: 16, fontWeight: FontWeight.w800))),
          Text(cents == null ? '—' : MerchPricing.format(cents),
              style: const TextStyle(color: _gold, fontSize: 16, fontWeight: FontWeight.w800)),
        ]),
      ),
    );
  }

  void _showInvitationPreview(int packSize) {
    // Phase 1 themed previews exist for Kids and 1st Birthday sub-categories
    // today. Other contexts fall back to the generic variant-driven card
    // inside the sheet.
    final isKidsBirthday = _isBirthday && _kidsThemesFor(_birthdaySubCategory);
    InvitationPreviewSheet.show(
      context,
      eventId: widget.eventId,
      shortCode: _shortCode,
      theme: themeByKey(_themeKey),
      themeVariant: _themeVariant,
      eventName: widget.eventTitle,
      eventDate: widget.eventDate,
      accountTier: _accountTier,
      hostName: widget.hostName,
      orgLogoUrl: _orgLogoUrl,
      packSize: packSize,
      isKidsBirthday: isKidsBirthday,
    );
  }

  // ── Step 2: address ───────────────────────────────────────────
  Widget _stepAddress() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: [
        _eyebrow(_stepEyebrowText()),
        _title('Ship it where?'),
        _desc('We use this for billing and shipping. United States only for now. Saved to your profile so you don\'t have to retype next time.'),
        const SizedBox(height: 16),
        _input(_name, 'Recipient name'),
        // TODO(places): wire google_places_flutter (already in pubspec) to
        // suggest line1 results. Pass the API key through Remote Config.
        _input(_line1, 'Address line 1'),
        _input(_line2, 'Apt / suite / unit (optional)'),
        Row(children: [
          Expanded(flex: 3, child: _input(_city, 'City')),
          const SizedBox(width: 10),
          Expanded(flex: 1, child: _stateDropdown()),
        ]),
        _input(_zip, 'ZIP', keyboard: TextInputType.number),
      ],
    );
  }

  Widget _input(TextEditingController c, String label, {TextInputType? keyboard, int? maxLength}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c, keyboardType: keyboard, maxLength: maxLength,
        style: TextStyle(color: _fg),
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: label, counterText: '',
          labelStyle: TextStyle(color: _muted),
          filled: true, fillColor: _card,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _purple, width: 1.5)),
        ),
      ),
    );
  }

  Widget _stateDropdown() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        initialValue: _stateAbbr,
        isExpanded: true,
        dropdownColor: _card,
        iconEnabledColor: _muted,
        style: TextStyle(color: _fg, fontSize: 15),
        items: [
          for (final s in _usStates)
            DropdownMenuItem<String>(
              value: s,
              child: Text(s, style: TextStyle(color: _fg)),
            ),
        ],
        onChanged: (v) => setState(() => _stateAbbr = v),
        decoration: InputDecoration(
          labelText: 'State',
          labelStyle: TextStyle(color: _muted),
          filled: true, fillColor: _card,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _purple, width: 1.5)),
        ),
      ),
    );
  }

  // ── Step 3: shipping ──────────────────────────────────────────
  Widget _stepShipping() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: [
        _eyebrow(_stepEyebrowText()),
        _title('How fast?'),
        const SizedBox(height: 16),
        _shipTile(MerchShipping.standard,  'Standard',  '5–7 business days', MerchPricing.shippingStandardCents),
        _shipTile(MerchShipping.expedited, 'Expedited', '2–3 business days', MerchPricing.shippingExpeditedCents),
      ],
    );
  }

  Widget _shipTile(MerchShipping s, String name, String eta, int cents) {
    final selected = _shipping == s;
    return GestureDetector(
      onTap: () => setState(() => _shipping = s),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _card, borderRadius: BorderRadius.circular(16),
          border: Border.all(color: selected ? _purple : _border, width: selected ? 1.6 : 1),
        ),
        child: Row(children: [
          Container(
            width: 22, height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: selected ? _purple : _border, width: 2),
              color: selected ? _purple : Colors.transparent,
            ),
            child: selected ? const Icon(Icons.check, color: Colors.white, size: 14) : null,
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: TextStyle(color: _fg, fontSize: 15, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(eta, style: TextStyle(color: _muted, fontSize: 12)),
          ])),
          Text(cents == 0 ? 'Free' : '+${MerchPricing.format(cents)}',
              style: TextStyle(
                color: cents == 0 ? AppColors.green : _gold,
                fontSize: 15, fontWeight: FontWeight.w800,
              )),
        ]),
      ),
    );
  }

  // ── Step 4: summary ───────────────────────────────────────────
  Widget _stepSummary() {
    final addr = _address;
    final theme = themeByKey(_themeKey);
    final isExpedited = _shipping == MerchShipping.expedited;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: [
        _eyebrow(_stepEyebrowText()),
        _title('Review and pay'),
        const SizedBox(height: 14),
        _cardBox(children: [
          _row(Icons.palette_outlined, theme.name,
              '${theme.variants[_themeVariant].name} variant · ${_accountTier == 'businessPlus' ? 'White-label' : _accountTier == 'business' ? 'Color + event details' : 'B&W brand mark'}'),
          Divider(color: _border, height: 22),
          _row(_product == MerchProduct.invitation ? Icons.mail_outline : Icons.style_outlined,
              '$_packSize pack · $_productLabel',
              MerchPricing.format(_subtotalCents)),
          // Standard shipping is built into pack prices — only show a line
          // item when the customer opted into the expedited upgrade.
          if (isExpedited) ...[
            Divider(color: _border, height: 22),
            _row(Icons.local_shipping_outlined, 'Expedited shipping',
                MerchPricing.format(_shippingCents)),
          ],
          Divider(color: _border, height: 22),
          _row(Icons.attach_money, 'Total', MerchPricing.format(_totalCents), bold: true),
        ]),
        const SizedBox(height: 12),
        _cardBox(children: [
          Text('SHIP TO', style: TextStyle(color: _muted, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
          const SizedBox(height: 6),
          Text(addr.formatted, style: TextStyle(color: _fg, fontSize: 13.5, height: 1.45)),
        ]),
        const SizedBox(height: 12),
        _cardBox(children: [
          Text('PAYMENT', style: TextStyle(color: _muted, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
          const SizedBox(height: 10),
          // Stripe's native CardFormField renders on the platform side
          // (iOS UIKit / Android EditText), so it doesn't pick up the
          // app's dark/light theme automatically. Forcing a white field
          // with dark text in BOTH themes is safer than passing _fg /
          // _card here, which produced white-on-white (light) or
          // dark-on-dark (dark) and made typed digits invisible.
          CardFormField(
            controller: _cardController,
            style: CardFormStyle(
              backgroundColor: Colors.white,
              textColor: AppColors.dark,
              placeholderColor: const Color(0xFF8892A4),
              borderColor: const Color(0xFFE0E8E0),
              borderRadius: 10,
            ),
          ),
        ]),
        if (kTestingMode) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _gold.withValues(alpha: 0.40)),
            ),
            child: const Row(children: [
              Icon(Icons.science_outlined, color: _gold, size: 18),
              SizedBox(width: 8),
              Expanded(child: Text(
                'TEST MODE — no Stripe charge, order goes straight to admin queue with a placeholder print file.',
                style: TextStyle(color: _gold, fontSize: 12.5, fontWeight: FontWeight.w700),
              )),
            ]),
          ),
        ],
      ],
    );
  }

  Widget _cardBox({required List<Widget> children}) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: _card, borderRadius: BorderRadius.circular(14),
      border: Border.all(color: _border),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
  );

  Widget _row(IconData icon, String label, String trailing, {bool bold = false}) {
    return Row(children: [
      Icon(icon, size: 18, color: _muted),
      const SizedBox(width: 10),
      Expanded(child: Text(label,
          style: TextStyle(color: _fg, fontSize: bold ? 16 : 14, fontWeight: bold ? FontWeight.w800 : FontWeight.w600))),
      Text(trailing, style: TextStyle(
        color: bold ? _gold : _fg,
        fontSize: bold ? 18 : 14, fontWeight: FontWeight.w800,
      )),
    ]);
  }

  // ── Step 5: confirmation ──────────────────────────────────────
  Widget _stepConfirmation() {
    final delivery = _estDelivery;
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final deliveryStr = delivery == null
        ? 'in 5–10 business days'
        : 'around ${months[delivery.month - 1]} ${delivery.day}';
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 88, height: 88,
            decoration: BoxDecoration(color: AppColors.green.withValues(alpha: 0.18), shape: BoxShape.circle),
            child: const Icon(Icons.check_rounded, color: AppColors.green, size: 56),
          ),
          const SizedBox(height: 20),
          Text('Your order is being prepared!',
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: 'FredokaOne', fontSize: 26, color: _fg)),
          const SizedBox(height: 8),
          Text(
            kTestingMode
                ? 'Test order recorded. Visible in the admin fulfillment queue.'
                : 'We\'ll email you tracking info as soon as it ships.\nEstimated delivery $deliveryStr.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _muted, fontSize: 14, height: 1.55),
          ),
          if (_orderId != null) ...[
            const SizedBox(height: 14),
            Text('Order #${_orderId!.substring(0, _orderId!.length.clamp(0, 8))}',
                style: const TextStyle(color: _gold, fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
          ],
          const SizedBox(height: 28),
          // Tiny live preview of the QR + brand mark — what they're getting
          // (until real renderer ships, this is the closest real preview).
          Container(
            width: 140, height: 140, padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white, borderRadius: BorderRadius.circular(12),
            ),
            // Canonical shortCode path. Every event doc is guaranteed
            // to have a non-empty `shortCode` (backfill complete);
            // initState seeds it from widget.shortCode and
            // _resolveShortCode fetches the doc when the caller
            // didn't pass one. While the async fetch is in flight we
            // render a silent placeholder instead of `partywithqr.com/event/null`.
            child: _shortCode != null
                ? QrImageView(
                    data: 'https://partywithqr.com/event/$_shortCode',
                    backgroundColor: Colors.white,
                  )
                : const SizedBox(height: 200),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).pop(_orderId),
              style: ElevatedButton.styleFrom(
                backgroundColor: _purple, foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            ),
          ),
        ]),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────
  Widget _eyebrow(String s) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 6),
    child: Text(s, style: TextStyle(
      color: _muted, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4,
    )),
  );
  Widget _title(String s) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(s, style: TextStyle(
      fontFamily: 'FredokaOne', fontSize: 26, color: _fg,
    )),
  );
  Widget _desc(String s) => Text(s, style: TextStyle(color: _muted, fontSize: 13.5, height: 1.5));
}

// ── Step kinds ──────────────────────────────────────────────────
// Listed in display order; the actual flow is computed by `_steps`
// (filters out `birthdaySubCategory` for non-birthday events). `confirmation`
// is a terminal state — never appears in the interactive list.
enum _StepKind { birthdaySubCategory, theme, pack, address, shipping, summary, confirmation }

// ── Birthday sub-category options ───────────────────────────────
// Drives the optional sub-selector for birthday events. Mirrors
// Vistaprint's birthday catalog so the print template can be picked
// based on this value once category-specific designs are wired in.
enum _BirthdaySubCategory { firstBirthday, kids, teens, adults, milestones, surprise }

extension _BirthdaySubCategoryMeta on _BirthdaySubCategory {
  String get emoji => switch (this) {
    _BirthdaySubCategory.firstBirthday => '🎂',
    _BirthdaySubCategory.kids          => '🎈',
    _BirthdaySubCategory.teens         => '🎮',
    _BirthdaySubCategory.adults        => '🥂',
    _BirthdaySubCategory.milestones    => '✨',
    _BirthdaySubCategory.surprise      => '🎉',
  };
  String get label => switch (this) {
    _BirthdaySubCategory.firstBirthday => '1st Birthday',
    _BirthdaySubCategory.kids          => 'Kids',
    _BirthdaySubCategory.teens         => 'Teens',
    _BirthdaySubCategory.adults        => 'Adults',
    _BirthdaySubCategory.milestones    => 'Milestones',
    _BirthdaySubCategory.surprise      => 'Surprise',
  };
}
