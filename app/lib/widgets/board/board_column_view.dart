import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/note.dart';
import '../../state/board_layout.dart';
import '../../state/notes_store.dart';
import '../../state/settings_store.dart';
import '../../theme.dart';
import '../../util/snack.dart';
import '../masonry.dart';
import '../note_card.dart';
import 'stage_editor.dart';

/// One column of the board: a header and the cards filed in it.
///
/// The same widget serves both layouts — side by side on a wide screen, one per
/// page on a phone. Only the container around it differs, so the column's
/// behaviour is defined once.
///
/// Dragging is split along the line that keeps each half simple:
///
/// - **Within the column**, [AnimatedMasonry] does the work it already does for
///   the grid — lift, reflow around the pointer, edge auto-scroll — and reports
///   the reordered column, which becomes one midpoint write.
/// - **Between columns**, this widget is a [DragTarget] for cards it does not
///   already hold. Dropped cards land at the end; drag again to place them.
///   Keeping the target here rather than inside the masonry is what lets an
///   empty column receive a card at all (an empty masonry has no size).
class BoardColumnView extends StatefulWidget {
  final BoardColumn column;

  /// The active search query, forwarded to cards for match highlighting.
  final String query;

  /// Invoked when the "show the rest" affordance on a capped Unassigned column
  /// is tapped. Null on every other column.
  final VoidCallback? onShowAll;

  /// Whether to draw the column's own header. The phone layout shows stage
  /// names in its page strip instead, so it turns this off.
  final bool showHeader;

  /// Whether cards in this column can be picked up. The phone board turns this
  /// off: there, cards move by being dropped on the stage strip, and a
  /// long-press drag inside a horizontally paging view fights the page swipe.
  final bool dragEnabled;

  const BoardColumnView({
    super.key,
    required this.column,
    this.query = '',
    this.onShowAll,
    this.showHeader = true,
    this.dragEnabled = true,
  });

  @override
  State<BoardColumnView> createState() => _BoardColumnViewState();
}

class _BoardColumnViewState extends State<BoardColumnView> {
  /// Each column scrolls on its own, and the masonry needs this for its edge
  /// auto-scroll while a card is being dragged.
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  String? get _stageId => widget.column.stage?.id;

  /// A card already here is the masonry's business, not a transfer.
  bool _isForeign(String noteId) =>
      !widget.column.notes.any((note) => note.id == noteId);

  void _acceptForeign(String noteId) {
    final store = context.read<NotesStore>();
    final from = store.noteById(noteId)?.stageId;
    store.setNoteStage(noteId, _stageId);
    showAppSnack(
      'Moved to ${widget.column.title}',
      icon: Icons.view_kanban_outlined,
      actionLabel: 'Undo',
      onAction: () => store.setNoteStage(noteId, from),
    );
  }

  /// A drag inside the column: exactly one card moved, so write exactly one
  /// position — the midpoint between where it now sits.
  void _reorderWithin(List<String> orderedIds) {
    final before = [for (final note in widget.column.notes) note.id];
    final movedId = movedCardId(before, orderedIds);
    if (movedId == null) return;
    final store = context.read<NotesStore>();
    final index = orderedIds.indexOf(movedId);
    Note? neighbour(int at) =>
        at < 0 || at >= orderedIds.length ? null : store.noteById(orderedIds[at]);
    store.setNoteStage(
      movedId,
      _stageId,
      position: NotesStore.positionBetween(
        neighbour(index - 1),
        neighbour(index + 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The target covers the whole column, header included — aiming for a
    // column means aiming at its title as often as at its cards.
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => _isForeign(details.data),
      onAcceptWithDetails: (details) => _acceptForeign(details.data),
      builder: (context, candidate, _) => _DropHighlight(
        active: candidate.isNotEmpty,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showHeader) _BoardColumnHeader(column: widget.column),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (widget.column.notes.isEmpty) return _EmptyColumn(column: widget.column);
    return SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedMasonry(
            // Re-key per column so switching stages replays the entrance
            // rather than gliding cards between unrelated columns.
            key: ValueKey('board-${_stageId ?? 'unassigned'}'),
            notes: widget.column.notes,
            columns: 1,
            spacing: 8,
            dragEnabled: widget.dragEnabled,
            scrollController: _scrollController,
            onReorder: _reorderWithin,
            itemBuilder: (context, note) =>
                NoteTile(key: ValueKey(note.id), note: note, query: widget.query),
          ),
          if (widget.column.hiddenCount > 0)
            _ShowAllTile(
              hidden: widget.column.hiddenCount,
              onTap: widget.onShowAll,
            ),
        ],
      ),
    );
  }
}

/// Tints a column while a card from elsewhere hovers over it, so the drop
/// target is legible without previewing a slot the drop does not promise.
class _DropHighlight extends StatelessWidget {
  final bool active;
  final Widget child;

  const _DropHighlight({required this.active, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      decoration: BoxDecoration(
        color: active
            ? scheme.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        borderRadius: kBorderRadius,
        border: Border.all(
          color: active ? scheme.primary : Colors.transparent,
          width: 2,
        ),
      ),
      child: child,
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
              : 'Drop notes here',
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
