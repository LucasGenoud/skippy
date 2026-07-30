import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/settings_store.dart';
import '../../theme.dart';
import '../form_dialog.dart';

/// A handful of pleasant seeds to pick from, the amber ([kDefaultAccent])
/// first so the out-of-the-box state reads as selected. Any hex is reachable
/// through the custom picker.
const List<Color> kAccentPresets = [
  kDefaultAccent, // Amber
  Color(0xFFFF7043), // Deep orange
  Color(0xFFEA4335), // Red
  Color(0xFFD81B60), // Pink
  Color(0xFF9334E6), // Purple
  Color(0xFF3F51B5), // Indigo
  Color(0xFF1A73E8), // Blue
  Color(0xFF00897B), // Teal
  Color(0xFF188038), // Green
  Color(0xFF5F6368), // Slate
];

/// Accent-color row: preset seeds plus a custom slot. The chosen seed reseeds
/// the whole Material scheme via [buildTheme] (see [SettingsStore.accentColor]),
/// so this recolors the app's chrome, FAB, checkboxes, selection, section
/// headers, while surfaces stay neutral.
class AccentColorTile extends StatelessWidget {
  const AccentColorTile({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final selected = settings.accentColor;
    final isPreset = kAccentPresets.any((c) => c == selected);
    return ListTile(
      leading: const Icon(Icons.palette_outlined),
      title: const Text('Accent color'),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final color in kAccentPresets)
              _AccentDot(
                color: color,
                selected: color == selected,
                onTap: () => settings.setAccentColor(color),
              ),
            _AccentDot(
              // A non-preset current value lives in the custom slot, selected.
              color: isPreset ? null : selected,
              custom: true,
              selected: !isPreset,
              onTap: () => _AccentCustomDialog.show(context, selected),
            ),
          ],
        ),
      ),
    );
  }
}

/// One tappable circle in the accent row. A [custom] dot with no [color] shows
/// a "+"; otherwise the fill is the seed, with a contrast-aware check when
/// selected.
class _AccentDot extends StatelessWidget {
  final Color? color;
  final bool selected;
  final bool custom;
  final VoidCallback onTap;

  const _AccentDot({
    required this.color,
    required this.onTap,
    this.selected = false,
    this.custom = false,
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
    final dot = InkWell(
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
            ? Icon(Icons.add, size: 18, color: scheme.onSurfaceVariant)
            : selected
            ? Icon(Icons.check, size: 18, color: onFill)
            : null,
      ),
    );
    // Tooltip asserts on a null message, so only wrap the custom slot (the one
    // dot whose purpose isn't obvious from its color).
    return custom ? Tooltip(message: 'Custom…', child: dot) : dot;
  }
}

/// Pick any accent by swatch or hex. A live chip previews the toned `primary`
/// the seed actually produces (Material mutes vivid seeds), so the choice is
/// WYSIWYG rather than a surprise.
class _AccentCustomDialog extends StatefulWidget {
  final Color initial;
  const _AccentCustomDialog({required this.initial});

  static Future<void> show(BuildContext context, Color initial) {
    final settings = context.read<SettingsStore>();
    return showFormDialog<void>(
      context,
      builder: (_) => ChangeNotifierProvider.value(
        value: settings,
        child: _AccentCustomDialog(initial: initial),
      ),
    );
  }

  @override
  State<_AccentCustomDialog> createState() => _AccentCustomDialogState();
}

class _AccentCustomDialogState extends State<_AccentCustomDialog> {
  late Color _color = widget.initial;
  late final TextEditingController _hex = TextEditingController(
    text: PaletteEntry.colorToHex(widget.initial),
  );

  // A vivid board spanning the hue wheel, good starting points before hex.
  static const _board = [
    Color(0xFFFBBC04),
    Color(0xFFF9AB00),
    Color(0xFFFF7043),
    Color(0xFFEA4335),
    Color(0xFFD81B60),
    Color(0xFF9334E6),
    Color(0xFF7C4DFF),
    Color(0xFF3F51B5),
    Color(0xFF1A73E8),
    Color(0xFF039BE5),
    Color(0xFF00897B),
    Color(0xFF188038),
    Color(0xFF7CB342),
    Color(0xFF8D6E63),
    Color(0xFF5F6368),
  ];

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _select(Color c) {
    setState(() => _color = c);
    _hex.text = PaletteEntry.colorToHex(c);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final primary = ColorScheme.fromSeed(
      seedColor: _color,
      brightness: Theme.of(context).brightness,
    ).primary;
    return FormDialog(
      title: const Text('Custom accent'),
      width: 380,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: primary,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.add,
                  size: 20,
                  color: scheme.brightness == Brightness.dark
                      ? Colors.black
                      : Colors.white,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Preview of the accent this seed produces.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in _board)
                InkWell(
                  onTap: () => _select(c),
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: c == _color
                            ? scheme.onSurface
                            : scheme.outlineVariant,
                        width: c == _color ? 2.5 : 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: 130,
            child: TextField(
              controller: _hex,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                labelText: 'Hex',
              ),
              onChanged: (value) {
                final parsed = PaletteEntry.hexToColor(value);
                if (parsed != null) setState(() => _color = parsed);
              },
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            context.read<SettingsStore>().setAccentColor(_color);
            Navigator.of(context).pop();
          },
          child: const Text('Use color'),
        ),
      ],
    );
  }
}
