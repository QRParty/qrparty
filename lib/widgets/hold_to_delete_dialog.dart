import 'package:flutter/material.dart';
import '../utils.dart';

/// Confirmation dialog that requires a deliberate 2-second long-press to
/// fire the destructive action. Replaces a tap-Delete button so a stray
/// tap can't wipe an event's RSVPs/photos.
///
/// Awaitable — `await showDialog<bool>(...)` resolves to `true` once the
/// user completes the hold, `null` if they cancel or dismiss. The dialog
/// does NOT perform the destructive action itself; callers handle the
/// follow-up based on the returned value.
///
/// onLongPressStart fires after Flutter's ~500ms long-press recognition
/// window, so total hold-from-touch is ≈2.5s. The label says "2 seconds"
/// because that's how long the visible fill animation runs once the
/// long-press is recognised.
class HoldToDeleteDialog extends StatefulWidget {
  final String eventTitle;

  const HoldToDeleteDialog({
    super.key,
    required this.eventTitle,
  });

  @override
  State<HoldToDeleteDialog> createState() => _HoldToDeleteDialogState();
}

class _HoldToDeleteDialogState extends State<HoldToDeleteDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        Navigator.of(context).pop(true);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onPressStart(LongPressStartDetails _) => _controller.forward();
  void _onPressEnd(LongPressEndDetails _) {
    if (!_controller.isCompleted) _controller.reset();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text('Delete event?'),
      // SizedBox(width: 280) clamps the AlertDialog's content width so
      // descendant Stack / FractionallySizedBox / width: double.infinity
      // nodes have a finite maxWidth to lay out against. Without this,
      // some Flutter versions pass an unconstrained width down through
      // the AlertDialog content slot and the hold-bar fill fails to
      // render.
      content: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you sure you want to delete "${widget.eventTitle}"? This will permanently remove all RSVPs, photos, and data.',
            ),
            const SizedBox(height: 18),
            GestureDetector(
              onLongPressStart: _onPressStart,
              onLongPressEnd: _onPressEnd,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (_, _) => ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  // FractionallySizedBox requires a bounded parent to compute
                  // its fraction. The AlertDialog content Column passes
                  // unbounded maxHeight downward, so wrapping the fill in
                  // SizedBox(height: 52) gives it a tight vertical bound; the
                  // background Container's explicit width: double.infinity
                  // bounds the Stack horizontally for the widthFactor math.
                  child: Stack(alignment: Alignment.center, children: [
                    Container(
                      height: 52,
                      width: double.infinity,
                      color: Colors.redAccent.withValues(alpha: 0.18),
                    ),
                    SizedBox(
                      height: 52,
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: _controller.value,
                        child: Container(color: Colors.redAccent),
                      ),
                    ),
                    const Text(
                      'Hold to Delete',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Center(
              child: Text(
                'Hold for 2 seconds to confirm',
                style: TextStyle(fontSize: 11, color: AppColors.muted),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
