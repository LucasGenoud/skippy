import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../util/label_style.dart';
import 'form_dialog.dart';
import 'settings/accent_color.dart' show kAccentPresets;

/// A small colour dot with the label's icon inside — the shared leading glyph
/// for a label across the assign sheet, the editor list, and the drawer.
class LabelGlyph extends StatelessWidget {
  final Label label;
  final double size;
  const LabelGlyph({super.key, required this.label, this.size = 24});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = labelColor(label, scheme.onSurfaceVariant);
    final tinted = label.color != null;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: tinted ? color.withValues(alpha: 0.18) : Colors.transparent,
        border: Border.all(color: color.withValues(alpha: tinted ? 0.0 : 0.5)),
      ),
      alignment: Alignment.center,
      child: Icon(labelIcon(label), size: size * 0.62, color: color),
    );
  }
}

/// Bottom sheet for assigning labels to a note, with inline creation —
/// typing a name that doesn't exist offers "Create `name`".
class LabelsSheet extends StatefulWidget {
  final List<String> noteIds;
  const LabelsSheet({super.key, required this.noteIds});

  static Future<void> show(BuildContext context, String noteId) {
    return showAdaptiveSelectionSurface<void>(
      context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: LabelsSheet(noteIds: [noteId]),
      ),
    );
  }

  /// Adds labels to every selected note. Existing labels are left in place,
  /// so applying the same label twice is harmless.
  static Future<void> showForNotes(
    BuildContext context,
    Iterable<String> noteIds,
  ) {
    final ids = noteIds.toList(growable: false);
    if (ids.isEmpty) return Future.value();
    return showAdaptiveSelectionSurface<void>(
      context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: LabelsSheet(noteIds: ids),
      ),
    );
  }

  @override
  State<LabelsSheet> createState() => _LabelsSheetState();
}

