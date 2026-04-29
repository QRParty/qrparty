import 'package:flutter/material.dart';
import '../models/merch_order.dart';
import 'invitation_preview.dart';

const _purple    = Color(0xFF9C7FD4);
const _gold      = Color(0xFFC8922A);
const _borderDk  = Color(0xFF4A4E6B);

/// Selectable card in the theme picker grid. Renders the actual scaled-down
/// invitation design (via [ThemeMiniPreview]) so the user sees a true
/// preview of what the printed card looks like, with name + variant chip
/// pinned to the bottom for context.
class ThemeCard extends StatelessWidget {
  final MerchTheme theme;
  final int variantIndex;
  final bool selected;
  final bool isKidsBirthday;
  final VoidCallback onTap;
  const ThemeCard({
    super.key,
    required this.theme,
    required this.variantIndex,
    required this.selected,
    required this.onTap,
    this.isKidsBirthday = false,
  });

  @override
  Widget build(BuildContext context) {
    final variant = theme.variants[variantIndex];
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: variant.bg,
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
          // Full-bleed mini invitation design.
          Positioned.fill(
            child: FittedBox(
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 200, height: 300,
                child: ThemeMiniPreview(
                  theme: theme,
                  variantIndex: variantIndex,
                  isKidsBirthday: isKidsBirthday,
                ),
              ),
            ),
          ),
          // Bottom gradient + label so the theme name stays readable on
          // any background design.
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 16, 10, 10),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.0),
                    Colors.black.withValues(alpha: 0.65),
                  ],
                ),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(theme.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'FredokaOne', fontSize: 15, color: Colors.white,
                      shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
                    )),
                const SizedBox(height: 1),
                Text(variant.name.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 9, fontWeight: FontWeight.w800,
                      letterSpacing: 1.4, color: Colors.white70,
                    )),
              ]),
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
