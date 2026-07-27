import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/note.dart';
import '../../state/board_layout.dart';
import '../../state/notes_store.dart';
import '../../state/settings_store.dart';
import '../../theme.dart';
import '../note_card.dart';
import 'stage_editor.dart';

/// One column of the board: a header and the cards filed in it.
///
/// The same widget serves both layouts — side by side on a wide screen, one per
/// page on a phone. Only the container around it differs, so the column's
/// behaviour is defined once.
class BoardColumnView extends StatelessWidget {
  final BoardColumn column;

  /// The active search query, forwarded to cards for match highlighting.
  final String query;

  /// Invoked when the "show the rest" affordance on a capped Unassigned column
  /// is tapped. Null on every other column.
  final VoidCallback? onShowAll;

  /// Whether to draw the column's own header. The phone layout shows stage
  /// names in its page strip instead, so it turns this off.
  final bool showHeader;

  const BoardColumnView({
    super.key,
    required this.column,
    this.query = '',
    this.onShowAll,
    this.showHeader = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeader) _BoardColumnHeader(column: column),
        Expanded(
          child: column.notes.isEmpty
              ? _EmptyColumn(column: column)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 96),
                  // Cards are expensive to build, and a board mounts more of
                  // them at once than the grid does; builder + a boundary per
                  // card keeps scrolling one column off the others' backs.
                  itemCount: column.notes.length + (column.hiddenCount > 0 ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == column.notes.length) {
                      return _ShowAllTile(
                        hidden: column.hiddenCount,
                        onTap: onShowAll,
                      );
                    }
                    final note = column.notes[index];
                    return RepaintBoundary(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: NoteTile(key: ValueKey(note.id), note: note, query: query),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _BoardColumnHeader extends StatelessWidget {
  final BoardColumn column;

  const _BoardColumnHeader({required this.column});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent =
        PaletteEntry.hexToColor(column.stage?.color) ?? scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              column.title,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Text(
            '${column.totalCount}',
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (column.stage case final Stage stage)
            IconButton(
              icon: const Icon(Icons.more_vert, size: 18),
              tooltip: 'Column options',
              visualDensity: VisualDensity.compact,
              onPressed: () => _showColumnMenu(context, stage),
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }

  Future<void> _showColumnMenu(BuildContext context, Stage stage) async {
    final store = context.read<NotesStore>();
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename column'),
              onTap: () => Navigator.pop(context, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete column'),
              subtitle: const Text('Its notes go back to Unassigned'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    if (action == 'edit') {
      await StageEditorDialog.show(context, stage.id);
    } else {
      store.deleteStage(stage.id);
    }
  }
}

class _EmptyColumn extends StatelessWidget {
  final BoardColumn column;

  const _EmptyColumn({required this.column});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          column.isUnassigned
              ? 'Notes you have not placed yet appear here'
              : 'No notes in ${column.title}',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// Tail of a capped Unassigned column: says how much is held back and opens
/// the rest, so nothing is silently missing.
class _ShowAllTile extends StatelessWidget {
  final int hidden;
  final VoidCallback? onTap;

  const _ShowAllTile({required this.hidden, this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurfaceVariant,
          side: BorderSide(color: hairlineColor(scheme)),
          shape: const RoundedRectangleBorder(borderRadius: kBorderRadius),
        ),
        child: Text('Show $hidden more'),
      ),
    );
  }
}
