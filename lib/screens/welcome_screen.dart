import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../utils.dart';
import 'qr_scanner_screen.dart';
import 'home_router.dart';

// ── Theme palette ──────────────────────────────────────────────
const _bgDark      = Color(0xFF2D3047);
const _bgLight     = Color(0xFFF8F7FC);
const _cardDark    = Color(0xFF383B56);
const _cardLight   = Colors.white;
const _borderDark  = Color(0xFF4A4E6B);
const _borderLight = Color(0xFFE0E8E0);
const _mutedDark   = Color(0xFFA9A6B8);
const _mutedLight  = Color(0xFF8892A4);
const _gold        = Color(0xFFC8922A);

// ─── SCREEN 1 — WELCOME ──────────────────────────────────────
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark  = Theme.of(context).brightness == Brightness.dark;
    final bg      = isDark ? _bgDark     : _bgLight;
    final fg      = isDark ? Colors.white : AppColors.dark;
    final muted   = isDark ? _mutedDark  : _mutedLight;
    // The logo card stays white so the brand "QR Party" mark reads consistently.
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            children: [
              const Spacer(flex: 2),
              // Coded logo
              Container(
                height: 130,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [BoxShadow(color: AppColors.green.withValues(alpha: 0.12), blurRadius: 40, offset: const Offset(0, 16))],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('QR', style: TextStyle(fontSize: 48, fontWeight: FontWeight.w900, color: AppColors.dark, height: 1)),
                        Text('Party', style: TextStyle(fontSize: 36, fontWeight: FontWeight.w300, color: AppColors.purple, height: 1)),
                      ],
                    ),
                    const SizedBox(width: 12),
                    // Real, scannable QR code — always points to the homepage.
                    // Outer dark container acts as a frame around the white
                    // QR plate so the brand aesthetic is preserved.
                    Container(
                      width: 72,
                      height: 72,
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(color: AppColors.dark, borderRadius: BorderRadius.circular(8)),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: QrImageView(
                          data: 'https://partywithqr.com',
                          version: QrVersions.auto,
                          backgroundColor: Colors.white,
                          padding: const EdgeInsets.all(2),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 36),
              Text(
                'scan.party.connect.',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: fg, letterSpacing: -0.5),
              ),
              const SizedBox(height: 10),
              Text(
                'Your party, one scan away',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 17, color: muted, height: 1.5),
              ),
              const Spacer(flex: 3),
              // CTA buttons
              SizedBox(
                width: double.infinity,
                height: 58,
                child: ElevatedButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SignUpScreen())),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  ),
                  child: const Text('Get Started', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 58,
                child: OutlinedButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginScreen())),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.green, width: 1.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  ),
                  child: const Text('Already have an account? Log in', style: TextStyle(fontSize: 16, color: AppColors.green)),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 58,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const QRScannerScreen())),
                  icon: const Icon(Icons.qr_code_scanner, color: AppColors.purple),
                  label: const Text('Scan an Event QR Code', style: TextStyle(fontSize: 16, color: AppColors.purple)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.purple, width: 1.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Text('© 2026 QR Party · www.PartyWithQR.com', style: TextStyle(fontSize: 12, color: muted)),
              const SizedBox(height: 16),
              debugLabel('Screen 1 — Shared'),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── SIGN UP SCREEN ───────────────────────────────────────────
class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});
  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _firstNameController = TextEditingController();
  final _lastNameController  = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _zipController = TextEditingController();
  final _orgNameCtrl = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _error;
  String _accountType = 'personal';

  // Theme-aware color getters — resolve light vs dark variant from the current Theme.
  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;
  Color get _fg     => _isDark ? Colors.white : AppColors.dark;

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _zipController.dispose();
    _orgNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    final isPersonal = _accountType == 'personal';
    final nameOk = isPersonal
        ? (_firstNameController.text.trim().isNotEmpty &&
           _lastNameController.text.trim().isNotEmpty)
        : _orgNameCtrl.text.trim().isNotEmpty;
    if (!nameOk || _emailController.text.isEmpty || _passwordController.text.isEmpty || _zipController.text.isEmpty) {
      setState(() => _error = 'Please fill in all fields');
      return;
    }
    if (_passwordController.text != _confirmPasswordController.text) {
      setState(() => _error = "Passwords don't match");
      return;
    }
    setState(() { _isLoading = true; _error = null; });
    try {
      final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );
      final newUser = cred.user;
      if (newUser == null) {
        throw FirebaseAuthException(code: 'user-null', message: 'Could not create user. Please try again.');
      }
      final firstName = isPersonal ? _firstNameController.text.trim() : '';
      final lastName  = isPersonal ? _lastNameController.text.trim()  : '';
      final fullName  = isPersonal ? '$firstName $lastName' : _orgNameCtrl.text.trim();
      await newUser.updateDisplayName(fullName);
      // merge: true so re-running this code path can't wipe fields
      // already on the doc — e.g. an admin manually promoted to
      // accountType='businessPlus' / isAdmin=true. Without merge, a
      // double-tap on Sign Up (or any path that re-enters this method
      // for an existing uid) would silently nuke admin grants.
      await FirebaseFirestore.instance.collection('users').doc(newUser.uid).set({
        'firstName':   firstName,
        'lastName':    lastName,
        'name':        fullName,
        'email':       _emailController.text.trim(),
        'zipCode':     _zipController.text.trim(),
        'accountType': _accountType,
        'createdAt':   FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      // Auto-provision the org doc for Business / Headquarters tiers
      // so downstream flows (HQ-link request, Add Location, org QR)
      // have a businessOrgId from day one. Best-effort — a failure
      // here doesn't block signup; the user can retry from
      // OrganizationScreen later.
      if (_accountType == 'business' || _accountType == 'businessPlus') {
        try {
          final orgRef = FirebaseFirestore.instance.collection('organizations').doc();
          await orgRef.set({
            'name':        _orgNameCtrl.text.trim(),
            'description': '',
            'logoUrl':     '',
            'ownerId':     newUser.uid,
            'memberIds':   [newUser.uid],
            'orgQrCode':   'https://partywithqr.com/org/${orgRef.id}',
            'createdAt':   FieldValue.serverTimestamp(),
          });
        } catch (e) {
          debugPrint('[SignUp] org auto-create failed: $e');
        }
      }
      try {
        await newUser.sendEmailVerification();
      } catch (e) {
        debugPrint('[SignUp] sendEmailVerification failed: $e');
      }
      await FirebaseAuth.instance.authStateChanges().firstWhere((u) => u != null);
      if (!mounted) return;
      // Business-tier only: offer the optional HQ-link request before
      // routing to email verification. Personal accounts skip; HQ-tier
      // accounts (businessPlus) skip because they ARE the linkable
      // entity — they don't link upward.
      if (_accountType == 'business') {
        await _showHqLinkDialog();
        if (!mounted) return;
      }
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const EmailVerificationScreen()),
        (_) => false,
      );
    } on FirebaseAuthException catch (e) {
      setState(() => _error = e.message ?? 'Could not create account.');
    } catch (e) {
      setState(() => _error = 'Something went wrong: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, iconTheme: IconThemeData(color: _fg)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Create your\naccount', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: _fg, height: 1.1, letterSpacing: -1)),
              const SizedBox(height: 8),
              Text('Join QR Party and start hosting!', style: TextStyle(fontSize: 16, color: _muted)),
              const SizedBox(height: 36),
              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Colors.redAccent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13))),
                  ]),
                ),
                const SizedBox(height: 16),
              ],
              _fieldLabel('What are you using this for?'),
              Row(children: [
                Expanded(child: _typeChip('Personal',     'personal')),
                const SizedBox(width: 8),
                Expanded(child: _typeChip('Business',     'business')),
                const SizedBox(width: 8),
                Expanded(child: _typeChip('Headquarters', 'businessPlus')),
              ]),
              const SizedBox(height: 8),
              Text('Headquarters: for districts, councils, and multi-location orgs',
                  style: TextStyle(fontSize: 12, color: _muted)),
              const SizedBox(height: 24),
              if (_accountType == 'personal') ...[
                Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _fieldLabel('First Name'),
                    _inputField(_firstNameController, 'Sarah', Icons.person_outline, textInputAction: TextInputAction.next, onEditingComplete: () => FocusScope.of(context).nextFocus(), textCapitalization: TextCapitalization.words),
                  ])),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _fieldLabel('Last Name'),
                    _inputField(_lastNameController, 'Chen', Icons.person_outline, textInputAction: TextInputAction.next, onEditingComplete: () => FocusScope.of(context).nextFocus(), textCapitalization: TextCapitalization.words),
                  ])),
                ]),
              ] else ...[
                _fieldLabel(_accountType == 'business' ? 'Business Name' : 'Organization Name'),
                _inputField(
                  _orgNameCtrl,
                  _accountType == 'business' ? 'e.g. Alvarado Street Brewery' : 'e.g. PGUSD District PTA',
                  Icons.business_outlined,
                  textInputAction: TextInputAction.next,
                  onEditingComplete: () => FocusScope.of(context).nextFocus(),
                  textCapitalization: TextCapitalization.words,
                ),
              ],
              const SizedBox(height: 20),
              _fieldLabel('Email'),
              _inputField(_emailController, 'you@example.com', Icons.email_outlined, keyboardType: TextInputType.emailAddress, textInputAction: TextInputAction.next, onEditingComplete: () => FocusScope.of(context).nextFocus()),
              const SizedBox(height: 20),
              _fieldLabel('Password'),
              _passwordField(_passwordController, _obscurePassword, 'Min. 6 characters',
                  () => setState(() => _obscurePassword = !_obscurePassword),
                  textInputAction: TextInputAction.next,
                  onSubmitted: () => FocusScope.of(context).nextFocus()),
              const SizedBox(height: 20),
              _fieldLabel('Confirm Password'),
              _passwordField(_confirmPasswordController, _obscureConfirm, 'Re-enter your password',
                  () => setState(() => _obscureConfirm = !_obscureConfirm),
                  textInputAction: TextInputAction.next,
                  onSubmitted: () => FocusScope.of(context).nextFocus()),
              const SizedBox(height: 20),
              _fieldLabel('Zip Code'),
              _inputField(_zipController, 'e.g. 93955', Icons.location_on_outlined, keyboardType: TextInputType.number, textInputAction: TextInputAction.done, onEditingComplete: _signUp),
              const SizedBox(height: 8),
              Text('Used to show you local events nearby', style: TextStyle(fontSize: 12, color: _muted)),
              const SizedBox(height: 36),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _signUp,
                  style: ElevatedButton.styleFrom(backgroundColor: AppColors.green, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                  child: _isLoading
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text('Create Account', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 20),
              Center(
                child: GestureDetector(
                  onTap: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen())),
                  child: RichText(
                    text: TextSpan(
                      text: 'Already have an account? ',
                      style: TextStyle(color: _muted, fontSize: 14),
                      children: const [TextSpan(text: 'Log in', style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w700))],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showHqLinkDialog() async {
    // Dialog pops with the resolved HQ org name on success, null on
    // skip / error. Snackbar fires on the parent SignUp scaffold's
    // ScaffoldMessenger AFTER the dialog tears down — same disposal-
    // safe pattern as _showSendInviteSheet on the HQ home feed.
    final hqOrgName = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _HqLinkDialog(),
    );
    if (hqOrgName == null || hqOrgName.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        'Request sent to $hqOrgName — they can invite you via Add Location to complete the link.',
      ),
      backgroundColor: AppColors.green,
      behavior: SnackBarBehavior.floating,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
      duration: const Duration(seconds: 6),
    ));
  }

  Widget _fieldLabel(String label) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _fg)),
      );

  void _selectAccountType(String value) {
    if (value == _accountType) return;
    final wasPersonal   = _accountType == 'personal';
    final goingPersonal = value == 'personal';
    setState(() {
      _accountType = value;
      if (goingPersonal) {
        _orgNameCtrl.clear();
        _firstNameController.clear();
        _lastNameController.clear();
      } else if (wasPersonal) {
        _firstNameController.clear();
        _lastNameController.clear();
      }
    });
  }

  Widget _typeChip(String label, String value) {
    final selected = _accountType == value;
    final tierColor = switch (value) {
      'business'     => AppColors.purple,
      'businessPlus' => _gold,
      _              => AppColors.green,
    };
    return GestureDetector(
      onTap: () => _selectAccountType(value),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? tierColor : _card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? tierColor : _border,
            width: 1.5,
          ),
        ),
        // FittedBox keeps "Personal" / "Business" at their native size
        // (they fit a ~104 dp chip slot comfortably) and only scales
        // "Headquarters" down on narrow phones / large system font
        // scaling, instead of wrapping it across two lines and making
        // that chip taller than the other two. maxLines: 1 is a
        // belt-and-suspenders guard for any future label that's even
        // wider than the chip can shrink-fit.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            maxLines: 1,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              color: selected ? Colors.white : _muted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _inputField(TextEditingController controller, String hint, IconData icon, {TextInputType? keyboardType, TextInputAction? textInputAction, VoidCallback? onEditingComplete, TextCapitalization textCapitalization = TextCapitalization.none}) => TextField(
        controller: controller,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        onEditingComplete: onEditingComplete,
        textCapitalization: textCapitalization,
        style: TextStyle(color: _fg, fontSize: 15),
        cursorColor: AppColors.green,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: _muted),
          prefixIcon: Icon(icon, color: _muted, size: 20),
          filled: true,
          fillColor: _card,
          border:        OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _border)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _border)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.green, width: 1.5)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
      );

  Widget _passwordField(
    TextEditingController controller,
    bool obscured,
    String hint,
    VoidCallback toggleObscure, {
    TextInputAction? textInputAction,
    VoidCallback? onSubmitted,
  }) => TextField(
        controller: controller,
        obscureText: obscured,
        textInputAction: textInputAction,
        onSubmitted: onSubmitted == null ? null : (_) => onSubmitted(),
        style: TextStyle(color: _fg, fontSize: 15),
        cursorColor: AppColors.green,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: _muted),
          prefixIcon: Icon(Icons.lock_outline, color: _muted, size: 20),
          suffixIcon: IconButton(
            icon: Icon(obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined, color: _muted, size: 20),
            onPressed: toggleObscure,
          ),
          filled: true,
          fillColor: _card,
          border:        OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _border)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _border)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.green, width: 1.5)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
      );
}

