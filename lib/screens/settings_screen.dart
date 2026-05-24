import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import '../utils.dart';
import 'welcome_screen.dart';
import 'business_upgrade_screen.dart';
import 'order_status_screen.dart';
import '../services/empty_events_cleanup.dart';

// Flip to `false` to re-enable real purchases.
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

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _hostNotifications  = true;
  bool _guestNotifications = true;
  Map<String, dynamic> _userData = {};
  StreamSubscription<DocumentSnapshot>? _userSub;

  // Theme-aware color getters — resolve light vs dark variant from the current Theme.
  // Note: this file has a `_card(...)` widget builder method, so the card-color
  // getter is named `_cardColor` to avoid a collision.
  bool  get _isDark    => Theme.of(context).brightness == Brightness.dark;
  Color get _bg        => _isDark ? _bgDark     : _bgLight;
  Color get _cardColor => _isDark ? _cardDark   : _cardLight;
  Color get _border    => _isDark ? _borderDark : _borderLight;
  Color get _muted     => _isDark ? _mutedDark  : _mutedLight;

  @override
  void initState() {
    super.initState();
    _subscribeToUserData();
  }

  @override
  void dispose() {
    _userSub?.cancel();
    super.dispose();
  }

  void _subscribeToUserData() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _userSub = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots()
        .listen((snap) {
      if (mounted) setState(() => _userData = snap.data() ?? {});
    });
  }

  Future<void> _switchView(bool preferBusiness) async {
    await ViewPreferenceNotifier.instance.set(preferBusiness);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(preferBusiness ? 'Switched to Business View' : 'Switched to Personal View'),
      backgroundColor: AppColors.green,
      behavior: SnackBarBehavior.floating,
    ));
    // Return to HomeRouter; ValueListenableBuilder there picks up the change.
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _showStorageUpgrade(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: _cardColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      isScrollControlled: true,
      builder: (_) => _StorageUpgradeSheet(currentPurchase: _userData['storagePurchase'] as String?),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final initials = user?.displayName?.isNotEmpty == true
        ? user!.displayName!.trim().split(' ').take(2).map((p) => p.isNotEmpty ? p[0].toUpperCase() : '').join()
        : '?';

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _cardColor,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Text('Settings', style: TextStyle(fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            // ── ACCOUNT ─────────────────────────────────────
            _sectionHeader('Account'),
            _card([
              // Profile header row
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(children: [
                  Container(
                    width: 52, height: 52,
                    decoration: BoxDecoration(color: AppColors.green.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
                    child: Center(child: Text(initials, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.green))),
                  ),
                  const SizedBox(width: 14),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(user?.displayName ?? 'Your Name', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
                    Text(user?.email ?? '', style: TextStyle(fontSize: 13, color: _muted)),
                  ])),
                ]),
              ),
              _divider(),
              _tile(context, Icons.person_outline,       'Edit Profile',     null, _showEditProfileDialog),
              _divider(),
              _tile(context, Icons.mail_outline,         'Update Email',     null, _showUpdateEmailDialog),
              _divider(),
              _tile(context, Icons.lock_outline,         'Change Password',  null, _showChangePasswordDialog),
              _divider(),
              _tile(context, Icons.location_on_outlined, 'Update Zip Code',  null, _showUpdateZipCodeDialog),
              _divider(),
              Builder(builder: (ctx) {
                final accountType = _userData['accountType'] as String?;
                final isBusinessLike = accountType == 'business' || accountType == 'businessPlus';
                if (!isBusinessLike) {
                  return _tile(context, Icons.swap_horiz_outlined, 'Switch Account', 'Coming soon', () => showComingSoon(context, 'Switch Account'));
                }
                return ValueListenableBuilder<bool>(
                  valueListenable: ViewPreferenceNotifier.instance,
                  builder: (_, preferBusiness, _) => _tile(
                    ctx,
                    Icons.swap_horiz_outlined,
                    preferBusiness ? 'Switch to Personal View' : 'Switch to Business View',
                    preferBusiness ? 'Currently viewing as Business' : 'Currently viewing as Personal',
                    () => _switchView(!preferBusiness),
                  ),
                );
              }),
              // Business / Headquarters IAP subscriptions aren't live on
              // iOS yet — hide the upsell tile + its leading divider so
              // there's no orphan rule between the prior content and the
              // next section. Same gate-pattern as the storage section.
              if (!Platform.isIOS) ...[
                _divider(),
                Builder(builder: (ctx) {
                  final accountType = _userData['accountType'] as String?;
                  final isBusinessLike = accountType == 'business' || accountType == 'businessPlus';
                  if (isBusinessLike) {
                    // Already on a business plan — no upsell needed.
                    return const SizedBox.shrink();
                  }
                  return ListTile(
                    leading: const Text('✨', style: TextStyle(fontSize: 20)),
                    title: const Text('Upgrade to Business ✨', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _purple)),
                    subtitle: Text('Unlock pro tools & analytics', style: TextStyle(fontSize: 12, color: _muted)),
                    trailing: const Icon(Icons.chevron_right, color: _purple, size: 20),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BusinessUpgradeScreen())),
                  );
                }),
              ],
            ]),

            // ── ORDERS ──────────────────────────────────────
            _sectionHeader('Orders'),
            _card([
              _tile(
                context,
                Icons.local_shipping_outlined,
                'My Orders',
                'Stickers, invitations & tracking',
                () => Navigator.push(context, MaterialPageRoute(builder: (_) => const OrderStatusScreen())),
              ),
              // Manual trigger for the same sweep that runs once per session
              // when the business home feed loads. Only useful for accounts
              // that can create business events, so we hide it for personal.
              Builder(builder: (ctx) {
                final acct = _userData['accountType'] as String?;
                if (acct != 'business' && acct != 'businessPlus') {
                  return const SizedBox.shrink();
                }
                return Column(children: [
                  _divider(),
                  _tile(
                    ctx,
                    Icons.cleaning_services_outlined,
                    'Clean up empty events',
                    'Remove business events with no RSVPs older than 24h',
                    () => EmptyEventsCleanup.run(ctx, silentIfNone: false),
                  ),
                ]);
              }),
            ]),

            // ── STORAGE ─────────────────────────────────────
            _sectionHeader('Storage'),
            _card([
              Padding(
                padding: const EdgeInsets.all(16),
                child: Builder(builder: (ctx) {
                  final limit = (_userData['archivedEventLimit'] as int?) ?? 20;
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text('Events used', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : AppColors.dark)),
                      Text('0 / $limit', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.green)),
                    ]),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: const LinearProgressIndicator(
                        value: 0,
                        minHeight: 7,
                        backgroundColor: AppColors.greenPale,
                        valueColor: AlwaysStoppedAnimation<Color>(AppColors.green),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('0 of $limit archived events used', style: TextStyle(fontSize: 12, color: _muted)),
                  ]);
                }),
              ),
              // Storage upgrade IAP products aren't live on iOS yet — hide
              // the entire Upgrade Storage row (and its leading divider so
              // there's no orphan rule between the progress card and the
              // next section). The events-used progress bar above stays
              // visible on both platforms so users can still see their
              // archived-event count.
              if (!Platform.isIOS) ...[
                _divider(),
                Builder(builder: (ctx) {
                  final purchase = _userData['storagePurchase'] as String?;
                  if (purchase == 'storage_50_events') {
                    return _tile(ctx, Icons.workspace_premium_outlined, 'Storage Upgraded', '50 events · Max tier', null);
                  }
                  return _tile(
                    ctx,
                    Icons.workspace_premium_outlined,
                    'Upgrade Storage',
                    purchase == 'storage_25_events' ? '25 events · Tap to upgrade to 50' : 'More archived events · from \$4.99',
                    () => _showStorageUpgrade(ctx),
                  );
                }),
              ],
            ]),

            // ── APPEARANCE ───────────────────────────────────
            _sectionHeader('Appearance'),
            _card([
              ValueListenableBuilder<ThemeMode>(
                valueListenable: ThemeNotifier.instance,
                builder: (context, mode, _) {
                  // For mode==system, fall back to the device brightness
                  // so the toggle reflects what the user actually sees.
                  // Without this, a fresh install on a dark-themed phone
                  // would show "Using light theme" even though the app
                  // is rendering dark.
                  final effectiveDark = mode == ThemeMode.dark
                      || (mode == ThemeMode.system
                          && MediaQuery.platformBrightnessOf(context) == Brightness.dark);
                  return _toggleTile(
                    effectiveDark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
                    'Dark Mode',
                    mode == ThemeMode.system
                        ? (effectiveDark ? 'Following system (dark)' : 'Following system (light)')
                        : (effectiveDark ? 'Using dark theme' : 'Using light theme'),
                    effectiveDark,
                    (_) { ThemeNotifier.instance.toggle(currentlyDark: effectiveDark); },
                  );
                },
              ),
            ]),

            // ── NOTIFICATIONS ────────────────────────────────
            _sectionHeader('Notifications'),
            _card([
              _toggleTile(
                Icons.campaign_outlined,
                'Host notifications',
                'When guests RSVP to your events',
                _hostNotifications,
                (v) => setState(() => _hostNotifications = v),
              ),
              _divider(),
              _toggleTile(
                Icons.notifications_outlined,
                'Guest notifications',
                'Event updates and reminders',
                _guestNotifications,
                (v) => setState(() => _guestNotifications = v),
              ),
            ]),

            // ── PRIVACY ──────────────────────────────────────
            _sectionHeader('Privacy'),
            _card([
              _tile(context, Icons.download_outlined,    'Download My Data', null, () => showComingSoon(context, 'Download My Data')),
              _divider(),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 22),
                title: const Text('Delete Account', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: Colors.redAccent)),
                trailing: Icon(Icons.chevron_right, color: _muted, size: 20),
                onTap: () => _confirmDeleteAccount(context),
              ),
            ]),

            // ── ABOUT ────────────────────────────────────────
            _sectionHeader('About'),
            _card([
              _tile(context, Icons.info_outline,          'App Version',       '1.0.0',         null),
              _divider(),
              _tile(context, Icons.privacy_tip_outlined,  'Privacy Policy',    null,            () => showComingSoon(context, 'Privacy Policy')),
              _divider(),
              _tile(context, Icons.gavel_outlined,        'Terms of Service',  null,            () => showComingSoon(context, 'Terms of Service')),
              _divider(),
              _tile(context, Icons.mail_outline,          'Contact Us',        'privacy@partywithqr.com', () => showComingSoon(context, 'Contact Us')),
            ]),

            // ── LOG OUT ──────────────────────────────────────
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                decoration: BoxDecoration(color: _cardColor, borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3))),
                child: ListTile(
                  leading: const Icon(Icons.logout, color: Colors.redAccent),
                  title: const Text('Log Out', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600, fontSize: 15)),
                  onTap: () async {
                    await FirebaseAuth.instance.signOut();
                    // Theme preference is per-device, not per-account, so
                    // we leave the dark/light state alone on logout. Next
                    // sign-in inherits whatever the previous user picked.
                    if (context.mounted) {
                      Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const WelcomeScreen()), (_) => false);
                    }
                  },
                ),
              ),
            ),

            const SizedBox(height: 28),
            Center(child: Text('© 2026 QR Party LLC · www.partywithqr.com', style: TextStyle(fontSize: 11, color: _muted))),
            const SizedBox(height: 24),
          ],
        ),
      ),
      bottomNavigationBar: debugLabel('Screen 13 — Host View'),
    );
  }

  Widget _sectionHeader(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Text(label.toUpperCase(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _muted, letterSpacing: 1.2)),
      );

  Widget _card(List<Widget> children) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Material(
          color: _cardColor,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
            ),
            child: Column(children: children),
          ),
        ),
      );

  Widget _tile(BuildContext context, IconData icon, String title, String? subtitle, VoidCallback? onTap) => ListTile(
        leading: Icon(icon, color: AppColors.green, size: 22),
        title: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: _isDark ? Colors.white : AppColors.dark)),
        subtitle: subtitle != null ? Text(subtitle, style: TextStyle(fontSize: 12, color: _muted)) : null,
        trailing: onTap != null ? Icon(Icons.chevron_right, color: _muted, size: 20) : null,
        onTap: onTap,
      );

  Widget _toggleTile(IconData icon, String title, String subtitle, bool value, ValueChanged<bool> onChanged) => ListTile(
        leading: Icon(icon, color: AppColors.green, size: 22),
        title: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: _isDark ? Colors.white : AppColors.dark)),
        subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: _muted)),
        // Tapping the row also toggles, matching user expectation when tapping the label text.
        onTap: () => onChanged(!value),
        trailing: Switch(
          value: value,
          onChanged: onChanged,
          activeTrackColor: AppColors.green,
          activeThumbColor: Colors.white,
        ),
      );

  Widget _divider() => const Divider(height: 1, indent: 56, endIndent: 0);

  // ── PROFILE / ACCOUNT EDIT DIALOGS ─────────────────────────────

  Future<void> _showEditProfileDialog() async {
    final accountType = _userData['accountType'] as String?;
    final isPersonal  = accountType != 'business' && accountType != 'businessPlus';
    final firstCtrl = TextEditingController(text: (_userData['firstName'] as String?) ?? '');
    final lastCtrl  = TextEditingController(text: (_userData['lastName']  as String?) ?? '');
    final orgCtrl   = TextEditingController(text: (_userData['name']      as String?) ?? '');
    String? localError;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: _cardColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text('Edit Profile', style: TextStyle(fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            if (isPersonal) ...[
              _dialogField(firstCtrl, 'First name', Icons.person_outline, textCapitalization: TextCapitalization.words),
              const SizedBox(height: 12),
              _dialogField(lastCtrl, 'Last name', Icons.person_outline, textCapitalization: TextCapitalization.words),
            ] else
              _dialogField(
                orgCtrl,
                accountType == 'business' ? 'Business name' : 'Organization name',
                Icons.business_outlined,
                textCapitalization: TextCapitalization.words,
              ),
            if (localError != null) ...[
              const SizedBox(height: 8),
              Text(localError!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: _muted))),
            TextButton(
              onPressed: () async {
                final first   = firstCtrl.text.trim();
                final last    = lastCtrl.text.trim();
                final orgName = orgCtrl.text.trim();
                if (isPersonal) {
                  if (first.isEmpty || last.isEmpty) {
                    setLocal(() => localError = 'Both fields required');
                    return;
                  }
                } else {
                  if (orgName.isEmpty) {
                    setLocal(() => localError = 'Name required');
                    return;
                  }
                }
                try {
                  final user = FirebaseAuth.instance.currentUser;
                  if (user == null) { Navigator.pop(ctx, 'error'); return; }
                  final displayName = isPersonal ? '$first $last' : orgName;
                  await user.updateDisplayName(displayName);
                  await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
                    'firstName': isPersonal ? first : '',
                    'lastName':  isPersonal ? last  : '',
                    'name':      displayName,
                  });
                  if (ctx.mounted) Navigator.pop(ctx, 'saved');
                } catch (e) {
                  setLocal(() => localError = 'Could not save: $e');
                }
              },
              child: const Text('Save', style: TextStyle(color: _purple, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );

    firstCtrl.dispose();
    lastCtrl.dispose();
    orgCtrl.dispose();
    if (result == 'saved' && mounted) _snack('✓ Profile updated', ok: true);
  }

  Future<void> _showUpdateEmailDialog() async {
    final currentEmail = FirebaseAuth.instance.currentUser?.email ?? '';
    final emailCtrl = TextEditingController(text: currentEmail);
    String? localError;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: _cardColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text('Update Email', style: TextStyle(fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              "We'll send a verification link to the new address — your email switches once you click it.",
              style: TextStyle(color: _muted, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 14),
            _dialogField(emailCtrl, 'New email', Icons.mail_outline, keyboardType: TextInputType.emailAddress),
            if (localError != null) ...[
              const SizedBox(height: 8),
              Text(localError!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: _muted))),
            TextButton(
              onPressed: () async {
                final email = emailCtrl.text.trim();
                if (email.isEmpty || !email.contains('@') || !email.contains('.')) {
                  setLocal(() => localError = 'Enter a valid email');
                  return;
                }
                if (email == currentEmail) {
                  setLocal(() => localError = 'That is your current email');
                  return;
                }
                try {
                  final user = FirebaseAuth.instance.currentUser;
                  if (user == null) { Navigator.pop(ctx, 'error'); return; }
                  // Modern API — sends a verification link; Firebase applies the
                  // change after the user clicks it. Avoids the deprecated
                  // updateEmail() API and its insecure behaviour.
                  await user.verifyBeforeUpdateEmail(email);
                  if (ctx.mounted) Navigator.pop(ctx, 'saved');
                } on FirebaseAuthException catch (e) {
                  final msg = switch (e.code) {
                    'requires-recent-login' => 'Please log out and sign back in before changing your email.',
                    'invalid-email'         => 'That email looks invalid.',
                    'email-already-in-use'  => 'That email is in use by another account.',
                    _                       => e.message ?? 'Could not update email.',
                  };
                  setLocal(() => localError = msg);
                } catch (e) {
                  setLocal(() => localError = 'Could not update: $e');
                }
              },
              child: const Text('Send Verification', style: TextStyle(color: _purple, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );

    emailCtrl.dispose();
    if (result == 'saved' && mounted) _snack('✓ Verification email sent — click the link to finish', ok: true);
  }

  Future<void> _showChangePasswordDialog() async {
    final newCtrl     = TextEditingController();
    final confirmCtrl = TextEditingController();
    String? localError;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: _cardColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text('Change Password', style: TextStyle(fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            _dialogField(newCtrl, 'New password (min. 6 characters)', Icons.lock_outline, obscureText: true),
            const SizedBox(height: 12),
            _dialogField(confirmCtrl, 'Confirm password', Icons.lock_outline, obscureText: true),
            if (localError != null) ...[
              const SizedBox(height: 8),
              Text(localError!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: _muted))),
            TextButton(
              onPressed: () async {
                final pw = newCtrl.text;
                final confirm = confirmCtrl.text;
                if (pw.length < 6) {
                  setLocal(() => localError = 'Password must be at least 6 characters');
                  return;
                }
                if (pw != confirm) {
                  setLocal(() => localError = 'Passwords do not match');
                  return;
                }
                try {
                  final user = FirebaseAuth.instance.currentUser;
                  if (user == null) { Navigator.pop(ctx, 'error'); return; }
                  await user.updatePassword(pw);
                  if (ctx.mounted) Navigator.pop(ctx, 'saved');
                } on FirebaseAuthException catch (e) {
                  final msg = switch (e.code) {
                    'requires-recent-login' => 'Please log out and sign back in before changing your password.',
                    'weak-password'         => 'That password is too weak.',
                    _                       => e.message ?? 'Could not update password.',
                  };
                  setLocal(() => localError = msg);
                } catch (e) {
                  setLocal(() => localError = 'Could not update: $e');
                }
              },
              child: const Text('Save', style: TextStyle(color: _purple, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );

    newCtrl.dispose();
    confirmCtrl.dispose();
    if (result == 'saved' && mounted) _snack('✓ Password updated', ok: true);
  }

  Future<void> _showUpdateZipCodeDialog() async {
    final zipCtrl = TextEditingController(text: (_userData['zipCode'] as String?) ?? '');
    String? localError;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: _cardColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text('Update Zip Code', style: TextStyle(fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              'Used to show you local events nearby and for the weather widget.',
              style: TextStyle(color: _muted, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 14),
            _dialogField(zipCtrl, 'Zip code', Icons.location_on_outlined, keyboardType: TextInputType.number),
            if (localError != null) ...[
              const SizedBox(height: 8),
              Text(localError!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: _muted))),
            TextButton(
              onPressed: () async {
                final zip = zipCtrl.text.trim();
                if (!RegExp(r'^\d{5}$').hasMatch(zip)) {
                  setLocal(() => localError = 'Enter a 5-digit zip code');
                  return;
                }
                try {
                  final user = FirebaseAuth.instance.currentUser;
                  if (user == null) { Navigator.pop(ctx, 'error'); return; }
                  await FirebaseFirestore.instance.collection('users').doc(user.uid).update({'zipCode': zip});
                  if (ctx.mounted) Navigator.pop(ctx, 'saved');
                } catch (e) {
                  setLocal(() => localError = 'Could not save: $e');
                }
              },
              child: const Text('Save', style: TextStyle(color: _purple, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );

    zipCtrl.dispose();
    if (result == 'saved' && mounted) _snack('✓ Zip code updated', ok: true);
  }

  // ── dialog helpers ─────────────────────────────────────────────

  Widget _dialogField(
    TextEditingController ctrl,
    String label,
    IconData icon, {
    bool obscureText = false,
    TextInputType? keyboardType,
    TextCapitalization textCapitalization = TextCapitalization.none,
  }) {
    final fg = _isDark ? Colors.white : AppColors.dark;
    return TextField(
      controller: ctrl,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
      style: TextStyle(color: fg, fontSize: 15),
      cursorColor: _purple,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: _muted),
        prefixIcon: Icon(icon, color: _muted, size: 20),
        filled: true,
        fillColor: _bg,
        border:        OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _purple, width: 1.5)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }

  void _snack(String msg, {required bool ok}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: ok ? AppColors.green : Colors.redAccent,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  void _confirmDeleteAccount(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Delete account?'),
        content: const Text('This permanently deletes your account and all your events. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () { Navigator.pop(context); showComingSoon(context, 'Delete Account'); },
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}

// ─── STORAGE UPGRADE SHEET ───────────────────────────────────────────────────

class _StorageUpgradeSheet extends StatefulWidget {
  final String? currentPurchase;
  const _StorageUpgradeSheet({this.currentPurchase});
  @override
  State<_StorageUpgradeSheet> createState() => _StorageUpgradeSheetState();
}

class _StorageUpgradeSheetState extends State<_StorageUpgradeSheet> {
  bool _loading = true;
  bool _purchasing = false;
  Map<String, ProductDetails> _products = {};

  // Theme-aware color getters — resolve light vs dark variant from the current Theme.
  bool  get _isDark    => Theme.of(context).brightness == Brightness.dark;
  Color get _cardColor => _isDark ? _cardDark   : _cardLight;
  Color get _border    => _isDark ? _borderDark : _borderLight;
  Color get _muted     => _isDark ? _mutedDark  : _mutedLight;

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  Future<void> _loadProducts() async {
    try {
      final available = await InAppPurchase.instance.isAvailable();
      if (!available) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final response = await InAppPurchase.instance.queryProductDetails({'storage_25_events', 'storage_50_events'});
      if (mounted) {
        setState(() {
          _loading = false;
          _products = {for (final p in response.productDetails) p.id: p};
        });
      }
    } catch (_) {
      // Any throw (store unavailable, network blip, plugin error) lands
      // in the same empty-products branch as a clean "not available"
      // — the iOS-specific friendly message in build() handles both.
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _buy(String productId) async {
    final product = _products[productId];
    if (product == null) return;
    setState(() => _purchasing = true);
    try {
      await InAppPurchase.instance.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: product));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start purchase: $e'), backgroundColor: Colors.redAccent),
        );
        setState(() => _purchasing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: _border, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 20),
          Text('Upgrade Storage', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _isDark ? Colors.white : AppColors.dark)),
          const SizedBox(height: 4),
          Text('Permanently increase your archived event limit', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: _muted)),
          const SizedBox(height: 24),
          if (_loading)
            const CircularProgressIndicator(color: AppColors.green)
          else if (_products.isEmpty) ...[
            // Empty-products branch covers all IAP failure modes
            // uniformly: store unavailable, products not yet
            // propagated through review, plugin error. App Store
            // reviewer rejected the prior platform-specific copy
            // ("…coming soon to iOS…") under Guideline 2.3.10 (no
            // mentions of other platforms). Keep the message generic
            // on both platforms.
            Text(
              Platform.isIOS
                  ? 'Upgrade your storage to archive more events.'
                  : 'Store unavailable. Try again later.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: _muted, height: 1.4),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.green,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('Got it', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              ),
            ),
          ] else ...[
            _optionTile('storage_25_events', '25 Events', '+5 more archived events'),
            const SizedBox(height: 12),
            _optionTile('storage_50_events', '50 Events', '+30 more archived events · Best value'),
          ],
          const SizedBox(height: 20),
          Text('One-time purchase · No subscription · QR Party LLC', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: _muted)),
        ],
      ),
    );
  }

  Widget _optionTile(String productId, String title, String subtitle) {
    final product = _products[productId];
    final owned = widget.currentPurchase == productId;
    final higherOwned = productId == 'storage_25_events' && widget.currentPurchase == 'storage_50_events';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: owned ? AppColors.greenPale : _cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: owned ? AppColors.green : _border),
      ),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _isDark ? Colors.white : AppColors.dark)),
          Text(subtitle, style: TextStyle(fontSize: 12, color: _muted)),
        ])),
        const SizedBox(width: 12),
        if (owned || higherOwned)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: AppColors.greenPale, borderRadius: BorderRadius.circular(20)),
            child: const Text('Owned ✓', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.green)),
          )
        else
          ElevatedButton(
            onPressed: kTestingMode || _purchasing ? null : () => _buy(productId),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.green,
              foregroundColor: Colors.white,
              disabledBackgroundColor: _border,
              disabledForegroundColor: _muted,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            child: kTestingMode
                ? const Text('Coming Soon', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))
                : _purchasing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : Text(product?.price ?? '—', style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
      ]),
    );
  }
}
