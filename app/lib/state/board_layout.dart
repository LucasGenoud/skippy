import '../models/note.dart';
import 'note_collection.dart';

/// One column of the board: a stage and the cards filed in it.
///
/// The unassigned column has a null [stage]. It is always first — it is the
/// board's inbox, where every note that has not been placed yet turns up.
class BoardColumn {
  /// The column's stage, or null for the unassigned column.
  final Stage? stage;

  /// Cards in this column, in board order.
  final List<Note> notes;

  /// How many cards the column actually holds. Differs from `notes.length`
  /// only on the unassigned column, whose display is capped — see
  /// [buildBoard].
  final int totalCount;

  const BoardColumn({
    required this.stage,
    required this.notes,
    required this.totalCount,
  });

  bool get isUnassigned => stage == null;

  /// Cards held back by the unassigned cap.
  int get hiddenCount => totalCount - notes.length;

  String get title => stage?.name ?? 'Unassigned';
}

/// A board: its columns, left to right.
class Board {
  final List<BoardColumn> columns;

  const Board(this.columns);

  /// True when the workspace has no stages at all — the board has never been
  /// set up, as opposed to being set up and empty.
  bool get hasNoStages => columns.every((column) => column.isUnassigned);

  bool get isEmpty =>
      columns.every((column) => column.notes.isEmpty) && hasNoStages;
}

/// How many unassigned cards the board shows before collapsing the rest behind
/// a count.
///
/// Without a cap, opening the board on a mature workspace means a first column
/// holding every note ever written — worst on a phone, where that column is the
/// whole screen. The cap keeps the inbox a place you triage from rather than
/// something you have to scroll past.
const int kUnassignedPreviewLimit = 20;

/// Groups [notes] into board columns.
///
/// Pure, like [selectNotes] in `note_collection.dart`, so the board's rules can
/// be tested without a widget tree and stay independent of how the store
/// persists things.
///
/// Labels play no part here. A note's column is its [Note.stageId] and nothing
/// else, which is what lets the board skip the "which of these does it really
/// belong to" question a label-derived board would have to answer.
Board buildBoard({
  required Iterable<Note> notes,
  required Iterable<Stage> stages,
  WorkspaceScope scope = const WorkspaceScope.all(),
  String query = '',
  bool showAllUnassigned = false,
}) {
  final normalizedQuery = query.trim().toLowerCase();
  final ordered = stages.toList()
    ..sort((a, b) => a.position.compareTo(b.position));
  final known = {for (final stage in ordered) stage.id};

  final buckets = <String?, List<Note>>{
    null: [],
    for (final stage in ordered) stage.id: [],
  };
  for (final note in notes) {
    if (!_isOnBoard(note) || !scope.contains(note)) continue;
    if (!_matchesQuery(note, normalizedQuery)) continue;
    // A stage the client hasn't caught up on yet — deleted elsewhere, or from
    // a workspace this note was just moved out of — reads as unassigned rather
    // than vanishing the card.
    final key = known.contains(note.stageId) ? note.stageId : null;
    buckets[key]!.add(note);
  }

  for (final bucket in buckets.values) {
    bucket.sort(_byPinnedThenPosition);
  }

  final unassigned = buckets[null]!;
  final capped = showAllUnassigned || unassigned.length <= kUnassignedPreviewLimit
      ? unassigned
      : unassigned.sublist(0, kUnassignedPreviewLimit);

  return Board([
    BoardColumn(
      stage: null,
      notes: capped,
      totalCount: unassigned.length,
    ),
    for (final stage in ordered)
      BoardColumn(
        stage: stage,
        notes: buckets[stage.id]!,
        totalCount: buckets[stage.id]!.length,
      ),
  ]);
}

/// The board shows live notes only. Archived and trashed ones have left the
/// workflow, and a board that accumulates them stops being a board.
bool _isOnBoard(Note note) => !note.archived && !note.trashed;

/// Pinned cards ride at the top of their column; everything else follows the
/// board's own order. The board always uses [Note.stagePosition] rather than
/// the grid's sort mode — a board whose cards reshuffle themselves is not a
/// board.
int _byPinnedThenPosition(Note a, Note b) {
  if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
  return a.stagePosition.compareTo(b.stagePosition);
}

bool _matchesQuery(Note note, String query) {
  if (query.isEmpty) return true;
  if (note.title.toLowerCase().contains(query)) return true;
  if (note.content.toLowerCase().contains(query)) return true;
  return note.items.any((item) => item.text.toLowerCase().contains(query));
}
