import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../utils.dart';

/// Shared event-deletion flow for business + org screens. Shows a
/// confirmation dialog ("Are you sure you want to delete X?"), calls
/// `delete()` on the event doc, and shows a success/error snackbar. The
/// `onEventDeleted` Cloud Function (functions/index.js) handles recursive
/// subcollection cleanup automatically — no extra batched-delete logic
/// needed on the client.
class EventDeleteHelper {
  /// Returns true if the event was deleted, false if cancelled or failed.
  static Future<bool> confirmAndDelete(
    BuildContext context, {
    required String eventId,
    required String eventTitle,
  }) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : AppColors.dark;
    final card = isDark ? const Color(0xFF383B56) : Colors.white;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Delete this event?',
          style: TextStyle(
            fontFamily: 'FredokaOne', fontSize: 20, color: fg,
          ),
        ),
        content: Text(
          'Are you sure you want to delete "$eventTitle"? This cannot be undone.',
          style: TextStyle(
            fontFamily: 'Nunito', fontSize: 14, color: fg.withValues(alpha: 0.85), height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: AppColors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;

    try {
      await FirebaseFirestore.instance.collection('events').doc(eventId).delete();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Deleted "$eventTitle"'),
          backgroundColor: AppColors.green,
        ));
      }
      return true;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not delete: $e'),
          backgroundColor: Colors.redAccent,
        ));
      }
      return false;
    }
  }

  /// UI-side permission check — mirrors the firestore.rules so we don't
  /// surface a Delete button that would just fail with permission-denied.
  /// Pass the event's `hostId` and (optional) `orgId` from the event doc,
  /// plus the current user's UID and (if known) the orgId of an org they
  /// own. Returns true when the user can delete.
  static bool canDelete({
    required String? hostId,
    required String? eventOrgId,
    required String? myUid,
    String? myOwnedOrgId,
    bool isAdmin = false,
  }) {
    if (myUid == null) return false;
    if (hostId == myUid) return true;
    if (isAdmin) return true;
    if (myOwnedOrgId != null && eventOrgId != null && myOwnedOrgId == eventOrgId) {
      return true;
    }
    return false;
  }
}
