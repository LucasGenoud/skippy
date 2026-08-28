import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/settings_store.dart';
import '../theme.dart';
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ModalHeader(title: 'Note color'),
          Padding(
            padding: modalBodyPadding(),
            child: _swatches(context, entries, scheme),
          ),
        ],
      ),
    );
  }

  /// The palette itself. Under a thumb it is one line that scrolls, which is
  /// the shape a sheet wants; in a dialog it wraps, because a box that shows
  /// most of a row and then cuts the rest off at its edge reads as broken
  /// rather than as scrollable.
  Widget _swatches(
    BuildContext context,
    List<({String key, String name, Color? fill})> entries,
    ColorScheme scheme,
  ) {
    Widget dot(({String key, String name, Color? fill}) entry) => _ColorDot(
      name: entry.name,
      fill: entry.fill,
      selected: entry.key == selected,
      surface: scheme.surface,
      onTap: () => onSelect(entry.key),
    );
    if (!modalIsSheet(context)) {
      return Wrap(
        spacing: kSpaceMd,
        runSpacing: kSpaceMd,
        children: [for (final entry in entries) dot(entry)],
      );
    }
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.only(right: kSpaceMd),
              child: dot(entry),
            ),
        ],
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
