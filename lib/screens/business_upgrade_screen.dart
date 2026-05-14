import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import '../utils.dart';

// Flip to false to re-enable real purchases.
const bool kTestingMode = false;

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
const _gold        = Color(0xFFC8922A);

class BusinessUpgradeScreen extends StatefulWidget {
  const BusinessUpgradeScreen({super.key});
  @override
  State<BusinessUpgradeScreen> createState() => _BusinessUpgradeScreenState();
}

class _BusinessUpgradeScreenState extends State<BusinessUpgradeScreen> {
  String _selectedBusinessPlan = 'annual';
  String _selectedPlusPlan     = 'annual';
  bool _loadingProducts = true;
  bool _purchasing = false;
  Map<String, ProductDetails> _products = {};
  StreamSubscription<DocumentSnapshot>? _userSub;

  static const _monthlyId   = 'business_monthly';
  static const _yearlyId    = 'business_yearly';
  static const _hqMonthlyId = 'business_plus_monthly';
  static const _hqYearlyId  = 'business_plus_yearly';

  // Theme-aware colors — resolve light vs dark variant from the current Theme.
  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;
  Color get _fg     => _isDark ? Colors.white : AppColors.dark;

  static const _businessFeatures = [
    'One QR code for your whole business',
    'Recurring events — weekly, monthly, custom',
    'Co-hosting with your team',
    'Event templates',
    'Cross-event analytics',
    'Custom branding',
    '100 archived events',
    '1 year photo storage',
    'Priority support',
  ];

  static const _plusExtraFeatures = [
    'White-label stickers — your logo, not ours',
    'Unlimited archived events',
    '2-year photo storage',
  ];

  @override
  void initState() {
    super.initState();
    _loadProducts();
    _watchActivation();
  }

  @override
  void dispose() {
    _userSub?.cancel();
    super.dispose();
  }

  Future<void> _loadProducts() async {
    final available = await InAppPurchase.instance.isAvailable();
    if (!available) {
      if (mounted) setState(() => _loadingProducts = false);
      return;
    }
    final response = await InAppPurchase.instance.queryProductDetails({
      _monthlyId, _yearlyId, _hqMonthlyId, _hqYearlyId,
    });
    if (mounted) {
      setState(() {
        _loadingProducts = false;
        _products = {for (final p in response.productDetails) p.id: p};
      });
    }
  }

  void _watchActivation() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _userSub = FirebaseFirestore.instance.collection('users').doc(uid).snapshots().listen((snap) {
      final data = snap.data() ?? {};
      final accountType = data['accountType'];
      final activated = (accountType == 'business' || accountType == 'businessPlus')
          && data['isTrialing'] != true;
      if (activated && mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });
  }

