import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── THEME ───────────────────────────────────────────────────
// Light mode is the default for every app launch. Dark mode is a
// session-only preference — toggling it does not write to disk, and
// signing out resets the notifier so the next user lands in light.
// (Any legacy 'theme_mode' key from older builds is wiped on init so
// we don't honour stale persisted state.)
class ThemeNotifier extends ValueNotifier<ThemeMode> {
  ThemeNotifier._() : super(ThemeMode.light);

  static final ThemeNotifier instance = ThemeNotifier._();

  static const _legacyPrefKey = 'theme_mode';

  static Future<void> init() async {
    // Always start light; clean up any persisted preference from older builds.
    instance.value = ThemeMode.light;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(_legacyPrefKey)) {
        await prefs.remove(_legacyPrefKey);
      }
    } catch (_) {/* prefs unavailable — ignore */}
  }

  void toggle() {
    value = value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
  }

  /// Force the app back to light mode — called on logout so the next
  /// user doesn't inherit the previous session's dark toggle.
  void resetToLight() {
    value = ThemeMode.light;
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

class AppNotifications {
  static final List<Map<String, dynamic>> sentNotifications = [];
}

class NotificationService {
  static Future<void> sendNotification(
    List<String> tokens,
    String title,
    String body, {
    String? eventId,
  }) async {
    if (tokens.isEmpty) return;
    await FirebaseFirestore.instance.collection('notificationQueue').add({
      'tokens': tokens,
      'title': title,
      'body': body,
      if (eventId != null) 'eventId': eventId,
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
void showComingSoon(BuildContext context, String feature) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$feature coming soon!'), backgroundColor: AppColors.green, behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))));
}

Widget debugLabel(String label) => Padding(
      padding: const EdgeInsets.all(10),
      child: Text(label, style: const TextStyle(fontSize: 10, color: AppColors.muted), textAlign: TextAlign.center),
    );
