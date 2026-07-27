import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/board_layout.dart';
import '../../state/notes_store.dart';
import '../../state/settings_store.dart';
import '../../theme.dart';
import '../../util/snack.dart';
import '../empty_state.dart';
import 'board_column_view.dart';
import 'stage_editor.dart';

/// The board: one column per stage, plus Unassigned.
///
/// Two containers over one column widget. Wide screens scroll the columns
/// horizontally and show them side by side; phones page through them one at a
/// time behind a strip of column names, because a row of 300px columns on a
/// 375px screen is a worse grid rather than a board.
class BoardView extends StatefulWidget {
  /// The active search query, forwarded to cards for match highlighting.
  final String query;

  /// Note ids the server ranked for a semantic search, or null when the board
  /// is filtering by keyword. Only these cards stay on the board.
  final Set<String>? rankedIds;

  /// Selection state, owned by the home screen so the top bar's action row
  /// works the same here as it does over the grid.
  final bool selectionMode;
  final Set<String> selectedIds;
  final void Function(String noteId, bool selected)? onSelectionChanged;

  const BoardView({
    super.key,
    this.query = '',
    this.rankedIds,
    this.selectionMode = false,
    this.selectedIds = const {},
    this.onSelectionChanged,
  });

  /// Below this the board pages instead of laying columns side by side. Matches
  /// the breakpoint the rest of the app uses for its phone layout.
  static const double pagedBreakpoint = 600;

  static const double _columnWidth = 300;

  @override
  State<BoardView> createState() => _BoardViewState();
}

class _BoardViewState extends State<BoardView> {
  /// Whether the Unassigned column is showing everything rather than its
  /// capped preview. Resets when the board is left, which is the point: the
  /// cap is about what you open onto.
  bool _showAllUnassigned = false;

  /// Columns do not fill the page: the neighbours peek in at either edge, so
  /// a phone shows that a board *has* columns rather than presenting one list
  /// at a time. It also puts the next column within drag reach.
  final _pageController = PageController(viewportFraction: 0.86);

  /// Horizontal scroll of the whole board on wide screens; also what the edge
  /// zones drive while a card is being carried.
  final _boardController = ScrollController();
  int _page = 0;

  @override
  void dispose() {
    _pageController.dispose();
    _boardController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final board = buildBoard(
      notes: store.notesInActiveWorkspace,
      stages: store.stages,
      scope: store.workspaceScope,
      query: widget.query,
      showAllUnassigned: _showAllUnassigned,
      rankedIds: widget.rankedIds,
    );

    if (board.hasNoStages) return _NoStagesYet(hasNotes: !board.isEmpty);

    final paged =
        MediaQuery.sizeOf(context).width < BoardView.pagedBreakpoint;
    return paged ? _buildPaged(board) : _buildColumns(board);
  }

  void _showAll() => setState(() => _showAllUnassigned = true);

  /// A card carried up from the page below and dropped on a stage chip. This
  /// is the phone's move gesture: short travel, and no page turns under the
  /// finger the way dragging across a `PageView` would.
  void _dropOnStage(String noteId, BoardColumn column) {
    final store = context.read<NotesStore>();
    final from = store.noteById(noteId)?.stageId;
    store.setNoteStage(noteId, column.stage?.id);
    showAppSnack(
      'Moved to ${column.title}',
      icon: Icons.view_kanban_outlined,
      actionLabel: 'Undo',
      onAction: () => store.setNoteStage(noteId, from),
    );
  }

