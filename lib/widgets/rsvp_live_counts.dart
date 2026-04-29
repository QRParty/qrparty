import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Streams `events/{eventId}/rsvps` and hands the live (yes, maybe, no)
/// people totals to [builder]. Each total is the sum of every matching
/// rsvp's `adults + children + plusOnes`, falling back to 1 when none of
/// those count fields are present (web-source RSVPs).
///
/// This is the single source of truth for guest-count UI on the home
/// feeds — replaces the earlier reliance on the parent event doc's
/// cached `yes/maybe/no` fields, which can drift out of sync when:
///   • A guest RSVPs via event.html on web (only recently started
///     incrementing the parent counters via a Firestore transaction).
///   • Legacy app RSVPs were written before the increment math
///     included children.
///
/// Usage:
/// ```
/// RsvpLiveCounts(
///   eventId: doc.id,
///   builder: (ctx, yes, maybe, no) => Row(children: [
///     Pill('$yes going'), Pill('$maybe maybe'), Pill('$no no'),
///   ]),
/// )
/// ```
///
/// [initial] (optional) is the cached parent-doc count to render before
/// the snapshot listener fires its first event — avoids a 0-flash on
/// scroll. Pass the cached `event['yes']/['maybe']/['no']` map if you
/// have it; otherwise `(0, 0, 0)` is shown until the stream resolves.
class RsvpLiveCounts extends StatefulWidget {
  final String eventId;
  final Widget Function(BuildContext context, int yes, int maybe, int no) builder;
  final ({int yes, int maybe, int no})? initial;

  const RsvpLiveCounts({
    super.key,
    required this.eventId,
    required this.builder,
    this.initial,
  });

  @override
  State<RsvpLiveCounts> createState() => _RsvpLiveCountsState();
}

class _RsvpLiveCountsState extends State<RsvpLiveCounts> {
  late int _yes   = widget.initial?.yes   ?? 0;
  late int _maybe = widget.initial?.maybe ?? 0;
  late int _no    = widget.initial?.no    ?? 0;
  Stream<QuerySnapshot<Map<String, dynamic>>>? _stream;

  @override
  void initState() {
    super.initState();
    _stream = FirebaseFirestore.instance
        .collection('events')
        .doc(widget.eventId)
        .collection('rsvps')
        .snapshots();
  }

  @override
  void didUpdateWidget(covariant RsvpLiveCounts old) {
    super.didUpdateWidget(old);
    // Re-subscribe if the host swapped which event we're rendering for
    // (e.g. card reuse during a list rebuild).
    if (old.eventId != widget.eventId) {
      _stream = FirebaseFirestore.instance
          .collection('events')
          .doc(widget.eventId)
          .collection('rsvps')
          .snapshots();
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snap) {
        // Use the most recent successful snapshot; on error or while
        // waiting for the first event, retain the prior counts so the
        // pill never flickers to zero.
        if (snap.hasData) {
          var yes = 0, maybe = 0, no = 0;
          for (final doc in snap.data!.docs) {
            final d = doc.data();
            final status = d['status'] as String?;
            if (status == null) continue;
            // Web RSVPs don't carry the count fields → treat as 1
            // person. App RSVPs carry adults/children/plusOnes — sum
            // them. The headcount displayed should be total PEOPLE,
            // not doc count, so a family-of-4 RSVP shows as 4.
            final people = ((d['adults']   as num?)?.toInt() ?? 0) +
                           ((d['children'] as num?)?.toInt() ?? 0) +
                           ((d['plusOnes'] as num?)?.toInt() ?? 0);
            final headcount = people > 0 ? people : 1;
            if      (status == 'Yes')   { yes   += headcount; }
            else if (status == 'Maybe') { maybe += headcount; }
            else if (status == 'No')    { no    += headcount; }
          }
          _yes = yes; _maybe = maybe; _no = no;
        }
        return widget.builder(context, _yes, _maybe, _no);
      },
    );
  }
}