class _LabelsSheetState extends State<LabelsSheet> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final notes = [
      for (final id in widget.noteIds)
        if (store.noteById(id) case final Note note) note,
    ];
    if (notes.isEmpty) return const SizedBox.shrink();
    final isMultiple = notes.length > 1;

    final q = _query.trim().toLowerCase();
    final visible = store.labels
        .where((l) => q.isEmpty || l.name.toLowerCase().contains(q))
        .toList();
    final exactExists = store.labels.any((l) => l.name.toLowerCase() == q);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                isMultiple
                    ? 'Add label to ${notes.length} notes'
                    : 'Label note',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: TextField(
                controller: _controller,
                autofocus: false,
                decoration: const InputDecoration(
                  hintText: 'Enter label name',
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 20),
                  border: UnderlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (q.isNotEmpty && !exactExists)
                    ListTile(
                      leading: const Icon(Icons.add),
                      title: Text('Create "${_query.trim()}"'),
                      onTap: () {
                        final label = store.createLabel(_query.trim());
                        for (final note in notes) {
                          store.addLabelToNote(note.id, label.id);
                        }
                        _controller.clear();
                        setState(() => _query = '');
                      },
                    ),
                  for (final label in visible)
                    if (isMultiple)
                      ListTile(
                        leading: LabelGlyph(label: label),
                        title: Text(label.name),
                        trailing:
                            notes.every(
                              (note) => note.labelIds.contains(label.id),
                            )
                            ? const Icon(Icons.check)
                            : const Icon(Icons.add),
                        onTap: () {
                          for (final note in notes) {
                            store.addLabelToNote(note.id, label.id);
                          }
                        },
                      )
                    else
                      CheckboxListTile(
                        value: notes.single.labelIds.contains(label.id),
                        controlAffinity: ListTileControlAffinity.leading,
                        dense: true,
                        secondary: LabelGlyph(label: label),
                        title: Text(label.name),
                        onChanged: (_) =>
                            store.toggleLabelOnNote(notes.single.id, label.id),
                      ),
                  if (visible.isEmpty && q.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('No labels yet — type a name to create one.'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// The "Edit labels" management dialog reached from the drawer. Lists labels
/// with their colour/icon; each opens a [LabelEditorDialog] on tap.
///
/// Shown through [showFormDialog]: a floating box on a wide screen, a page that
/// slides up on a phone — where a list of labels and a delete button per row
/// have no business being squeezed into a boxed modal.
class EditLabelsDialog extends StatelessWidget {
  const EditLabelsDialog({super.key});

  static Future<void> show(BuildContext context) {
    final store = context.read<NotesStore>();
    return showFormDialog<void>(
      context,
      builder: (_) => ChangeNotifierProvider.value(
        value: store,
        child: const EditLabelsDialog(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    return FormDialog(
      title: const Text('Edit labels'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.add),
            title: const Text('Create new label'),
            onTap: () => LabelEditorDialog.show(context, null),
          ),
          const Divider(height: 8),
          for (final label in store.labels)
            ListTile(
              key: ValueKey(label.id),
              contentPadding: EdgeInsets.zero,
              leading: LabelGlyph(label: label, size: 28),
              title: Text(label.name, overflow: TextOverflow.ellipsis),
              onTap: () => LabelEditorDialog.show(context, label.id),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete label',
                onPressed: () => store.deleteLabel(label.id),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// Create or edit one label: name, colour (default / preset swatch / custom
/// hex), and icon (curated grid, with a "default" slot). [labelId] null =
/// create. Colour presets reuse [kAccentPresets]; the icon set is [kLabelIcons].
class LabelEditorDialog extends StatefulWidget {
  final String? labelId;
  const LabelEditorDialog({super.key, this.labelId});

  static Future<void> show(BuildContext context, String? labelId) {
    final store = context.read<NotesStore>();
    return showFormDialog<void>(
      context,
      builder: (_) => ChangeNotifierProvider.value(
        value: store,
        child: LabelEditorDialog(labelId: labelId),
      ),
    );
  }

  @override
  State<LabelEditorDialog> createState() => _LabelEditorDialogState();
}

class _LabelEditorDialogState extends State<LabelEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _hex;
  String? _color; // hex or null (theme default)
  String? _icon; // icon key or null (default glyph)
  String? _nameError; // shown under the Name field once invalid

  bool get _isNew => widget.labelId == null;

  @override
  void initState() {
    super.initState();
    final existing = widget.labelId == null
        ? null
        : context.read<NotesStore>().labelById(widget.labelId!);
    _name = TextEditingController(text: existing?.name ?? '');
    _color = existing?.color;
    _icon = existing?.icon;
    _hex = TextEditingController(text: _color ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _hex.dispose();
    super.dispose();
  }

  void _save() {
    final store = context.read<NotesStore>();
    final name = _name.text.trim();
    final error = _validate(store, name);
    if (error != null) {
      setState(() => _nameError = error);
      return;
    }
    if (_isNew) {
      store.createLabel(name, color: _color, icon: _icon);
    } else {
      store.updateLabel(
        widget.labelId!,
        name: name,
        color: _color,
        icon: _icon,
      );
    }
    Navigator.of(context).pop();
  }

  /// The name field's problem, or null when it's valid: empty, or a duplicate
  /// of another label (the server rejects duplicates, so catch it up front).
  String? _validate(NotesStore store, String name) {
    if (name.isEmpty) return 'Enter a name';
    final clash = store.labels.any(
      (l) =>
          l.id != widget.labelId && l.name.toLowerCase() == name.toLowerCase(),
    );
    if (clash) return 'A label named "$name" already exists';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FormDialog(
      title: Text(_isNew ? 'New label' : 'Edit label'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _name,
            autofocus: _isNew,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Name',
              isDense: true,
              border: const OutlineInputBorder(),
              // Non-null errorText turns the border + label red and shows
              // the message underneath (Material's standard error state).
              errorText: _nameError,
            ),
            // Clear the error as soon as they start correcting it.
            onChanged: (_) {
              if (_nameError != null) setState(() => _nameError = null);
            },
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 20),
          _sectionLabel(context, 'Color'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              // Default (no colour) slot.
              _ColorDot(
                color: null,
                selected: _color == null,
                onTap: () => setState(() {
                  _color = null;
                  _hex.text = '';
                }),
              ),
              for (final c in kAccentPresets)
                _ColorDot(
                  color: c,
                  selected:
                      _color != null && PaletteEntry.hexToColor(_color) == c,
                  onTap: () => setState(() {
                    _color = PaletteEntry.colorToHex(c);
                    _hex.text = _color!;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 150,
            child: TextField(
              controller: _hex,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                labelText: 'Custom hex',
                hintText: '#RRGGBB',
              ),
              onChanged: (value) {
                final parsed = PaletteEntry.hexToColor(value);
                setState(
                  () => _color = parsed == null
                      ? (value.trim().isEmpty ? null : _color)
                      : PaletteEntry.colorToHex(parsed),
                );
              },
            ),
          ),
          const SizedBox(height: 20),
          _sectionLabel(context, 'Icon'),
          const SizedBox(height: 10),
          _IconGrid(
            selected: _icon,
            tint: PaletteEntry.hexToColor(_color) ?? scheme.onSurfaceVariant,
            onSelect: (key) => setState(() => _icon = key),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: Text(_isNew ? 'Create' : 'Save')),
      ],
    );
  }

  Widget _sectionLabel(BuildContext context, String text) => Text(
    text,
    style: Theme.of(context).textTheme.labelMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

/// One tappable colour circle in the editor. A null [color] is the "default"
/// slot (theme colour, shown as a neutral swatch).
class _ColorDot extends StatelessWidget {
  final Color? color;
  final bool selected;
  final VoidCallback onTap;
  const _ColorDot({
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
class _IconGrid extends StatelessWidget {
  final String? selected;
  final Color tint;
  final ValueChanged<String?> onSelect;
  const _IconGrid({
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
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
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
