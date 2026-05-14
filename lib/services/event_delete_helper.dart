import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../utils.dart';
import '../widgets/hold_to_delete_dialog.dart';

/// Shared event-deletion flow for business + org screens. Shows the
/// hold-to-delete confirmation dialog, calls `delete()` on the event
/// doc, and shows a success/error snackbar. The `onEventDeleted` Cloud
/// Function (functions/index.js) handles recursive subcollection
/// cleanup automatically — no extra batched-delete logic needed on the
/// client.
class EventDeleteHelper {
  /// Returns true if the event was deleted, false if cancelled or failed.
  static Future<bool> confirmAndDelete(
    BuildContext context, {
    required String eventId,
    required String eventTitle,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => HoldToDeleteDialog(eventTitle: eventTitle),
    );
    if (confirmed != true) return false;
    if (!context.mounted) return false;

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