  Future<void> _subscribe(String tier) async {
    final String productId;
    if (tier == 'business') {
      productId = _selectedBusinessPlan == 'monthly' ? _monthlyId : _yearlyId;
    } else {
      productId = _selectedPlusPlan == 'monthly' ? _hqMonthlyId : _hqYearlyId;
    }
    final product = _products[productId];
    if (product == null) {
      // Surface the failure instead of silently no-op'ing — without
      // this, a Play Console misconfiguration (product not yet propagated,
      // tester role not granted, etc.) looks like an unresponsive button.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Subscription "$productId" is not available right now. Try again in a few minutes.'),
          backgroundColor: Colors.redAccent,
        ));
      }
      return;
    }
    setState(() => _purchasing = true);
    try {
      await InAppPurchase.instance.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: product));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start purchase: $e'), backgroundColor: Colors.redAccent),
        );
      }
    } finally {
      if (mounted) setState(() => _purchasing = false);
    }
  }

  // Test-only upgrade path. Writes accountType + isTrialing directly
  // to the user doc, bypassing Stripe / IAP entirely. Activation
  // detection in _watchActivation picks up the change and pops back
  // to the home feed, mirroring the real purchase flow's exit.
  Future<void> _testUpgrade(String tier) async {
    if (_purchasing) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    setState(() => _purchasing = true);
    try {
      final accountType = tier == 'businessPlus' ? 'businessPlus' : 'business';
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'accountType': accountType,
        'isTrialing':  false,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('🧪 Test upgrade applied: $accountType'),
          backgroundColor: AppColors.green,
          behavior: SnackBarBehavior.floating,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Test upgrade failed: $e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _purchasing = false);
    }
  }

  Future<void> _restore() async {
    setState(() => _purchasing = true);
    try {
      await InAppPurchase.instance.restorePurchases();
    } catch (_) {}
    if (mounted) setState(() => _purchasing = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (kTestingMode) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: _gold,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    '🧪 TEST MODE — Bypasses Stripe, writes accountType directly',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1A1A1A),
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Align(
                alignment: Alignment.topRight,
                child: GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 32, height: 32,
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.10), shape: BoxShape.circle),
                    child: const Center(child: Text('×', style: TextStyle(fontSize: 22, color: Colors.white, height: 1.1))),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                decoration: const BoxDecoration(boxShadow: [BoxShadow(color: Color(0x559C7FD4), blurRadius: 32, spreadRadius: 8)]),
                child: const Text('✨', style: TextStyle(fontSize: 60)),
              ),
              const SizedBox(height: 16),
              Text(
                'Level Up Your Events',
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'FredokaOne', fontSize: 30, color: _fg),
              ),
              const SizedBox(height: 8),
              Text(
                'Choose the plan that fits your team',
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'Nunito', fontSize: 15, color: _muted, height: 1.4),
              ),
              const SizedBox(height: 24),

              // ── BUSINESS TIER ──────────────────────────────
              _buildTierCard(
                accent: _purple,
                label: 'BUSINESS',
                subtitle: 'Everything in Personal, plus pro tools',
                features: _businessFeatures,
                monthlyPrice: '\$9.99',
                yearlyPrice: '\$79.99',
                selectedPlan: _selectedBusinessPlan,
                onPlanChanged: (p) => setState(() => _selectedBusinessPlan = p),
                onSubscribe: () => kTestingMode ? _testUpgrade('business') : _subscribe('business'),
                featured: false,
              ),

              const SizedBox(height: 20),

              // ── BUSINESS PLUS TIER ─────────────────────────
              _buildTierCard(
                accent: _gold,
                label: 'HEADQUARTERS',
                subtitle: 'Everything in Business, plus:',
                features: _plusExtraFeatures,
                monthlyPrice: '\$19.99',
                yearlyPrice: '\$159.99',
                selectedPlan: _selectedPlusPlan,
                onPlanChanged: (p) => setState(() => _selectedPlusPlan = p),
                onSubscribe: () => kTestingMode ? _testUpgrade('businessPlus') : _subscribe('businessPlus'),
                featured: true,
              ),

              const SizedBox(height: 20),
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Text(
                  'Maybe later',
                  style: TextStyle(fontSize: 15, color: _muted, decoration: TextDecoration.underline, decorationColor: _muted),
                ),
              ),
              const SizedBox(height: 10),
              GestureDetector(
                onTap: _purchasing ? null : _restore,
                child: const Text(
                  'Restore purchases',
                  style: TextStyle(fontSize: 13, color: Color(0xFF6B6880), decoration: TextDecoration.underline, decorationColor: Color(0xFF6B6880)),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Cancel anytime · No charge until trial ends · QR Party LLC',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Color(0xFF6B6880)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTierCard({
    required Color accent,
    required String label,
    required String subtitle,
    required List<String> features,
    required String monthlyPrice,
    required String yearlyPrice,
    required String selectedPlan,
    required void Function(String) onPlanChanged,
    required VoidCallback onSubscribe,
    required bool featured,
  }) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: featured ? accent : _border, width: featured ? 2 : 1),
        boxShadow: featured
            ? [BoxShadow(color: accent.withValues(alpha: 0.18), blurRadius: 24, spreadRadius: 2)]
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Wrap (rather than Row) so HEADQUARTERS — which carries
                // both LAUNCH PRICING and MOST POWERFUL pills — gracefully
                // breaks to a second line on narrow phones instead of
                // overflowing.
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        color: accent,
                        letterSpacing: 2,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: AppColors.green, borderRadius: BorderRadius.circular(20)),
                      child: const Text(
                        'LAUNCH PRICING',
                        style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: .8),
                      ),
                    ),
                    if (featured)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(20)),
                        child: const Text(
                          'MOST POWERFUL',
                          style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: .8),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 14, color: _muted, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 16),
                ...features.map((f) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('✓', style: TextStyle(fontSize: 15, color: accent, fontWeight: FontWeight.w900)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(f, style: TextStyle(fontSize: 14, color: _fg, height: 1.35)),
                          ),
                        ],
                      ),
                    )),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: _buildPlanCard(
                        label: 'Monthly',
                        price: monthlyPrice,
                        period: '/month',
                        selected: selectedPlan == 'monthly',
                        accent: accent,
                        onTap: () => onPlanChanged('monthly'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          _buildPlanCard(
                            label: 'Annual',
                            price: yearlyPrice,
                            period: '/year',
                            selected: selectedPlan == 'annual',
                            accent: accent,
                            onTap: () => onPlanChanged('annual'),
                          ),
                          Positioned(
                            top: -9, right: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(color: AppColors.green, borderRadius: BorderRadius.circular(20)),
                              child: const Text('SAVE 33%', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Colors.white)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: (kTestingMode ? _purchasing : (_loadingProducts || _purchasing)) ? null : onSubscribe,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kTestingMode ? _gold : accent,
                      foregroundColor: (kTestingMode || featured) ? const Color(0xFF1A1A1A) : Colors.white,
                      disabledBackgroundColor: _border,
                      disabledForegroundColor: _muted,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                    child: (kTestingMode ? _purchasing : (_loadingProducts || _purchasing))
                        ? SizedBox(
                            width: 22, height: 22,
                            child: CircularProgressIndicator(
                              color: (kTestingMode || featured) ? const Color(0xFF1A1A1A) : Colors.white,
                              strokeWidth: 2.5,
                            ),
                          )
                        : Text(
                            kTestingMode ? 'Test Upgrade (Dev Only)' : 'Start 14-Day Free Trial',
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlanCard({
    required String label,
    required String price,
    required String period,
    required bool selected,
    required Color accent,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.12) : _bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? accent : _border,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Text(label, style: TextStyle(fontSize: 12, color: _muted, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(price, style: TextStyle(fontSize: 22, color: _fg, fontWeight: FontWeight.w800)),
            Text(period, style: TextStyle(fontSize: 11, color: _muted)),
          ],
        ),
      ),
    );
  }
}
