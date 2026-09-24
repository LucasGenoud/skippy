import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/note.dart';
import '../../state/board_layout.dart';
import '../../state/notes_store.dart';
import '../../state/settings_store.dart';
import '../../screens/editor_screen.dart';
import '../../theme.dart';
import '../../util/motion.dart';
import '../form_dialog.dart';
import '../masonry.dart';
import '../note_card.dart';
import 'stage_editor.dart';

/// One column of the board: a header and the cards filed in it.
///
/// The same widget serves both layouts, side by side on a wide screen, one per
/// page on a phone. Only the container around it differs, so the column's
/// behaviour is defined once.
///
/// Dragging is split along the line that keeps each half simple:
///
/// - **Within the column**, [AnimatedMasonry] does the work it already does for
///   the grid, lift, reflow around the pointer, edge auto-scroll, and reports
///   an explicit [MasonryReorder]. The board's pure ordering policy turns that
///   into one sparse-position write.
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

  /// Whether cards in this column can be picked up.
  final bool dragEnabled;

  /// Selection state, owned by the home screen so the top bar's action row
  /// works over the board exactly as it does over the grid.
  final bool selectionMode;
  final Set<String> selectedIds;
  final void Function(String noteId, bool selected)? onSelectionChanged;

  /// A collapsed column keeps its title and count in a narrow rail.
  final bool collapsed;
  final VoidCallback? onToggleCollapsed;

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
    this.collapsed = false,
    this.onToggleCollapsed,
  });

  @override
  State<BoardColumnView> createState() => _BoardColumnViewState();
}

class _BoardColumnViewState extends State<BoardColumnView> {
  /// Each column scrolls on its own, and the masonry needs this for its edge
  /// auto-scroll while a card is being dragged.
  final _scrollController = ScrollController();

  /// Reached for to read the pointer back into a drop index. Replaced when the
  /// column changes underneath us, so cards do not glide between unrelated
  /// columns.
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

  Iterable<String> _draggedIds(String noteId) =>
      widget.selectedIds.contains(noteId) ? widget.selectedIds : [noteId];

  /// A selection is foreign when at least one of its cards changes column.
  bool _isForeign(String noteId) {
    final here = {for (final note in widget.column.notes) note.id};
    return _draggedIds(noteId).any((id) => !here.contains(id));
  }

