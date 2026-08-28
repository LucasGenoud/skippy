import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../util/label_style.dart';
import '../util/motion.dart';
import '../theme.dart';
import 'drag_reorder_list.dart';
import 'form_dialog.dart';
import 'glyph_picker.dart';
import 'settings/accent_color.dart' show kAccentPresets;
import 'staggered_entrance.dart';

/// A small colour dot with the label's icon inside, the shared leading glyph
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

/// Bottom sheet for assigning labels to a note, with inline creation,
/// typing a name that doesn't exist offers "Create `name`".
class LabelsSheet extends StatefulWidget {
  final List<String> noteIds;

  /// Detached mode: label a note that does not exist yet (the desktop quick
  /// add composer). The sheet reads this set and reports every tap through
  /// [onToggle] instead of writing to a stored note, so composing never has
  /// to materialize a note just to file it.
  final Set<String>? selection;
  final ValueChanged<String>? onToggle;

  const LabelsSheet({
    super.key,
    this.noteIds = const [],
    this.selection,
    this.onToggle,
  }) : assert(
         selection == null || onToggle != null,
         'detached mode needs an onToggle',
       );

  static Future<void> show(BuildContext context, String noteId) {
    return showAdaptiveSelectionSurface<void>(
      context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
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
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: LabelsSheet(noteIds: ids),
      ),
    );
  }

  /// Assign labels to a note being composed: [selected] is the live set and
  /// [onToggle] is called with each label the user checks or unchecks.
  static Future<void> showForSelection(
    BuildContext context, {
    required Set<String> selected,
    required ValueChanged<String> onToggle,
  }) {
    return showAdaptiveSelectionSurface<void>(
      context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: LabelsSheet(selection: selected, onToggle: onToggle),
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
    final selection = widget.selection;
    final notes = [
      for (final id in widget.noteIds)
        if (store.noteById(id) case final Note note) note,
    ];
    if (selection == null && notes.isEmpty) return const SizedBox.shrink();
    final isMultiple = notes.length > 1;

    bool isAssigned(Label label) =>
        selection?.contains(label.id) ??
        notes.every((note) => note.labelIds.contains(label.id));

    /// One tap on a label row: the composed selection in detached mode, the
    /// stored notes otherwise.
    void toggle(Label label) {
      if (selection != null) {
        widget.onToggle!(label.id);
        setState(() {});
      } else if (isMultiple) {
        for (final note in notes) {
          store.addLabelToNote(note.id, label.id);
        }
      } else {
        store.toggleLabelOnNote(notes.single.id, label.id);
      }
    }

    final q = _query.trim().toLowerCase();
    final visible = store.labels
        .where((l) => q.isEmpty || l.name.toLowerCase().contains(q))
        .toList();
    final exactExists = store.labels.any((l) => l.name.toLowerCase() == q);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ModalHeader(
              title: isMultiple
                  ? 'Add label to ${notes.length} notes'
                  : 'Label note',
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                kModalInset,
                kModalHeaderGap,
                kModalInset,
                kSpaceSm,
              ),
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
                        if (selection != null) {
                          widget.onToggle!(label.id);
                        } else {
                          for (final note in notes) {
                            store.addLabelToNote(note.id, label.id);
                          }
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
                        // Assigning across several notes turns "+" into a
                        // check in place; it pops through rather than
                        // switching between two frames.
                        trailing: AnimatedSwitcher(
                          duration: Motion.fast,
                          switchInCurve: Curves.easeOutBack,
                          switchOutCurve: Motion.standard,
                          transitionBuilder: (child, animation) =>
                              ScaleTransition(scale: animation, child: child),
                          child: isAssigned(label)
                              ? const Icon(Icons.check, key: ValueKey('on'))
                              : const Icon(Icons.add, key: ValueKey('off')),
                        ),
                        onTap: () => toggle(label),
                      )
                    else
                      CheckboxListTile(
                        value: isAssigned(label),
                        controlAffinity: ListTileControlAffinity.leading,
                        dense: true,
                        secondary: LabelGlyph(label: label),
                        title: Text(label.name),
                        onChanged: (_) => toggle(label),
                      ),
                  if (visible.isEmpty && q.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('No labels yet, type a name to create one.'),
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
/// slides up on a phone, where a list of labels and a delete button per row
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
    final labels = store.labels;
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
          DragReorderList<Label>(
            items: labels,
            idOf: (label) => label.id,
            onReorder: store.moveLabel,
            rowBuilder: (context, label, index, handle) => StaggeredEntrance(
              index: index,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    handle,
                    const SizedBox(width: 4),
                    LabelGlyph(label: label, size: 28),
                  ],
                ),
                title: Text(label.name, overflow: TextOverflow.ellipsis),
                onTap: () => LabelEditorDialog.show(context, label.id),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete label',
                  onPressed: () => store.deleteLabel(label.id),
                ),
              ),
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
              ColorDot(
                color: null,
                selected: _color == null,
                onTap: () => setState(() {
                  _color = null;
                  _hex.text = '';
                }),
              ),
              for (final c in kAccentPresets)
                ColorDot(
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
          IconGrid(
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
