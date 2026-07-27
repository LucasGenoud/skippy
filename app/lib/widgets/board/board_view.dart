import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/board_layout.dart';
import '../../state/notes_store.dart';
import '../../state/settings_store.dart';
import '../../theme.dart';
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

  const BoardView({super.key, this.query = ''});

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

  final _pageController = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pageController.dispose();
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
    );

    if (board.hasNoStages) return _NoStagesYet(hasNotes: !board.isEmpty);

    final paged =
        MediaQuery.sizeOf(context).width < BoardView.pagedBreakpoint;
    return paged ? _buildPaged(board) : _buildColumns(board);
  }

  void _showAll() => setState(() => _showAllUnassigned = true);

  Widget _buildColumns(Board board) {
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      itemCount: board.columns.length,
      itemBuilder: (context, index) {
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
          ),
        );
      },
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
                // The strip above already names the column and counts it.
                showHeader: false,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The phone board's column switcher: names and counts, scrollable, current
/// one highlighted. Doubles as the header the paged columns leave out.
class _StageStrip extends StatelessWidget {
  final List<BoardColumn> columns;
  final int current;
  final ValueChanged<int> onSelect;

  const _StageStrip({
    required this.columns,
    required this.current,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: columns.length,
        itemBuilder: (context, index) {
          final column = columns[index];
          final selected = index == current;
          final accent =
              PaletteEntry.hexToColor(column.stage?.color) ??
              scheme.onSurfaceVariant;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              onTap: () => onSelect(index),
              borderRadius: kBorderRadius,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: selected
                      ? scheme.secondaryContainer
                      : Colors.transparent,
                  borderRadius: kBorderRadius,
                  border: Border.all(
                    color: selected
                        ? Colors.transparent
                        : hairlineColor(scheme),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                      ),
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
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
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