// ─── EMAIL VERIFICATION SCREEN ────────────────────────────────
class EmailVerificationScreen extends StatefulWidget {
  const EmailVerificationScreen({super.key});
  @override
  State<EmailVerificationScreen> createState() => _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  static const _resendCooldownSeconds = 60;
  Timer? _pollTimer;
  Timer? _cooldownTimer;
  int _cooldown = _resendCooldownSeconds;
  bool _checking = false;
  bool _resending = false;
  String? _error;

  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;
  Color get _fg     => _isDark ? Colors.white : AppColors.dark;

  @override
  void initState() {
    super.initState();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkVerified(silent: true));
    _startCooldown();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _cooldownTimer?.cancel();
    super.dispose();
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldown = _resendCooldownSeconds);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      if (_cooldown <= 1) { t.cancel(); setState(() => _cooldown = 0); }
      else { setState(() => _cooldown -= 1); }
    });
  }

  Future<void> _checkVerified({bool silent = false}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (!silent) setState(() { _checking = true; _error = null; });
    try {
      await user.reload();
      final refreshed = FirebaseAuth.instance.currentUser;
      if (refreshed != null && refreshed.emailVerified) {
        _pollTimer?.cancel();
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const HomeRouter()),
          (_) => false,
        );
        return;
      }
      if (!silent && mounted) {
        setState(() => _error = "We haven't received your verification yet. Check your inbox and tap the link.");
      }
    } catch (e) {
      if (!silent && mounted) setState(() => _error = 'Could not check verification: $e');
    } finally {
      if (!silent && mounted) setState(() => _checking = false);
    }
  }

  Future<void> _resend() async {
    if (_cooldown > 0 || _resending) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() { _resending = true; _error = null; });
    try {
      await user.sendEmailVerification();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Verification email sent'),
        backgroundColor: AppColors.green,
      ));
      _startCooldown();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not resend: $e');
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  Future<void> _signOutAndBack() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final email = FirebaseAuth.instance.currentUser?.email ?? 'your inbox';
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 72, height: 72,
                decoration: BoxDecoration(
                  color: AppColors.green.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Center(child: Text('📧', style: TextStyle(fontSize: 34))),
              ),
              const SizedBox(height: 24),
              Text('Check your\nemail',
                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: _fg, height: 1.1, letterSpacing: -1)),
              const SizedBox(height: 12),
              RichText(
                text: TextSpan(
                  style: TextStyle(fontSize: 16, color: _muted, height: 1.5),
                  children: [
                    const TextSpan(text: 'We sent a verification link to '),
                    TextSpan(text: email, style: TextStyle(color: _fg, fontWeight: FontWeight.w700)),
                    const TextSpan(text: '. Tap the link there, then come back here.'),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Colors.redAccent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    const Icon(Icons.info_outline, color: Colors.redAccent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13))),
                  ]),
                ),
                const SizedBox(height: 16),
              ],
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _checking ? null : () => _checkVerified(silent: false),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.green, foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: _checking
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text("I've verified", style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton(
                  onPressed: (_cooldown > 0 || _resending) ? null : _resend,
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: _cooldown > 0 ? _border : AppColors.green, width: 1.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: _resending
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: AppColors.green, strokeWidth: 2))
                      : Text(
                          _cooldown > 0 ? 'Resend email in ${_cooldown}s' : 'Resend email',
                          style: TextStyle(
                            fontSize: 15,
                            color: _cooldown > 0 ? _muted : AppColors.green,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 14),
              Center(
                child: Text(
                  'Auto-checking every 5 seconds',
                  style: TextStyle(fontSize: 12, color: _muted),
                ),
              ),
              const SizedBox(height: 28),
              Center(
                child: GestureDetector(
                  onTap: _signOutAndBack,
                  child: Text(
                    'Use a different email',
                    style: TextStyle(color: _muted, fontSize: 14, decoration: TextDecoration.underline, decorationColor: _muted),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── LOGIN SCREEN ─────────────────────────────────────────────
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _error;

  // Theme-aware color getters — resolve light vs dark variant from the current Theme.
  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;
  Color get _fg     => _isDark ? Colors.white : AppColors.dark;

  /// Sends a password-reset email to whatever address is currently in
  /// the email field. Uses the same email controller as the sign-in
  /// flow so the user doesn't have to retype it.
  ///
  /// Firebase's modern default behavior is to NOT throw `user-not-found`
  /// for unknown emails — it silently swallows them to prevent email
  /// enumeration attacks. We mirror that intentionally: the green
  /// confirmation snackbar shows whether the email exists or not, so
  /// nobody can probe the account database via the reset form. The
  /// only paths that surface an error are:
  ///   • blank / malformed input  → red banner asking for a real email
  ///   • invalid-email from server → red banner (server-side validation)
  ///   • network-request-failed   → "Network issue — please try again"
  ///   • everything else (including user-not-found, if Firebase happens
  ///     to throw it on this project) → still treated as success; the
  ///     real reason is logged so the dev console keeps the truth.
  Future<void> _sendPasswordReset() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Type your email above first, then tap "Forgot password?"');
      return;
    }
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      setState(() => _error = 'That email address looks invalid.');
      return;
    }
    setState(() { _isLoading = true; _error = null; });

    void showSuccess() {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Check your inbox at $email for a reset link.'),
        backgroundColor: AppColors.green,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ));
    }

    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      debugPrint('[Login] password reset call succeeded for $email');
      showSuccess();
    } on FirebaseAuthException catch (e) {
      debugPrint('[Login] sendPasswordResetEmail code=${e.code} message=${e.message}');
      if (!mounted) return;
      switch (e.code) {
        case 'invalid-email':
          setState(() => _error = 'That email address looks invalid.');
        case 'network-request-failed':
          setState(() => _error = 'Network issue — please try again.');
        case 'user-not-found':
        case 'too-many-requests':
        default:
          // Treat as success in the UI (don't leak whether the account
          // exists, don't punish the user for a backend rate limit).
          // Real cause already logged above for debugging.
          showSuccess();
      }
    } catch (e) {
      // Anything not a FirebaseAuthException is almost certainly a
      // transport layer problem (DNS, no network, etc.) — show success
      // optimistically anyway, since the email may still go through
      // once connectivity returns. Log the cause for engineers.
      debugPrint('[Login] sendPasswordResetEmail unexpected: $e');
      showSuccess();
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _login() async {
    if (_emailController.text.isEmpty || _passwordController.text.isEmpty) {
      setState(() => _error = 'Please fill in all fields');
      return;
    }
    setState(() { _isLoading = true; _error = null; });
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );
      // Wait for the auth-state stream to fire, then push HomeRouter
      // explicitly so the user lands on the correct home feed regardless of
      // any timing race with MaterialApp.home rebuilding.
      await FirebaseAuth.instance.authStateChanges().firstWhere((u) => u != null);
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeRouter()),
        (_) => false,
      );
    } on FirebaseAuthException catch (e) {
      setState(() => _error = e.message ?? 'Could not sign in.');
    } catch (e) {
      setState(() => _error = 'Something went wrong: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, iconTheme: IconThemeData(color: _fg)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Welcome\nback!', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: _fg, height: 1.1, letterSpacing: -1)),
              const SizedBox(height: 8),
              Text('Sign in to your QR Party account', style: TextStyle(fontSize: 16, color: _muted)),
              const SizedBox(height: 36),
              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Colors.redAccent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13))),
                  ]),
                ),
                const SizedBox(height: 16),
              ],
              Text('Email', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _fg)),
              const SizedBox(height: 8),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                style: TextStyle(color: _fg, fontSize: 15),
                cursorColor: AppColors.green,
                decoration: InputDecoration(
                  hintText: 'you@example.com',
                  hintStyle: TextStyle(color: _muted),
                  prefixIcon: Icon(Icons.email_outlined, color: _muted, size: 20),
                  filled: true,
                  fillColor: _card,
                  border:        OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _border)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _border)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.green, width: 1.5)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                ),
              ),
              const SizedBox(height: 20),
              Text('Password', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _fg)),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _login(),
                style: TextStyle(color: _fg, fontSize: 15),
                cursorColor: AppColors.green,
                decoration: InputDecoration(
                  hintText: 'Your password',
                  hintStyle: TextStyle(color: _muted),
                  prefixIcon: Icon(Icons.lock_outline, color: _muted, size: 20),
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined, color: _muted, size: 20),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                  filled: true,
                  fillColor: _card,
                  border:        OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _border)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _border)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.green, width: 1.5)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: GestureDetector(
                  onTap: _isLoading ? null : _sendPasswordReset,
                  child: const Text('Forgot password?', style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w600, fontSize: 14)),
                ),
              ),
              const SizedBox(height: 36),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _login,
                  style: ElevatedButton.styleFrom(backgroundColor: AppColors.green, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                  child: _isLoading
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text('Log In', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 20),
              Center(
                child: GestureDetector(
                  onTap: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const SignUpScreen())),
                  child: RichText(
                    text: TextSpan(
                      text: 'Don\'t have an account? ',
                      style: TextStyle(color: _muted, fontSize: 14),
                      children: const [TextSpan(text: 'Sign up', style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w700))],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Post-signup dialog for Business-tier accounts. Optional — the user
/// can skip and ship the request manually later from the home feed.
///
/// Extracted as a StatefulWidget so the email controller + focus node
/// dispose in State.dispose() instead of after the dialog pops. Same
/// disposal-safety pattern as `_InviteSheet` / `_NotifyAllSheet`
/// elsewhere in the codebase.
///
/// On send: calls the `requestHqLink` Cloud Function (uses admin SDK
/// to bypass the firestore.rules HQ-only invite-create restriction).
/// On success: pops the dialog and shows a green snackbar telling the
/// user the HQ can complete the link via Add Location. On error:
/// surfaces the message inline so the user can edit + retry without
/// losing what they typed.
class _HqLinkDialog extends StatefulWidget {
  const _HqLinkDialog();

  @override
  State<_HqLinkDialog> createState() => _HqLinkDialogState();
}

class _HqLinkDialogState extends State<_HqLinkDialog> {
  final TextEditingController _emailCtrl = TextEditingController();
  final FocusNode _emailFocus = FocusNode();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _emailFocus.dispose();
    super.dispose();
  }

  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;
  Color get _fg     => _isDark ? Colors.white : AppColors.dark;

  Future<void> _send() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      setState(() => _error = "Enter the Headquarters' email");
      return;
    }
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      setState(() => _error = 'That email address looks invalid');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('requestHqLink');
      final res = await callable.call({'hqOrgEmail': email});
      final data = res.data as Map?;
      final hqOrgName = (data?['hqOrgName'] as String?)?.trim();
      final displayName = (hqOrgName != null && hqOrgName.isNotEmpty) ? hqOrgName : 'the Headquarters';
      if (!mounted) return;
      // Pop with the resolved name so the caller can fire the success
      // snackbar on the parent scaffold post-teardown — see
      // _showHqLinkDialog. Avoids using this State's BuildContext
      // across the async gap.
      Navigator.of(context).pop(displayName);
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message ?? 'Could not send the request.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Send failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      contentPadding: const EdgeInsets.fromLTRB(22, 22, 22, 8),
      titlePadding: const EdgeInsets.fromLTRB(22, 22, 22, 8),
      title: Text(
        'Link to a Headquarters?',
        style: TextStyle(fontFamily: 'FredokaOne', fontSize: 20, color: _fg),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Part of a district or council? Enter their email to send a link request.",
            style: TextStyle(fontSize: 14, color: _muted, height: 1.45),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _emailCtrl,
            focusNode: _emailFocus,
            enabled: !_busy,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _send(),
            style: TextStyle(color: _fg, fontSize: 15),
            cursorColor: AppColors.green,
            decoration: InputDecoration(
              hintText: 'hq@example.org',
              hintStyle: TextStyle(color: _muted),
              prefixIcon: Icon(Icons.email_outlined, size: 18, color: _muted),
              filled: true,
              fillColor: _card,
              border:        OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.green, width: 1.5)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ],
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text('Skip for now', style: TextStyle(color: _muted, fontWeight: FontWeight.w700)),
        ),
        ElevatedButton(
          onPressed: _busy ? null : _send,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.green,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Text('Send Request', style: TextStyle(fontWeight: FontWeight.w800)),
        ),
      ],
    );
  }
}