  Widget _buildColumns(Board board) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: ListView.builder(
            controller: _boardController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            // One past the columns: the tail tile. The empty state's "Add a
            // column" button disappears with the first stage, so without this
            // the column editor would be unreachable on a board that has one.
            itemCount: board.columns.length + 1,
            itemBuilder: (context, index) {
              if (index == board.columns.length) return const _AddColumnTile();
              final column = board.columns[index];
              return Container(
                width: BoardView._columnWidth,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: kBorderRadius,
                  border: Border.all(color: hairlineColor(scheme)),
                ),
                child: BoardColumnView(
                  column: column,
                  query: widget.query,
                  onShowAll: column.isUnassigned ? _showAll : null,
                  selectionMode: widget.selectionMode,
                  selectedIds: widget.selectedIds,
                  onSelectionChanged: widget.onSelectionChanged,
                ),
              );
            },
          ),
        ),
        // Carrying a card to a column that is off-screen needs the board to
        // move under it. These two strips do that while a card hovers them.
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: _EdgeScrollZone(
            controller: _boardController,
            towardsStart: true,
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: _EdgeScrollZone(
            controller: _boardController,
            towardsStart: false,
          ),
        ),
      ],
    );
  }

  Widget _buildPaged(Board board) {
    // A stage deleted while the board is open can leave the controller past
    // the end; clamp rather than page into nothing.
    final page = _page.clamp(0, board.columns.length - 1);
    return Column(
      children: [
        _StageStrip(
          columns: board.columns,
          current: page,
          onSelect: (index) => _pageController.animateToPage(
            index,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
          ),
          onWillDrop: (noteId, column) =>
              context.read<NotesStore>().noteById(noteId)?.stageId !=
              column.stage?.id,
          onDrop: _dropOnStage,
        ),
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: board.columns.length,
            onPageChanged: (index) => setState(() => _page = index),
            itemBuilder: (context, index) {
              final column = board.columns[index];
              return BoardColumnView(
                column: column,
                query: widget.query,
                onShowAll: column.isUnassigned ? _showAll : null,
                selectionMode: widget.selectionMode,
                selectedIds: widget.selectedIds,
                onSelectionChanged: widget.onSelectionChanged,
                // The strip above already names the column and counts it,
                // but the add button has nowhere else to live on a phone.
                showHeader: false,
                onAddCard: () => addCardToStage(context, column.stage?.id),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The board's tail on wide screens: opens the column editor.
///
/// Sits where the next column would go, which is where you reach for it. Drawn
/// as an outline rather than a filled column so it reads as an invitation and
/// not as a column holding nothing.
class _AddColumnTile extends StatelessWidget {
  const _AddColumnTile();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: BoardView._columnWidth,
      margin: const EdgeInsets.only(right: 12),
      child: InkWell(
        onTap: () => EditStagesDialog.show(context),
        borderRadius: kBorderRadius,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: kBorderRadius,
            border: Border.all(color: hairlineColor(scheme)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(
                'Add column',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A thin strip at the board's edge that scrolls it while a dragged card
/// hovers there, so a column off the side of the screen is still reachable.
///
/// A `DragTarget` that never accepts: it only wants to know a card is over it.
/// `onMove` stops firing when the pointer holds still, so the scrolling is
/// driven by a timer between enter and leave rather than by pointer samples.
class _EdgeScrollZone extends StatefulWidget {
  final ScrollController controller;

  /// Which way to travel: towards the board's start (left) or its end.
  final bool towardsStart;

  const _EdgeScrollZone({required this.controller, required this.towardsStart});

  static const double width = 56;
  static const double _pixelsPerTick = 14;

  @override
  State<_EdgeScrollZone> createState() => _EdgeScrollZoneState();
}

class _EdgeScrollZoneState extends State<_EdgeScrollZone> {
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final position = widget.controller.position;
      final delta = widget.towardsStart
          ? -_EdgeScrollZone._pixelsPerTick
          : _EdgeScrollZone._pixelsPerTick;
      final next = (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (next == position.pixels) return;
      widget.controller.jumpTo(next);
    });
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      // Never accepts: a drop here should fall through to whatever column has
      // scrolled under the pointer, not vanish into the edge.
      onWillAcceptWithDetails: (_) => false,
      onMove: (_) {
        if (_timer == null && widget.controller.hasClients) _start();
      },
      onLeave: (_) => _stop(),
      builder: (context, _, _) =>
          const SizedBox(width: _EdgeScrollZone.width),
    );
  }
}

/// The phone board's column switcher: names and counts, scrollable, current
/// one highlighted. Doubles as the header the paged columns leave out, and as
/// the phone's drop target — a card is carried up to a chip rather than across
/// pages, so nothing has to turn under the finger.
class _StageStrip extends StatefulWidget {
  final List<BoardColumn> columns;
  final int current;
  final ValueChanged<int> onSelect;

  /// Whether [noteId] may be dropped on [column] — false for the column it is
  /// already in, so the chip does not light up for a no-op.
  final bool Function(String noteId, BoardColumn column)? onWillDrop;

  /// A card was carried up from the page below and dropped on a chip.
  final void Function(String noteId, BoardColumn column)? onDrop;

  const _StageStrip({
    required this.columns,
    required this.current,
    required this.onSelect,
    this.onWillDrop,
    this.onDrop,
  });

  @override
  State<_StageStrip> createState() => _StageStripState();
}

class _StageStripState extends State<_StageStrip> {
  final _controller = ScrollController();
  final Map<int, GlobalKey> _chipKeys = {};

  @override
  void didUpdateWidget(_StageStrip old) {
    super.didUpdateWidget(old);
    if (old.current != widget.current) _revealCurrent();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Keep the open column's chip on screen. Without this a chip can sit past
  /// the right edge, which is not merely awkward to tap — it is unreachable as
  /// a drop target, because you cannot scroll the strip while holding a card.
  void _revealCurrent() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final chip = _chipKeys[widget.current]?.currentContext;
      if (chip == null) return;
      Scrollable.ensureVisible(
        chip,
        alignment: 0.5,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    // Every chip is built, not just the visible ones: a board has a handful of
    // columns, and [Scrollable.ensureVisible] can only reach a chip that
    // exists — which is exactly the off-screen one it is needed for.
    return SizedBox(
      height: 44,
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            for (final (index, column) in widget.columns.indexed)
              Padding(
                key: _chipKeys.putIfAbsent(index, GlobalKey.new),
                padding: const EdgeInsets.only(right: 8),
                child: DragTarget<String>(
                  onWillAcceptWithDetails: (details) =>
                      widget.onWillDrop?.call(details.data, column) ?? false,
                  onAcceptWithDetails: (details) =>
                      widget.onDrop?.call(details.data, column),
                  builder: (context, candidate, _) => _StageChip(
                    column: column,
                    selected: index == widget.current,
                    hovered: candidate.isNotEmpty,
                    onTap: () => widget.onSelect(index),
                  ),
                ),
              ),
            // Last in the strip, after the columns it adds to. The phone hides
            // the column headers, so this is its only route to the editor —
            // rename and delete arrive with it.
            const _AddColumnChip(),
          ],
        ),
      ),
    );
  }
}

/// The strip's trailing chip: opens the column editor.
class _AddColumnChip extends StatelessWidget {
  const _AddColumnChip();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => EditStagesDialog.show(context),
      borderRadius: kBorderRadius,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          borderRadius: kBorderRadius,
          border: Border.all(color: hairlineColor(scheme)),
        ),
        child: Row(
          children: [
            Icon(Icons.add, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              'Add column',
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// One column's chip in the phone strip: a navigation control and, while a
/// card is in the air, a drop target.
class _StageChip extends StatelessWidget {
  final BoardColumn column;
  final bool selected;
  final bool hovered;
  final VoidCallback onTap;

  const _StageChip({
    required this.column,
    required this.selected,
    required this.hovered,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent =
        PaletteEntry.hexToColor(column.stage?.color) ?? scheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: kBorderRadius,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: hovered
              ? scheme.primaryContainer
              : selected
              ? scheme.secondaryContainer
              : Colors.transparent,
          borderRadius: kBorderRadius,
          border: Border.all(
            color: hovered
                ? scheme.primary
                : selected
                ? Colors.transparent
                : hairlineColor(scheme),
            width: hovered ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(
              column.title,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: selected
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${column.totalCount}',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when the workspace has no columns: the board exists but has never
/// been set up, which is a different thing from an empty board.
class _NoStagesYet extends StatelessWidget {
  final bool hasNotes;

  const _NoStagesYet({required this.hasNotes});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Expanded(
          child: EmptyState(
            icon: Icons.view_kanban_outlined,
            message: 'Add columns to build a board\n'
                'for this workspace',
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 48),
          child: FilledButton.icon(
            onPressed: () => EditStagesDialog.show(context),
            icon: const Icon(Icons.add),
            label: const Text('Add a column'),
          ),
        ),
      ],
    );
  }
}
