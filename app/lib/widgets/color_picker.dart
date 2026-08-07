import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/settings_store.dart';
import '../util/motion.dart';
import 'form_dialog.dart';

/// Horizontal strip of the user's note colors (personalized in Settings),
/// shown in a phone sheet or compact web dialog. Selection updates live.
class ColorPickerSheet extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onSelect;
  const ColorPickerSheet({
    super.key,
    required this.selected,
    required this.onSelect,
  });

  static Future<void> show(
    BuildContext context, {
    required String Function() selected,
    required ValueChanged<String> onSelect,
  }) {
    final settings = context.read<SettingsStore>();
    return showAdaptiveSelectionSurface<void>(
      context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      builder: (context) => ChangeNotifierProvider.value(
        value: settings,
        child: StatefulBuilder(
          builder: (context, setSheetState) => ColorPickerSheet(
            selected: selected(),
            onSelect: (c) {
              onSelect(c);
              setSheetState(() {});
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final brightness = Theme.of(context).brightness;
    final scheme = Theme.of(context).colorScheme;
    final entries = [
      (key: 'default', name: 'Default', fill: null as Color?),
      for (final entry in settings.palette)
        (
          key: entry.key,
          name: entry.name,
          fill: brightness == Brightness.light ? entry.light : entry.dark,
        ),
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Note color', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final entry in entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: _ColorDot(
                        name: entry.name,
                        fill: entry.fill,
                        selected: entry.key == selected,
                        surface: scheme.surface,
                        onTap: () => onSelect(entry.key),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  final String name;
  final Color? fill;
  final bool selected;
  final Color surface;
  final VoidCallback onTap;

  const _ColorDot({
    required this.name,
    required this.fill,
    required this.selected,
    required this.surface,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: name,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: AnimatedContainer(
          duration: Motion.fast,
          curve: Motion.standard,
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: fill ?? surface,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 2.5 : 1,
            ),
          ),
          // The check pops in with a small overshoot when a color is picked.
          child: AnimatedSwitcher(
            duration: Motion.fast,
            switchInCurve: Curves.easeOutBack,
            switchOutCurve: Motion.standard,
            transitionBuilder: (child, animation) =>
                ScaleTransition(scale: animation, child: child),
            child: fill == null && !selected
                ? Icon(
                    Icons.format_color_reset_outlined,
                    key: const ValueKey('reset'),
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  )
                : selected
                ? Icon(
                    Icons.check,
                    key: const ValueKey('check'),
                    size: 22,
                    color: scheme.primary,
                  )
                : const SizedBox.shrink(key: ValueKey('none')),
          ),
        ),
      ),
    );
  }
}
