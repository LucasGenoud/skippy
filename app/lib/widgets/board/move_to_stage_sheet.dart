import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/notes_store.dart';
import '../../state/settings_store.dart';
import '../../util/snack.dart';

/// Picks the column a note belongs in.
///
/// This is how a card moves in v1 — on every platform, not as a phone-only
/// fallback. It is also the keyboard and screen-reader path, so it stays the
/// guaranteed route even once dragging exists.
class MoveToStageSheet extends StatelessWidget {
  final String noteId;

  const MoveToStageSheet({super.key, required this.noteId});

  static Future<void> show(BuildContext context, String noteId) {
    final store = context.read<NotesStore>();
    return showModalBottomSheet<void>(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: store,
        child: MoveToStageSheet(noteId: noteId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final note = store.noteById(noteId);
    final current = note?.stageId;
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                'Move to column',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            _StageOption(
              label: 'Unassigned',
              color: null,
              selected: current == null,
              onTap: () => _move(context, store, null, 'Unassigned'),
            ),
            for (final stage in store.stages)
              _StageOption(
                label: stage.name,
                color: PaletteEntry.hexToColor(stage.color),
                selected: current == stage.id,
                onTap: () => _move(context, store, stage.id, stage.name),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _move(
    BuildContext context,
    NotesStore store,
    String? stageId,
    String name,
  ) {
    final previous = store.noteById(noteId)?.stageId;
    Navigator.of(context).pop();
    if (previous == stageId) return;
    store.setNoteStage(noteId, stageId);
    showAppSnack(
      'Moved to $name',
      icon: Icons.view_kanban_outlined,
      actionLabel: 'Undo',
      onAction: () => store.setNoteStage(noteId, previous),
    );
  }
}

class _StageOption extends StatelessWidget {
  final String label;
  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  const _StageOption({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: color ?? scheme.onSurfaceVariant,
          shape: BoxShape.circle,
        ),
      ),
      title: Text(label, overflow: TextOverflow.ellipsis),
      trailing: selected ? const Icon(Icons.check) : null,
      selected: selected,
      onTap: onTap,
    );
  }
}
