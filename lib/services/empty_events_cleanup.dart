import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../utils.dart';

/// Finds and (with confirmation) deletes the current user's stale "empty"
/// business events — `accountType` of `business` or `businessPlus`, zero
/// total RSVPs, and `createdAt` more than 24 hours ago.
///
/// Used in two places:
/// 1. Auto-fired once per session when the business home feed loads, with
///    `silentIfNone: true` so users don't see anything when there's nothing
///    to clean up.
/// 2. Manual "Clean up empty events" tile in Settings, with
///    `silentIfNone: false` so users get an explicit "all clean" snackbar.
///
/// Always shows a confirmation dialog before deleting — the host opts in
/// to each batch and can cancel at any time.
class EmptyEventsCleanup {
  static const _ageCutoff = Duration(hours: 24);

  /// Returns the number of events deleted (0 if cancelled or none found).
  static Future<int> run(
    BuildContext context, {
    bool silentIfNone = false,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return 0;

    final cutoff = DateTime.now().subtract(_ageCutoff);
    final List<QueryDocumentSnapshot> candidates;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('events')
          .where('hostId', isEqualTo: uid)
          .get();
      candidates = snap.docs.where((d) => _isCandidate(d, cutoff)).toList();
    } catch (e) {
      debugPrint('[EmptyEventsCleanup] query failed: $e');
      if (!silentIfNone && context.mounted) {
        _toast(context, 'Could not check for empty events: $e', isError: true);
      }
      return 0;
    }

    if (candidates.isEmpty) {
      if (!silentIfNone && context.mounted) {
        _toast(context, 'All clean — no empty events to remove.');
      }
      return 0;
    }

    if (!context.mounted) return 0;
    final confirmed = await _showConfirmDialog(context, candidates);
    if (confirmed != true) return 0;

    var deleted = 0;
    for (final doc in candidates) {
      try {
        await doc.reference.delete();
        deleted++;
      } catch (e) {
        debugPrint('[EmptyEventsCleanup] delete ${doc.id} failed: $e');
      }
    }

    if (context.mounted) {
      _toast(context, 'Deleted $deleted empty event${deleted == 1 ? "" : "s"}.');
    }
    return deleted;
  }

  static bool _isCandidate(QueryDocumentSnapshot doc, DateTime cutoff) {
    final m = doc.data() as Map<String, dynamic>;
    final acct = m['accountType'] as String?;
    if (acct != 'business' && acct != 'businessPlus') return false;
    final yes   = (m['yes']   as num?)?.toInt() ?? 0;
    final maybe = (m['maybe'] as num?)?.toInt() ?? 0;
    final no    = (m['no']    as num?)?.toInt() ?? 0;
    if (yes + maybe + no > 0) return false;
    final created = (m['createdAt'] as Timestamp?)?.toDate();
    if (created == null) return false;
    return created.isBefore(cutoff);
  }

  static Future<bool?> _showConfirmDialog(
    BuildContext ctx,
    List<QueryDocumentSnapshot> docs,
  ) {
    return showDialog<bool>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Clean up empty events?',
            style: TextStyle(
              fontFamily: 'FredokaOne',
              fontSize: 20,
              color: Theme.of(dialogCtx).brightness == Brightness.dark
                  ? Colors.white : AppColors.dark,
            )),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              'These ${docs.length} business event${docs.length == 1 ? "" : "s"} '
              'have no RSVPs and were created more than 24 hours ago. '
              'Deleting them is permanent.',
              style: const TextStyle(fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 14),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final doc in docs) _candidateRow(doc),
                ]),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text('Cancel', style: TextStyle(color: AppColors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(
              'Delete ${docs.length}',
              style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _candidateRow(QueryDocumentSnapshot doc) {
    final m = doc.data() as Map<String, dynamic>;
    final title = (m['title'] as String?) ?? 'Untitled';
    final created = (m['createdAt'] as Timestamp?)?.toDate();
    final age = created == null
        ? '—'
        : _humanAge(DateTime.now().difference(created));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Icon(Icons.delete_outline, size: 14, color: Colors.redAccent),
        ),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
          Text('Created $age ago',
              style: TextStyle(fontSize: 11.5, color: AppColors.muted)),
        ])),
      ]),
    );
  }

  static String _humanAge(Duration d) {
    if (d.inDays >= 1) return '${d.inDays}d';
    if (d.inHours >= 1) return '${d.inHours}h';
    return '${d.inMinutes}m';
  }

  static void _toast(BuildContext ctx, String msg, {bool isError = false}) {
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.redAccent : AppColors.green,
    ));
  }
}
