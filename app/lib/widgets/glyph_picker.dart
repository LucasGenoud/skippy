import 'package:flutter/material.dart';

import '../theme.dart';
import '../util/label_style.dart';
import '../util/motion.dart';

/// The colour and icon pickers shared by everything that carries the app's
/// label glyph vocabulary: labels themselves, and saved smart views. One
/// implementation so the two never drift apart visually.

/// One tappable colour circle in the editor. A null [color] is the "default"
/// slot (theme colour, shown as a neutral swatch).
class ColorDot extends StatelessWidget {
  final Color? color;
  final bool selected;
  final VoidCallback onTap;
  const ColorDot({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = color;
    final onFill =
        fill != null &&
            ThemeData.estimateBrightnessForColor(fill) == Brightness.dark
        ? Colors.white
        : Colors.black87;
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      // The ring thickens into place and the check pops in, so picking a
      // colour is something you watch land rather than a redraw.
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.standard,
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: fill ?? scheme.surfaceContainerHighest,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? scheme.onSurface : scheme.outlineVariant,
            width: selected ? 2.5 : 1,
          ),
        ),
        child: AnimatedSwitcher(
          duration: Motion.fast,
          switchInCurve: Curves.easeOutBack,
          switchOutCurve: Motion.standard,
          transitionBuilder: (child, animation) =>
              ScaleTransition(scale: animation, child: child),
          child: selected
              ? Icon(
                  Icons.check,
                  key: const ValueKey('check'),
                  size: 18,
                  color: fill == null ? scheme.onSurfaceVariant : onFill,
                )
              : fill == null
              ? Icon(
                  Icons.format_color_reset_outlined,
                  key: const ValueKey('reset'),
                  size: 18,
                  color: scheme.onSurfaceVariant,
                )
              : const SizedBox.shrink(key: ValueKey('none')),
        ),
      ),
    );
  }
}

/// The curated icon grid, plus a leading "default" slot (no custom icon).
class IconGrid extends StatelessWidget {
  final String? selected;
  final Color tint;
  final ValueChanged<String?> onSelect;
  const IconGrid({
    super.key,
    required this.selected,
    required this.tint,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget cell({required String? key, required IconData icon}) {
      final isSel = selected == key;
      return InkWell(
        onTap: () => onSelect(key),
        borderRadius: kBorderRadius,
        child: AnimatedContainer(
          duration: Motion.fast,
          curve: Motion.standard,
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            borderRadius: kBorderRadius,
            color: isSel ? tint.withValues(alpha: 0.18) : null,
            border: Border.all(
              color: isSel ? tint : scheme.outlineVariant,
              width: isSel ? 2 : 1,
            ),
          ),
          // The glyph takes the label's colour along with its cell, rather
          // than snapping to it while the cell is still filling in.
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: isSel ? tint : scheme.onSurface),
            duration: Motion.fast,
            curve: Motion.standard,
            builder: (context, color, _) => Icon(icon, size: 20, color: color),
          ),
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        // Default slot: clears any custom icon.
        cell(key: null, icon: kDefaultLabelIcon),
        for (final entry in kLabelIcons.entries)
          cell(key: entry.key, icon: entry.value),
      ],
    );
  }
}
