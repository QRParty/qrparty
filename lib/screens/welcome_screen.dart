import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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
  final _zipController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _error;
  String? _accountType;

  // Theme-aware color getters — resolve light vs dark variant from the current Theme.
  bool  get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg     => _isDark ? _bgDark     : _bgLight;
  Color get _card   => _isDark ? _cardDark   : _cardLight;
  Color get _border => _isDark ? _borderDark : _borderLight;
  Color get _muted  => _isDark ? _mutedDark  : _mutedLight;
  Color get _fg     => _isDark ? Colors.white : AppColors.dark;

  Future<void> _signUp() async {
    if (_firstNameController.text.isEmpty || _lastNameController.text.isEmpty || _emailController.text.isEmpty || _passwordController.text.isEmpty || _zipController.text.isEmpty) {
      setState(() => _error = 'Please fill in all fields');
      return;
    }
    if (_accountType == null) {
      setState(() => _error = 'Please select how you\'ll use QR Party');
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
        // Defensive — should never happen on a successful create, but means we
        // can't write the profile if it does. Surface rather than silently fail.
        throw FirebaseAuthException(code: 'user-null', message: 'Could not create user. Please try again.');
      }
      final firstName = _firstNameController.text.trim();
      final lastName  = _lastNameController.text.trim();
      final fullName  = '$firstName $lastName';
      await newUser.updateDisplayName(fullName);
      final profileData = <String, dynamic>{
        'firstName':   firstName,
        'lastName':    lastName,
        'name':        fullName,
        'email':       _emailController.text.trim(),
        'zipCode':     _zipController.text.trim(),
        'accountType': _accountType,
        'createdAt':   FieldValue.serverTimestamp(),
      };
      if (_accountType == 'business') {
        profileData['isTrialing']     = true;
        profileData['trialStartDate'] = FieldValue.serverTimestamp();
      }
      await FirebaseFirestore.instance
          .collection('users')
          .doc(newUser.uid)
          .set(profileData);
      // Wait for the auth-state stream to actually reflect the new signed-in
      // user. Without this, there's a race where popping back to the navigator
      // root can land on the still-WelcomeScreen home before the stream emits.
      await FirebaseAuth.instance.authStateChanges().firstWhere((u) => u != null);
      // Push HomeRouter as a fresh root route — deterministic, doesn't rely on
      // MaterialApp.home rebuilding at exactly the right moment. HomeRouter
      // reads the user's profile and routes to HomeFeedScreen or
      // BusinessHomeFeedScreen, then overlays the first-login welcome card.
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeRouter()),
        (_) => false,
      );
    } on FirebaseAuthException catch (e) {
      setState(() => _error = e.message ?? 'Could not create account.');
    } catch (e) {
      // Catch-all for Firestore errors, network errors, type errors etc.
      // Without this, every non-Firebase exception was silently swallowed,
      // leaving the user staring at a frozen screen with no feedback.
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
              const SizedBox(height: 20),
              _fieldLabel('Email'),
              _inputField(_emailController, 'you@example.com', Icons.email_outlined, keyboardType: TextInputType.emailAddress, textInputAction: TextInputAction.next, onEditingComplete: () => FocusScope.of(context).nextFocus()),
              const SizedBox(height: 20),
              _fieldLabel('Password'),
              _passwordField(),
              const SizedBox(height: 20),
              _fieldLabel('Zip Code'),
              _inputField(_zipController, 'e.g. 93955', Icons.location_on_outlined, keyboardType: TextInputType.number, textInputAction: TextInputAction.done, onEditingComplete: _signUp),
              const SizedBox(height: 8),
              Text('Used to show you local events nearby', style: TextStyle(fontSize: 12, color: _muted)),
              const SizedBox(height: 28),
              _fieldLabel('How will you use QR Party?'),
              Row(children: [
                Expanded(child: _accountTypeCard('personal', '🎉', 'Personal', 'Hosting parties and\nevents for fun')),
                const SizedBox(width: 12),
                Expanded(child: _accountTypeCard('business', '💼', 'Business', 'Professional event\nplanning')),
              ]),
              const SizedBox(height: 36),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: (_isLoading || _accountType == null) ? null : _signUp,
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

  Widget _accountTypeCard(String type, String emoji, String title, String description) {
    final selected = _accountType == type;
    return GestureDetector(
      onTap: () => setState(() => _accountType = type),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected ? AppColors.green.withValues(alpha: 0.08) : _card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? AppColors.green : _border,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(height: 8),
            Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: selected ? AppColors.green : _fg)),
            const SizedBox(height: 4),
            Text(description, style: TextStyle(fontSize: 12, color: _muted, height: 1.4)),
          ],
        ),
      ),
    );
  }

  Widget _fieldLabel(String label) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _fg)),
      );

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

  Widget _passwordField() => TextField(
        controller: _passwordController,
        obscureText: _obscurePassword,
        textInputAction: TextInputAction.next,
        onSubmitted: (_) => FocusScope.of(context).nextFocus(),
        style: TextStyle(color: _fg, fontSize: 15),
        cursorColor: AppColors.green,
        decoration: InputDecoration(
          hintText: 'Min. 6 characters',
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
      );
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
                  onTap: () => showComingSoon(context, 'Password reset'),
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
