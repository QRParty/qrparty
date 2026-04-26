import 'package:flutter/material.dart';
import '../models/merch_order.dart';

const _purple    = Color(0xFF9C7FD4);
const _gold      = Color(0xFFC8922A);
const _borderDk  = Color(0xFF4A4E6B);

/// Selectable card in the theme picker grid. Renders a stylised preview of
/// the theme using the variant's bg + accent colors plus the theme emoji.
/// When real PNG art lands, swap the gradient/emoji for an Image widget.
class ThemeCard extends StatelessWidget {
  final MerchTheme theme;
  final int variantIndex;
  final bool selected;
  final VoidCallback onTap;
  const ThemeCard({
    super.key,
    required this.theme,
    required this.variantIndex,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final variant = theme.variants[variantIndex];
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? _purple : _borderDk,
            width: selected ? 2 : 1,
          ),
          boxShadow: selected
              ? [BoxShadow(color: _purple.withValues(alpha: 0.30), blurRadius: 14, spreadRadius: 1)]
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(children: [
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [variant.accent.withValues(alpha: 0.55), variant.bg],
                center: const Alignment(0.4, -0.5), radius: 1.2,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  child: Text(theme.emoji, style: const TextStyle(fontSize: 36)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(theme.name,
                        style: TextStyle(
                          fontFamily: 'FredokaOne', fontSize: 16, color: variant.text,
                          shadows: const [Shadow(color: Colors.black54, blurRadius: 4)],
                        )),
                    const SizedBox(height: 2),
                    Text(variant.name.toUpperCase(),
                        style: TextStyle(
                          fontSize: 9, fontWeight: FontWeight.w800,
                          letterSpacing: 1.4, color: variant.text.withValues(alpha: 0.78),
                        )),
                  ]),
                ),
              ],
            ),
          ),
          if (selected)
            Positioned(
              top: 8, right: 8,
              child: Container(
                width: 22, height: 22,
                decoration: const BoxDecoration(color: _gold, shape: BoxShape.circle),
                child: const Icon(Icons.check, color: Colors.black, size: 14),
              ),
            ),
        ]),
      ),
    );
  }
}
