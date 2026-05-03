import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── THEME ───────────────────────────────────────────────────
// Dark mode is a per-device preference. On a true fresh install (no key
// written yet) we follow the OS theme via [ThemeMode.system] — most apps
// behave this way, and it sidesteps the bug where a tester whose phone is
// in dark mode saw the app launch in light and assumed it was broken.
// The first explicit toggle in Settings writes a hard preference; from
// that point on, the saved value wins forever (system theme is no longer
// consulted until the user resets via the toggle).
//
// Storage key 'darkMode' (bool). Absence = system; true = dark; false =
// light. Earlier installs wrote nothing and used a legacy `theme_mode`
// string key — `init()` wipes that key on first run for cleanliness.
class ThemeNotifier extends ValueNotifier<ThemeMode> {
  ThemeNotifier._() : super(ThemeMode.system);

  static final ThemeNotifier instance = ThemeNotifier._();

  static const _prefKey = 'darkMode';
  static const _legacyPrefKey = 'theme_mode';

  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // One-time cleanup of the old string-typed key from the
      // session-only era. Safe no-op if it's not present.
      if (prefs.containsKey(_legacyPrefKey)) {
        await prefs.remove(_legacyPrefKey);
      }
      // No saved value → follow the OS. Saved value → hard light/dark.
      // Distinguishes the "user hasn't picked yet" state from "user
      // explicitly chose light" so we don't override the OS preference
      // on a fresh install just because false is the default.
      if (!prefs.containsKey(_prefKey)) {
        instance.value = ThemeMode.system;
        return;
      }
      final isDark = prefs.getBool(_prefKey) ?? false;
      instance.value = isDark ? ThemeMode.dark : ThemeMode.light;
    } catch (_) {
      // prefs unavailable (e.g. test harness, first-run quirk) — fall
      // back to system so we still match the device. Don't crash.
      instance.value = ThemeMode.system;
    }
  }

  /// Toggle dark/light and write the new value to disk so it survives
  /// app restart and logout. When the current mode is system, [currentlyDark]
  /// resolves the effective appearance from the OS so the toggle flips to
  /// the opposite of what the user is actually seeing.
  Future<void> toggle({required bool currentlyDark}) async {
    value = currentlyDark ? ThemeMode.light : ThemeMode.dark;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, value == ThemeMode.dark);
    } catch (_) {/* prefs unavailable — in-memory toggle still works */}
  }

  bool get isDark => value == ThemeMode.dark;
}

// ─── VIEW PREFERENCE ─────────────────────────────────────────
// Personal vs business home feed for users on a business plan.
// Default true so new business users land on the business feed.
class ViewPreferenceNotifier extends ValueNotifier<bool> {
  ViewPreferenceNotifier._() : super(true);

  static final ViewPreferenceNotifier instance = ViewPreferenceNotifier._();

  static const _prefKey = 'preferBusinessView';

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    instance.value = prefs.getBool(_prefKey) ?? true;
  }

  Future<void> set(bool preferBusiness) async {
    value = preferBusiness;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, preferBusiness);
  }
}

// ─── CONSTANTS ───────────────────────────────────────────────
class AppColors {
  static const green = Color(0xFF52796F);
  static const greenLight = Color(0xFF84A98C);
  static const greenPale = Color(0xFFCAD2C5);
  static const purple = Color(0xFF9C7FD4);
  static const purplePale = Color(0xFFEDE7F6);
  static const gold = Color(0xFFE9C46A);
  static const surface = Color(0xFFF8F7FC);
  static const dark = Color(0xFF2D3047);
  static const muted = Color(0xFF8892A4);
}

// ─── FEATURE FLAGS ───────────────────────────────────────────
// Compile-time toggles for partially-built or beta-gated features.
// Flip these and recompile to (un)expose the feature; the underlying
// data and code paths stay intact so events with old data still work.

/// Hides every user-visible Wishlist entry point in the app — the
/// list-type chooser on event creation, the Wishlist tab on guest
/// view, the wishlist editor on the edit screen, and the wishlist
/// total on past event cards. Checklist remains fully visible and
/// functional. Set to true to expose Wishlist again. No data is
/// destroyed when this is false: events whose `listType` is already
/// `'Wishlist'` simply render as if it were `'No List'` until the
/// host edits them or the flag flips back on.
const bool kWishlistEnabled = true;

/// Hides every user-visible entry point to ordering printed stickers
/// or invitations during beta. Set to true to re-expose the merch
/// flow. The OrderMerchScreen, MerchOrderService, MerchPricing, and
/// admin order tooling all remain intact — only the user-facing CTAs
/// are gated. Existing orders placed before the flag flipped continue
/// to surface in the user's order history; this flag only blocks
/// NEW order creation paths.
const bool kMerchOrderingEnabled = false;

