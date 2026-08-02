import 'package:flutter/material.dart';

import '../theme.dart';
import '../util/label_style.dart';

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
      child: Container(
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
        child: fill == null
            ? Icon(
                selected ? Icons.check : Icons.format_color_reset_outlined,
                size: 18,
                color: scheme.onSurfaceVariant,
              )
            : selected
            ? Icon(Icons.check, size: 18, color: onFill)
            : null,
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
        child: Container(
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
          child: Icon(icon, size: 20, color: isSel ? tint : scheme.onSurface),
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
