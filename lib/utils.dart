import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── THEME ───────────────────────────────────────────────────
// Dark mode is a per-device preference. On a true fresh install (no key
// written yet) we default to [ThemeMode.light] — the brand and
// onboarding visuals are designed light-first, and forcing light avoids
// surprising new users whose phone is set to dark before they've had a
// chance to opt in. The first explicit toggle in Settings writes a hard
// preference; from that point on, the saved value wins forever.
//
// Storage key 'darkMode' (bool). Absence = light default; true = dark;
// false = light. Earlier installs wrote nothing and used a legacy
// `theme_mode` string key — `init()` wipes that key on first run for
// cleanliness.
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
      // No saved value → default to light. Saved value → hard light/dark.
      // Fresh installs always launch in light mode regardless of the OS
      // theme; users can flip to dark via the Settings toggle, which
      // writes a hard preference and from then on the saved value wins.
      if (!prefs.containsKey(_prefKey)) {
        instance.value = ThemeMode.light;
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

// Single source of truth for one EventType per name. Used as a fallback
// pool when rendering legacy events whose saved type isn't in the
// caller's tier-filtered picker (see [personalEventTypes] /
// [businessEventTypes]). Keep "Custom" last in [eventTypes] — every
// `firstWhere` that uses `orElse: () => eventTypes.last` relies on
// that for unknown types to render with the Custom card visuals.
const EventType _typeBirthday          = EventType(name: 'Birthday',           emoji: '🎂', primary: Color(0xFFE91E8C), secondary: Color(0xFFFF6BB5), accent: Color(0xFFFFD700), suggestion: "Sarah's Birthday Bash");
const EventType _typeWedding           = EventType(name: 'Wedding',            emoji: '💍', primary: Color(0xFF8B6F5E), secondary: Color(0xFFD4B896), accent: Color(0xFFF8F0E8), suggestion: "Mike & Emily's Wedding");
const EventType _typeGraduation        = EventType(name: 'Graduation',         emoji: '🎓', primary: Color(0xFF1A237E), secondary: Color(0xFF3949AB), accent: Color(0xFFFFD700), suggestion: "Class of 2026 Graduation");
const EventType _typeBabyShower        = EventType(name: 'Baby Shower',        emoji: '🍼', primary: Color(0xFF00897B), secondary: Color(0xFF80CBC4), accent: Color(0xFFFCE4EC), suggestion: "Baby Shower for Emma");
const EventType _typeAnniversary       = EventType(name: 'Anniversary',        emoji: '💖', primary: Color(0xFFC2185B), secondary: Color(0xFFEC407A), accent: Color(0xFFFFD700), suggestion: "Our 10-Year Anniversary");
const EventType _typeHolidayParty      = EventType(name: 'Holiday Party',      emoji: '🎄', primary: Color(0xFF1B5E20), secondary: Color(0xFF43A047), accent: Color(0xFFE53935), suggestion: "Holiday Gathering 2026");
const EventType _typeRetirement        = EventType(name: 'Retirement',         emoji: '🥂', primary: Color(0xFF4A148C), secondary: Color(0xFF7B1FA2), accent: Color(0xFFFFD700), suggestion: "Pat's Retirement Party");
const EventType _typeEngagement        = EventType(name: 'Engagement',         emoji: '💍', primary: Color(0xFFAD1457), secondary: Color(0xFFE91E63), accent: Color(0xFFF8BBD0), suggestion: "Engagement Celebration");
const EventType _typeReunion           = EventType(name: 'Reunion',            emoji: '🎈', primary: Color(0xFF1565C0), secondary: Color(0xFF42A5F5), accent: Color(0xFFFFC107), suggestion: "Class of '95 Reunion");
const EventType _typeCustom            = EventType(name: 'Custom',             emoji: '🎨', primary: Color(0xFF52796F), secondary: Color(0xFF84A98C), accent: Color(0xFF9C7FD4), suggestion: "My Special Event");

const EventType _typeFundraiser        = EventType(name: 'Fundraiser',         emoji: '🎗️', primary: Color(0xFFB71C1C), secondary: Color(0xFFEF5350), accent: Color(0xFFFFD600), suggestion: "Annual Fundraiser");
const EventType _typeSchoolEvent       = EventType(name: 'School Event',       emoji: '🏫', primary: Color(0xFF1565C0), secondary: Color(0xFF42A5F5), accent: Color(0xFFFFD54F), suggestion: "Spring Carnival");
const EventType _typeCommunityMeeting  = EventType(name: 'Community Meeting',  emoji: '🤝', primary: Color(0xFF00695C), secondary: Color(0xFF26A69A), accent: Color(0xFFFFCA28), suggestion: "Town Hall Meeting");
const EventType _typeGrandOpening      = EventType(name: 'Grand Opening',      emoji: '🎊', primary: Color(0xFFC2185B), secondary: Color(0xFFEC407A), accent: Color(0xFFFFD700), suggestion: "Grand Opening Day");
const EventType _typeNetworkingEvent   = EventType(name: 'Networking Event',   emoji: '💼', primary: Color(0xFF263238), secondary: Color(0xFF546E7A), accent: Color(0xFF00BCD4), suggestion: "Q2 Networking Mixer");
const EventType _typeWorkshop          = EventType(name: 'Workshop',           emoji: '🛠️', primary: Color(0xFF6D4C41), secondary: Color(0xFF8D6E63), accent: Color(0xFFFFB300), suggestion: "Hands-On Workshop");
const EventType _typeVolunteerEvent    = EventType(name: 'Volunteer Event',    emoji: '🌱', primary: Color(0xFF2E7D32), secondary: Color(0xFF66BB6A), accent: Color(0xFFFFEB3B), suggestion: "Community Cleanup");
const EventType _typeAppreciationEvent = EventType(name: 'Appreciation Event', emoji: '🏆', primary: Color(0xFF6A1B9A), secondary: Color(0xFFAB47BC), accent: Color(0xFFFFC400), suggestion: "Volunteer Appreciation");

// Legacy types kept solely for rendering historical events whose
// saved name predates the personal/business split. Not pickable from
// any new-event picker; the grid only iterates the tier-specific
// lists. Removing these would silently downgrade legacy doc visuals
// to the Custom card.
const EventType _typeLegacyParty         = EventType(name: 'Party',         emoji: '🎉', primary: Color(0xFF6A1B9A), secondary: Color(0xFFAB47BC), accent: Color(0xFFFF9800), suggestion: "Epic House Party");
const EventType _typeLegacyCorporate     = EventType(name: 'Corporate',     emoji: '💼', primary: Color(0xFF263238), secondary: Color(0xFF546E7A), accent: Color(0xFF00BCD4), suggestion: "Q2 Team Celebration");
const EventType _typeLegacyDivorceParty  = EventType(name: 'Divorce Party', emoji: '🥂', primary: Color(0xFF4A148C), secondary: Color(0xFF7B1FA2), accent: Color(0xFFFFD700), suggestion: "Freedom Party!");

/// Personal-tier picker list. Iterated by the create-event grid when
/// `accountType` is anything other than `'business'` or `'businessPlus'`.
/// "Custom" stays last so the grid's bottom-right always houses the
/// escape hatch.
const List<EventType> personalEventTypes = [
  _typeBirthday,
  _typeWedding,
  _typeGraduation,
  _typeBabyShower,
  _typeAnniversary,
  _typeHolidayParty,
  _typeRetirement,
  _typeEngagement,
  _typeReunion,
  _typeCustom,
];

/// Business-tier picker list. Iterated by the create-event grid when
/// `accountType == 'business' || == 'businessPlus'`. "Custom" stays
/// last for the same reason as [personalEventTypes].
const List<EventType> businessEventTypes = [
  _typeFundraiser,
  _typeSchoolEvent,
  _typeCommunityMeeting,
  _typeGrandOpening,
  _typeNetworkingEvent,
  _typeWorkshop,
  _typeVolunteerEvent,
  _typeAppreciationEvent,
  _typeCustom,
];

/// Union of every event type across both tiers plus legacy names.
/// Used for *rendering* (not picking) — the home feeds and saved-event
/// renderers do `eventTypes.firstWhere(name == saved, orElse: last)`
/// to look up the visuals for a stored event whose name might not be
/// on the current tier's pickable list.
const List<EventType> eventTypes = [
  _typeBirthday,
  _typeWedding,
  _typeGraduation,
  _typeBabyShower,
  _typeAnniversary,
  _typeHolidayParty,
  _typeRetirement,
  _typeEngagement,
  _typeReunion,
  _typeFundraiser,
  _typeSchoolEvent,
  _typeCommunityMeeting,
  _typeGrandOpening,
  _typeNetworkingEvent,
  _typeWorkshop,
  _typeVolunteerEvent,
  _typeAppreciationEvent,
  _typeLegacyParty,
  _typeLegacyCorporate,
  _typeLegacyDivorceParty,
  _typeCustom,
];

/// Migrates deprecated event-type names so legacy saves still resolve
/// to the right card visuals at render time. Today the only mapping
/// is `'Holiday'` → `'Holiday Party'`. New mappings can be added here
/// without touching call sites.
String migrateEventTypeName(String? saved) {
  if (saved == null) return '';
  if (saved == 'Holiday') return 'Holiday Party';
  return saved;
}

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