  /// Follow the carried card, but only rebuild when it crosses into a new
  /// slot, pointer samples arrive far faster than the answer changes, and
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
    final moved = store.noteById(noteId);
    if (moved == null) return;
    final index = _incomingIndex;
    _clearIncoming();
    // No confirmation snack here: the card visibly glides into its new slot,
    // which is the confirmation. A toast on top of a drag you just watched
    // happen is noise, not information.
    for (final id in _draggedIds(noteId)) {
      final note = store.noteById(id);
      if (note == null || note.stageId == _stageId) continue;
      store.setNoteStage(
        id,
        _stageId,
        position: id == noteId && index != null
            ? _positionForIncoming(moved, index)
            : null,
      );
    }
  }

  /// Inserts [moved] into the visual slot and lets the board's ordering policy
  /// resolve the numeric position inside its pinning group.
  double? _positionForIncoming(Note moved, int index) {
    final ordered = List<Note>.from(widget.column.notes);
    var safeIndex = index;
    if (safeIndex < 0) safeIndex = 0;
    if (safeIndex > ordered.length) safeIndex = ordered.length;
    ordered.insert(safeIndex, moved);
    return boardPositionForInsertion(moved: moved, ordered: ordered);
  }

  /// A drag inside the column: exactly one card moved, so write exactly one
  /// position, the midpoint between where it now sits.
  MasonryReorderDecision _reorderWithin(MasonryReorder reorder) {
    final store = context.read<NotesStore>();
    final moved = store.noteById(reorder.draggedId);
    // A neighbouring phone page or stage-strip target can accept the drag
    // while this masonry is finishing its animation. The target has already
    // updated the store in that case, so the old source column must never
    // write the carried card back into itself.
    if (moved == null ||
        moved.archived ||
        moved.trashed ||
        moved.stageId != _stageId) {
      return MasonryReorderDecision.restore;
    }
    final after = [
      for (final id in reorder.orderedIds)
        if (store.noteById(id) case final Note note) note,
    ];
    final position = boardPositionForReorder(
      moved: moved,
      before: widget.column.notes,
      after: after,
    );
    if (position == null || position == moved.stagePosition) {
      return MasonryReorderDecision.restore;
    }
    store.setNoteStage(moved.id, _stageId, position: position);
    return MasonryReorderDecision.keep;
  }

  @override
  Widget build(BuildContext context) {
    // The target covers the whole column, header included, aiming for a
    // column means aiming at its title as often as at its cards.
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => _isForeign(details.data),
      // Every column the pointer is over hears this, including one that just
      // refused the card, `_DragAvatar` reports moves to all entered targets,
      // not only the accepting one. Without the check, a card being lifted out
      // of this column would open a slot in it for itself.
      onMove: (details) => _isForeign(details.data)
          ? _trackIncoming(details.offset)
          : _clearIncoming(),
      onLeave: (_) => _clearIncoming(),
      onAcceptWithDetails: (details) => _acceptForeign(details.data),
      builder: (context, candidate, _) => _DropHighlight(
        active: candidate.isNotEmpty,
        child: AnimatedSwitcher(
          duration: Motion.reduced(context) ? Duration.zero : Motion.base,
          switchInCurve: Motion.standard,
          switchOutCurve: Motion.standard,
          transitionBuilder: (child, animation) =>
              widget.onToggleCollapsed != null &&
                  child.key == const ValueKey('expanded')
              ? OverflowBox(
                  minWidth: 300,
                  maxWidth: 300,
                  alignment: Alignment.topLeft,
                  child: FadeTransition(opacity: animation, child: child),
                )
              : FadeTransition(opacity: animation, child: child),
          child: widget.collapsed
              ? _CollapsedColumn(
                  key: const ValueKey('collapsed'),
                  column: widget.column,
                  onExpand: widget.onToggleCollapsed,
                )
              : Column(
                  key: const ValueKey('expanded'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Outside the header on purpose: the phone hides the header but
                    // still wants its column capped in the stage's colour.
                    _StageRule(column: widget.column),
                    if (widget.showHeader)
                      _BoardColumnHeader(
                        column: widget.column,
                        onToggleCollapsed: widget.onToggleCollapsed,
                      ),
                    Expanded(child: _body()),
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.tonalIcon(
                          onPressed: () => addCardToStage(context, _stageId),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add note'),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _body() {
    if (widget.column.notes.isEmpty) return _EmptyColumn(column: widget.column);
    return SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedMasonry(
            key: _masonryKey,
            notes: widget.column.notes,
            incomingIndex: _incomingIndex,
            columns: 1,
            spacing: 8,
            dragEnabled: widget.dragEnabled,
            draggableIds: widget.selectionMode ? widget.selectedIds : null,
            dragFeedbackLabel:
                widget.selectionMode && widget.selectedIds.length > 1
                ? 'Move ${widget.selectedIds.length} cards'
                : null,
            scrollController: _scrollController,
            onReorder: _reorderWithin,
            onStationaryLongPress: (id) => widget.onSelectionChanged?.call(
              id,
              !widget.selectedIds.contains(id),
            ),
            itemBuildKey: (note) => Object.hash(
              widget.query,
              widget.selectionMode,
              widget.selectedIds.contains(note.id),
            ),
            itemBuilder: (context, note) => NoteTile(
              key: ValueKey(note.id),
              note: note,
              query: widget.query,
              selectionMode: widget.selectionMode,
              selected: widget.selectedIds.contains(note.id),
              openedFromBoard: true,
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
    openedFromBoard: true,
    openFullscreen: () => Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditorScreen(stageId: stageId, openedFromBoard: true),
      ),
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
      duration: Motion.fast,
      curve: Motion.standard,
      decoration: BoxDecoration(
        color: active
            ? scheme.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        borderRadius: kBorderRadius,
      ),
      // The ring is a *foreground* decoration: a real border would inset the
      // column by its own width, and the header's stage rule has to reach the
      // column's edges whether a card is hovering or not.
      foregroundDecoration: BoxDecoration(
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
  final VoidCallback? onToggleCollapsed;

  const _BoardColumnHeader({required this.column, this.onToggleCollapsed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
          child: Row(
            children: [
              if (onToggleCollapsed != null)
                IconButton(
                  icon: const Icon(Icons.keyboard_double_arrow_left, size: 20),
                  tooltip: 'Collapse ${column.title}',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 36,
                  ),
                  onPressed: onToggleCollapsed,
                ),
              Expanded(
                child: Text(
                  column.title,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _CountChip(count: column.totalCount),
              ),
              if (column.stage case final Stage stage)
                IconButton(
                  icon: const Icon(Icons.more_vert, size: 18),
                  tooltip: 'Column options',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 36,
                  ),
                  onPressed: () => _showColumnMenu(context, stage),
                )
              else
                const SizedBox(width: 8),
            ],
          ),
        ),
        // Separates the title bar from the cards without boxing it: the stage
        // rule above and this one below are what turn the header into a header.
        Divider(height: 1, thickness: 1, color: boardColumnBorderColor(scheme)),
      ],
    );
  }

  Future<void> _showColumnMenu(BuildContext context, Stage stage) async {
    final store = context.read<NotesStore>();
    final action = await showAdaptiveSelectionSurface<String>(
      context,
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

class _CollapsedColumn extends StatelessWidget {
  final BoardColumn column;
  final VoidCallback? onExpand;

  const _CollapsedColumn({super.key, required this.column, this.onExpand});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Expand ${column.title}',
      child: InkWell(
        onTap: onExpand,
        mouseCursor: SystemMouseCursors.click,
        hoverColor: Colors.transparent,
        splashColor: Colors.transparent,
        child: Column(
          children: [
            _StageRule(column: column),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.keyboard_double_arrow_right,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 8),
                  RotatedBox(
                    quarterTurns: 3,
                    child: Text(
                      '${column.title} (${column.totalCount})',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  RotatedBox(
                    quarterTurns: 3,
                    child: Text(
                      'Expand',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The stage's colour, capping the column.
///
/// Promoted from the 8px dot the header used to carry: at board zoom that dot
/// was the smallest mark on the screen, and it was the only thing telling two
/// columns apart. Uncolored stages, and Unassigned, which is not a stage at
/// all, draw the rule in the column's own border colour, so every column is
/// capped the same way and only the ones you have coloured stand out.
class _StageRule extends StatelessWidget {
  final BoardColumn column;

  const _StageRule({required this.column});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 3,
      color:
          PaletteEntry.hexToColor(column.stage?.color) ??
          boardColumnBorderColor(scheme),
    );
  }
}

/// How many cards a column holds. Drawn on the card fill rather than as bare
/// text, so it reads as a tally attached to the column instead of as a number
/// floating between the title and the buttons.
class _CountChip extends StatefulWidget {
  final int count;

  const _CountChip({required this.count});

  @override
  State<_CountChip> createState() => _CountChipState();
}

class _CountChipState extends State<_CountChip> {
  late int _previousCount = widget.count;

  @override
  void didUpdateWidget(_CountChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    _previousCount = oldWidget.count;
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.count;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 40),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: kBorderRadius,
        border: Border.all(color: boardColumnBorderColor(scheme)),
      ),
      child: ClipRect(
        child: AnimatedSwitcher(
          duration: Motion.fast,
          transitionBuilder: (child, animation) {
            final childCount = (child.key as ValueKey<int>).value;
            final offset = childCount == count
                ? Offset(0, childCount > _previousCount ? 1 : -1)
                : Offset(0, childCount < count ? -1 : 1);
            return SlideTransition(
              position: Tween(
                begin: offset,
                end: Offset.zero,
              ).animate(animation),
              child: child,
            );
          },
          child: Text(
            '$count',
            key: ValueKey(count),
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
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
