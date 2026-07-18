import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/settings_store.dart';

/// One row in the note-color palette list: light/dark swatches, the name, and
/// edit/remove actions.
class PaletteRow extends StatelessWidget {
  final PaletteEntry entry;
  const PaletteRow({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsStore>();
    return ListTile(
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Swatch(color: entry.light, icon: Icons.light_mode_outlined),
          const SizedBox(width: 6),
          _Swatch(color: entry.dark, icon: Icons.dark_mode_outlined),
        ],
      ),
      title: Text(entry.name),
      onTap: () => PaletteEditDialog.show(context, entry),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 20),
            tooltip: 'Edit color',
            onPressed: () => PaletteEditDialog.show(context, entry),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: 'Remove color',
            onPressed: settings.palette.length <= 1
                ? null
                : () => settings.removePaletteColor(entry.key),
          ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  final IconData icon;
  const _Swatch({required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Icon(icon, size: 14, color: Colors.black.withValues(alpha: 0.35)),
    );
  }
}

/// Create/edit one palette color: a name plus light and dark shades, picked
/// from swatches or typed as hex.
class PaletteEditDialog extends StatefulWidget {
  final PaletteEntry? entry; // null = create
  const PaletteEditDialog({super.key, this.entry});

  static Future<void> show(BuildContext context, PaletteEntry? entry) {
    final settings = context.read<SettingsStore>();
    return showDialog<void>(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: settings,
        child: PaletteEditDialog(entry: entry),
      ),
    );
  }

  @override
  State<PaletteEditDialog> createState() => _PaletteEditDialogState();
}

class _PaletteEditDialogState extends State<PaletteEditDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.entry?.name ?? '',
  );
  late Color _light = widget.entry?.light ?? const Color(0xFFF28B82);
  late Color _dark = widget.entry?.dark ?? const Color(0xFF5C2B29);

  // A compact but broad swatch board (Material 200s for light, 900s for dark).
  static const _lightSwatches = [
    Color(0xFFF28B82),
    Color(0xFFFBBC04),
    Color(0xFFFFF475),
    Color(0xFFCCFF90),
    Color(0xFFA7FFEB),
    Color(0xFFAECBFA),
    Color(0xFFE8EAED),
    Color(0xFFFDCFE8),
    Color(0xFFD7AEFB),
    Color(0xFFE6C9A8),
    Color(0xFFB2EBF2),
    Color(0xFFFFCCBC),
  ];
  static const _darkSwatches = [
    Color(0xFF5C2B29),
    Color(0xFF614A19),
    Color(0xFF635D19),
    Color(0xFF345920),
    Color(0xFF16504B),
    Color(0xFF2D555E),
    Color(0xFF3C3F43),
    Color(0xFF5B2245),
    Color(0xFF42275E),
    Color(0xFF442F19),
    Color(0xFF1F4E5F),
    Color(0xFF6D3B2C),
  ];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final settings = context.read<SettingsStore>();
    final entry = widget.entry;
    if (entry == null) {
      settings.addPaletteColor(_name.text, _light, _dark);
    } else {
      settings.updatePaletteColor(
        entry.key,
        name: _name.text.trim().isEmpty ? entry.name : _name.text,
        light: _light,
        dark: _dark,
      );
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.entry == null ? 'Add color' : 'Edit color'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),
              _ShadeEditor(
                label: 'Light theme shade',
                color: _light,
                swatches: _lightSwatches,
                onChanged: (c) => setState(() => _light = c),
              ),
              const SizedBox(height: 16),
              _ShadeEditor(
                label: 'Dark theme shade',
                color: _dark,
                swatches: _darkSwatches,
                onChanged: (c) => setState(() => _dark = c),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class _ShadeEditor extends StatefulWidget {
  final String label;
  final Color color;
  final List<Color> swatches;
  final ValueChanged<Color> onChanged;

  const _ShadeEditor({
    required this.label,
    required this.color,
    required this.swatches,
    required this.onChanged,
  });

  @override
  State<_ShadeEditor> createState() => _ShadeEditorState();
}

class _ShadeEditorState extends State<_ShadeEditor> {
  late final TextEditingController _hex = TextEditingController(
    text: PaletteEntry.colorToHex(widget.color),
  );

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _select(Color c) {
    _hex.text = PaletteEntry.colorToHex(c);
    widget.onChanged(c);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: scheme.outlineVariant),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 110,
              child: TextField(
                controller: _hex,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  labelText: 'Hex',
                ),
                onChanged: (value) {
                  final parsed = PaletteEntry.hexToColor(value);
                  if (parsed != null) widget.onChanged(parsed);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final swatch in widget.swatches)
              InkWell(
                onTap: () => _select(swatch),
                customBorder: const CircleBorder(),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: swatch,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: swatch == widget.color
                          ? scheme.primary
                          : scheme.outlineVariant,
                      width: swatch == widget.color ? 2 : 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
