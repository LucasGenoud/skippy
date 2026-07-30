import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/notes_store.dart';
import '../../state/settings_store.dart';
import '../../util/snack.dart';
import '../form_dialog.dart';

/// Picks the column one or more notes belong in.
///
/// The guaranteed way to move a card, available on every platform, and the
/// keyboard and screen-reader path that dragging can never be. It also backs
/// the selection bar's bulk move.
class MoveToStageSheet extends StatelessWidget {
  /// The notes to file. One id for a single card's menu, many for a
  /// selection.
  final List<String> noteIds;

  const MoveToStageSheet({super.key, required this.noteIds});

  static Future<void> show(BuildContext context, String noteId) =>
      showForNotes(context, [noteId]);

  static Future<void> showForNotes(
    BuildContext context,
    Iterable<String> noteIds,
  ) {
    final ids = noteIds.toList(growable: false);
    if (ids.isEmpty) return Future.value();
    final store = context.read<NotesStore>();
    return showAdaptiveSelectionSurface<void>(
      context,
      builder: (_) => ChangeNotifierProvider.value(
        value: store,
        child: MoveToStageSheet(noteIds: ids),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    // A shared "current" only means anything when every note agrees, which is
    // the single-note case and the already-aligned selection.
    final stageIds = {
      for (final id in noteIds)
        if (store.noteById(id) case final note?) note.stageId,
    };
    final current = stageIds.length == 1 ? stageIds.single : null;
    final title = noteIds.length == 1
        ? 'Move to column'
        : 'Move ${noteIds.length} notes to column';
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            _StageOption(
              label: 'Unassigned',
              color: null,
              selected: stageIds.length == 1 && current == null,
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
    // Snapshot where each note came from so one Undo puts them all back, even
    // though they may have started in different columns.
    final before = {
      for (final id in noteIds)
        if (store.noteById(id) case final note?) id: note.stageId,
    };
    Navigator.of(context).pop();
    final moved = [
      for (final entry in before.entries)
        if (entry.value != stageId) entry.key,
    ];
    if (moved.isEmpty) return;
    for (final id in moved) {
      store.setNoteStage(id, stageId);
    }
    showAppSnack(
      moved.length == 1
          ? 'Moved to $name'
          : '${moved.length} notes moved to $name',
      icon: Icons.view_kanban_outlined,
      actionLabel: 'Undo',
      onAction: () {
        for (final id in moved) {
          store.setNoteStage(id, before[id]);
        }
      },
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
