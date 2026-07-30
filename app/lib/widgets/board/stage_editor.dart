import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/note.dart';
import '../../state/notes_store.dart';
import '../../state/settings_store.dart';
import '../settings/accent_color.dart';
import '../drag_reorder_list.dart';
import '../form_dialog.dart';
import '../staggered_entrance.dart';

/// Manage the board's columns: add, rename, recolour, remove.
///
/// Parallel to `EditLabelsDialog` rather than sharing code with it, stages and
/// labels are independent systems, and two small dialogs are easier to change
/// than one generic one.
class EditStagesDialog extends StatelessWidget {
  const EditStagesDialog({super.key});

  static Future<void> show(BuildContext context) {
    final store = context.read<NotesStore>();
    return showFormDialog<void>(
      context,
      builder: (_) => ChangeNotifierProvider.value(
        value: store,
        child: const EditStagesDialog(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final stages = store.stages;
    return FormDialog(
      title: const Text('Edit columns'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.add),
            title: const Text('Add column'),
            onTap: () => StageEditorDialog.show(context, null),
          ),
          const Divider(height: 8),
          DragReorderList<Stage>(
            items: stages,
            idOf: (stage) => stage.id,
            onReorder: store.moveStage,
            rowBuilder: (context, stage, index, handle) => StaggeredEntrance(
              index: index,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    handle,
                    const SizedBox(width: 8),
                    _StageDot(color: stage.color),
                  ],
                ),
                title: Text(stage.name, overflow: TextOverflow.ellipsis),
                onTap: () => StageEditorDialog.show(context, stage.id),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete column',
                  onPressed: () => store.deleteStage(stage.id),
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

/// Create or rename one column. [stageId] null means create.
class StageEditorDialog extends StatefulWidget {
  final String? stageId;

  const StageEditorDialog({super.key, this.stageId});

  static Future<void> show(BuildContext context, String? stageId) {
    final store = context.read<NotesStore>();
    return showFormDialog<void>(
      context,
      builder: (_) => ChangeNotifierProvider.value(
        value: store,
        child: StageEditorDialog(stageId: stageId),
      ),
    );
  }

  @override
  State<StageEditorDialog> createState() => _StageEditorDialogState();
}

class _StageEditorDialogState extends State<StageEditorDialog> {
  late final TextEditingController _name;
  String? _color;
  String? _nameError;

  bool get _isNew => widget.stageId == null;

  @override
  void initState() {
    super.initState();
    final existing = widget.stageId == null
        ? null
        : context.read<NotesStore>().stageById(widget.stageId!);
    _name = TextEditingController(text: existing?.name ?? '');
    _color = existing?.color;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String? _validate(NotesStore store, String name) {
    if (name.isEmpty) return 'Name a column';
    final clash = store.stages.any(
      (stage) =>
          stage.id != widget.stageId &&
          stage.name.toLowerCase() == name.toLowerCase(),
    );
    // The server enforces this too (unique per workspace); catching it here
    // keeps the optimistic create from being silently rejected later.
    return clash ? 'That column already exists' : null;
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
      store.createStage(name, color: _color);
    } else {
      store.updateStage(widget.stageId!, name: name, color: _color);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return FormDialog(
      title: Text(_isNew ? 'Add column' : 'Edit column'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Name',
              errorText: _nameError,
            ),
            onChanged: (_) {
              if (_nameError != null) setState(() => _nameError = null);
            },
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 20),
          Text('Colour', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _ColorChoice(
                color: null,
                selected: _color == null,
                onTap: () => setState(() => _color = null),
              ),
              for (final color in kAccentPresets)
                _ColorChoice(
                  color: color,
                  selected:
                      PaletteEntry.hexToColor(_color)?.toARGB32() ==
                      color.toARGB32(),
                  onTap: () =>
                      setState(() => _color = PaletteEntry.colorToHex(color)),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(_isNew ? 'Add' : 'Save'),
        ),
      ],
    );
  }
}

/// The dot that stands in for a column in lists, a stage's whole visual
/// identity, since stages carry no icon.
class _StageDot extends StatelessWidget {
  final String? color;

  const _StageDot({this.color});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: PaletteEntry.hexToColor(color) ?? scheme.onSurfaceVariant,
        shape: BoxShape.circle,
      ),
    );
  }
}

class _ColorChoice extends StatelessWidget {
  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  const _ColorChoice({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color ?? scheme.surfaceContainerHighest,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? scheme.onSurface : Colors.transparent,
            width: 2,
          ),
        ),
        child: color == null
            ? Icon(Icons.block, size: 16, color: scheme.onSurfaceVariant)
            : null,
      ),
    );
  }
}