class AppNotifications {
  static final List<Map<String, dynamic>> sentNotifications = [];
}

class NotificationService {
  /// Enqueues a push-notification job for a Cloud Function to fan out.
  ///
  /// `eventId` is required: the firestore.rules rule on
  /// `notificationQueue/{id}` validates that the caller is host/co-host
  /// of the named event, so a missing eventId silently gets rejected
  /// with permission-denied. Callers with a nullable eventId must guard
  /// before calling.
  static Future<void> sendNotification(
    List<String> tokens,
    String title,
    String body, {
    required String eventId,
  }) async {
    if (tokens.isEmpty) return;
    await FirebaseFirestore.instance.collection('notificationQueue').add({
      'tokens': tokens,
      'title': title,
      'body': body,
      'eventId': eventId,
      'timestamp': FieldValue.serverTimestamp(),
      'status': 'pending',
    });
  }
}

// ─── EVENT TYPES ─────────────────────────────────────────────
class EventType {
  final String name;
  final String emoji;
  final Color primary;
  final Color secondary;
  final Color accent;
  final String suggestion;

  const EventType({required this.name, required this.emoji, required this.primary, required this.secondary, required this.accent, required this.suggestion});
}

const List<EventType> eventTypes = [
  EventType(name: 'Birthday', emoji: '🎂', primary: Color(0xFFE91E8C), secondary: Color(0xFFFF6BB5), accent: Color(0xFFFFD700), suggestion: "Sarah's Birthday Bash"),
  EventType(name: 'Wedding', emoji: '💍', primary: Color(0xFF8B6F5E), secondary: Color(0xFFD4B896), accent: Color(0xFFF8F0E8), suggestion: "Mike & Emily's Wedding"),
  EventType(name: 'Graduation', emoji: '🎓', primary: Color(0xFF1A237E), secondary: Color(0xFF3949AB), accent: Color(0xFFFFD700), suggestion: "Class of 2026 Graduation"),
  EventType(name: 'Party', emoji: '🎉', primary: Color(0xFF6A1B9A), secondary: Color(0xFFAB47BC), accent: Color(0xFFFF9800), suggestion: "Epic House Party"),
  EventType(name: 'Baby Shower', emoji: '🍼', primary: Color(0xFF00897B), secondary: Color(0xFF80CBC4), accent: Color(0xFFFCE4EC), suggestion: "Baby Shower for Emma"),
  EventType(name: 'Corporate', emoji: '💼', primary: Color(0xFF263238), secondary: Color(0xFF546E7A), accent: Color(0xFF00BCD4), suggestion: "Q2 Team Celebration"),
  EventType(name: 'Holiday', emoji: '🎄', primary: Color(0xFF1B5E20), secondary: Color(0xFF43A047), accent: Color(0xFFE53935), suggestion: "Holiday Gathering 2026"),
  EventType(name: 'Divorce Party', emoji: '🥂', primary: Color(0xFF4A148C), secondary: Color(0xFF7B1FA2), accent: Color(0xFFFFD700), suggestion: "Freedom Party!"),
  EventType(name: 'Custom', emoji: '✨', primary: Color(0xFF52796F), secondary: Color(0xFF84A98C), accent: Color(0xFF9C7FD4), suggestion: "My Special Event"),
];

// ─── HELPERS ──────────────────────────────────────────────────

/// Returns a version of [base] guaranteed to read against a dark
/// surface. Several event-type primaries (Corporate, Graduation,
/// Holiday, Divorce Party) are dark navies / forests / aubergines —
/// they look great as accents on a white card but disappear when
/// rendered on the dark-mode card (#383B56). When [isDark] is true,
/// the helper lifts the lightness above 0.55 so the color stays
/// recognisable AND visible against the dark surface. In light mode
/// it returns the color unchanged.
///
/// Use this anywhere you'd otherwise paint event-type-tinted text or
/// icons on top of the theme's card surface — date labels in event
/// rows, status chips, shop chip accents, etc.
Color onDarkSurface(Color base, {required bool isDark}) {
  if (!isDark) return base;
  final hsl = HSLColor.fromColor(base);
  final lifted = hsl.lightness < 0.55 ? 0.72 : hsl.lightness;
  return hsl
      .withLightness(lifted.clamp(0.0, 1.0))
      .withSaturation((hsl.saturation * 0.85).clamp(0.0, 1.0))
      .toColor();
}

void showComingSoon(BuildContext context, String feature) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$feature coming soon!'), backgroundColor: AppColors.green, behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))));
}

Widget debugLabel(String label) => Padding(
      padding: const EdgeInsets.all(10),
      child: Text(label, style: const TextStyle(fontSize: 10, color: AppColors.muted), textAlign: TextAlign.center),
    );
