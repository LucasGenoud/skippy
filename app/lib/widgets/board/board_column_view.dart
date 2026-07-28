import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/note.dart';
import '../../state/board_layout.dart';
import '../../state/notes_store.dart';
import '../../state/settings_store.dart';
import '../../screens/editor_screen.dart';
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
///   already hold. It holds a slot open under the carried card and drops it
///   there, so arriving in a column and placing it are one gesture rather than
///   two. Keeping the target here rather than inside the masonry is what lets
///   an empty column receive a card at all (an empty masonry has no size).
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

  /// Whether cards in this column can be picked up. Selection mode turns it
  /// off, matching the grid: a long press means "select" then, not "lift".
  final bool dragEnabled;

  /// Selection state, owned by the home screen so the top bar's action row
  /// works over the board exactly as it does over the grid.
  final bool selectionMode;
  final Set<String> selectedIds;
  final void Function(String noteId, bool selected)? onSelectionChanged;

  /// Compose a note already filed in this column. Supplied by the phone
  /// layout, which hides the header the button normally lives in.
  final VoidCallback? onAddCard;

  const BoardColumnView({
    super.key,
    required this.column,
    this.query = '',
    this.onShowAll,
    this.showHeader = true,
    this.dragEnabled = true,
    this.selectionMode = false,
    this.selectedIds = const {},
    this.onSelectionChanged,
    this.onAddCard,
  });

  @override
  State<BoardColumnView> createState() => _BoardColumnViewState();
}

class _BoardColumnViewState extends State<BoardColumnView> {
  /// Each column scrolls on its own, and the masonry needs this for its edge
  /// auto-scroll while a card is being dragged.
  final _scrollController = ScrollController();

  /// Reached for to read the pointer back into a drop index. Replaced when the
  /// column changes underneath us, which is what replays the entrance rather
  /// than gliding cards between unrelated columns.
  GlobalKey<AnimatedMasonryState> _masonryKey = GlobalKey();

  /// Where a card from another column would land right now, or null when
  /// nothing is hovering.
  int? _incomingIndex;

  @override
  void didUpdateWidget(BoardColumnView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.column.stage?.id != _stageId) {
      _masonryKey = GlobalKey();
      _incomingIndex = null;
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  String? get _stageId => widget.column.stage?.id;

  /// A card already here is the masonry's business, not a transfer.
  bool _isForeign(String noteId) =>
      !widget.column.notes.any((note) => note.id == noteId);

  /// Follow the carried card, but only rebuild when it crosses into a new
  /// slot — pointer samples arrive far faster than the answer changes, and
  /// each rebuild costs the masonry its tile cache.
  void _trackIncoming(Offset globalTop) {
    final index = _masonryKey.currentState?.insertionIndexAt(globalTop) ?? 0;
    if (index != _incomingIndex) setState(() => _incomingIndex = index);
  }

  void _clearIncoming() {
    if (_incomingIndex != null) setState(() => _incomingIndex = null);
  }

  void _acceptForeign(String noteId) {
    final store = context.read<NotesStore>();
    final index = _incomingIndex;
    _clearIncoming();
    final from = store.noteById(noteId);
    store.setNoteStage(noteId, _stageId, position: _positionAt(index));
    showAppSnack(
      'Moved to ${widget.column.title}',
      icon: Icons.view_kanban_outlined,
      actionLabel: 'Undo',
      // Its old slot, not just its old column: undoing a placement that chose
      // where the card went should not drop it at the end of where it came
      // from.
      onAction: () => store.setNoteStage(
        noteId,
        from?.stageId,
        position: from?.stagePosition,
      ),
    );
  }

  /// The slot [index] names, as a position between the cards it falls between.
  /// Null when the column never got a hover to place it — an empty column has
  /// no masonry to aim at — which leaves the card at the end.
  double? _positionAt(int? index) {
    if (index == null) return null;
    final notes = widget.column.notes;
    Note? at(int i) => i < 0 || i >= notes.length ? null : notes[i];
    return NotesStore.positionBetween(at(index - 1), at(index));
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
      // Every column the pointer is over hears this, including one that just
      // refused the card — `_DragAvatar` reports moves to all entered targets,
      // not only the accepting one. Without the check, a card being lifted out
      // of this column would open a slot in it for itself.
      onMove: (details) => _isForeign(details.data)
          ? _trackIncoming(details.offset)
          : _clearIncoming(),
      onLeave: (_) => _clearIncoming(),
      onAcceptWithDetails: (details) => _acceptForeign(details.data),
      builder: (context, candidate, _) => _DropHighlight(
        active: candidate.isNotEmpty,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showHeader) _BoardColumnHeader(column: widget.column),
            if (!widget.showHeader && widget.onAddCard != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: widget.onAddCard,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add note'),
                ),
              ),
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
            key: _masonryKey,
            notes: widget.column.notes,
            incomingIndex: _incomingIndex,
            columns: 1,
            spacing: 8,
            // A long press selects rather than lifts while selecting, the
            // same rule the grid follows.
            dragEnabled: widget.dragEnabled && !widget.selectionMode,
            // Board cards must be visible on the first frame; see the flag's
            // doc on why the grid's cascade is the wrong default here.
            staggeredEntrance: false,
            scrollController: _scrollController,
            onReorder: _reorderWithin,
            onStationaryLongPress: (id) => widget.onSelectionChanged?.call(
              id,
              !widget.selectedIds.contains(id),
            ),
            itemBuilder: (context, note) => NoteTile(
              key: ValueKey(note.id),
              note: note,
              query: widget.query,
              selectionMode: widget.selectionMode,
              selected: widget.selectedIds.contains(note.id),
              onSelectionChanged: (selected) =>
                  widget.onSelectionChanged?.call(note.id, selected),
            ),
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

/// Compose a note already filed in [stageId] (null for Unassigned).
///
/// Mirrors how the home screen composes into a label view: the draft is filed
/// from birth rather than created loose and moved afterwards.
Future<void> addCardToStage(BuildContext context, String? stageId) {
  return openNoteEditor(
    context,
    stageId: stageId,
    openFullscreen: () => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => EditorScreen(stageId: stageId)),
    ),
  );
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
          IconButton(
            icon: const Icon(Icons.add, size: 18),
            tooltip: 'Add a note to ${column.title}',
            visualDensity: VisualDensity.compact,
            onPressed: () => addCardToStage(context, column.stage?.id),
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
