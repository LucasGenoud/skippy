import '../models/note.dart';
import '../util/search_query.dart';
import 'note_collection.dart';

/// One column of the board: a stage and the cards filed in it.
///
/// The unassigned column has a null [stage]. It is always first, it is the
/// board's inbox, where every note that has not been placed yet turns up.
class BoardColumn {
  /// The column's stage, or null for the unassigned column.
  final Stage? stage;

  /// Cards in this column, in board order.
  final List<Note> notes;

  /// How many cards the column actually holds. Differs from `notes.length`
  /// only on the unassigned column, whose display is capped, see
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

  /// True when the workspace has no stages at all, the board has never been
  /// set up, as opposed to being set up and empty.
  bool get hasNoStages => columns.every((column) => column.isUnassigned);

  bool get isEmpty =>
      columns.every((column) => column.notes.isEmpty) && hasNoStages;
}

/// How many unassigned cards the board shows before collapsing the rest behind
/// a count.
///
/// Without a cap, opening the board on a mature workspace means a first column
/// holding every note ever written, worst on a phone, where that column is the
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

  /// Only needed to resolve `label:` terms in [query]; the board itself never
  /// groups by label.
  Iterable<Label> labels = const [],
  bool showAllUnassigned = false,
  Set<String>? rankedIds,
}) {
  // Semantic search narrows the board to what it ranked, but it does not
  // replace the query's filters: `label:work` still has to mean labelled work.
  // The ranking is global while a card's place is its column, so ranked cards
  // keep stage order rather than being re-sorted into a flat relevance list,
  // which would stop the result being a board.
  final all = parseSearchQuery(query);
  final parsed = rankedIds == null ? all : all.filtersOnly;
  final searchContext = SearchContext(labels);
  final ordered = stages.toList()
    ..sort((a, b) => a.position.compareTo(b.position));
  final known = {for (final stage in ordered) stage.id};

  final buckets = <String?, List<Note>>{
    null: [],
    for (final stage in ordered) stage.id: [],
  };
  for (final note in notes) {
    if (!_isOnBoard(note) || !scope.contains(note)) continue;
    if (rankedIds != null && !rankedIds.contains(note.id)) continue;
    if (!parsed.matches(note, searchContext)) continue;
    // A stage the client hasn't caught up on yet, deleted elsewhere, or from
    // a workspace this note was just moved out of, reads as unassigned rather
    // than vanishing the card.
    final key = known.contains(note.stageId) ? note.stageId : null;
    buckets[key]!.add(note);
  }

  for (final bucket in buckets.values) {
    bucket.sort(_byPinnedThenPosition);
  }

  final unassigned = buckets[null]!;
  final capped =
      showAllUnassigned || unassigned.length <= kUnassignedPreviewLimit
      ? unassigned
      : unassigned.sublist(0, kUnassignedPreviewLimit);

  return Board([
    BoardColumn(stage: null, notes: capped, totalCount: unassigned.length),
    for (final stage in ordered)
      BoardColumn(
        stage: stage,
        notes: buckets[stage.id]!,
        totalCount: buckets[stage.id]!.length,
      ),
  ]);
}

/// Resolves the sparse position for a card reordered within one board column.
///
/// Pinned and unpinned cards are separate ordering groups: [stagePosition]
/// orders cards only within a group, while pinning decides which group comes
/// first. Keeping that composite-order rule here ensures gesture widgets and
/// stores do not each implement a partial version of it.
///
/// Returns null when the dragged card did not change order relative to its own
/// group, or when either ordering is incomplete.
double? boardPositionForReorder({
  required Note moved,
  required Iterable<Note> before,
  required Iterable<Note> after,
}) {
  final beforePeers = _orderingPeers(moved, before);
  final afterPeers = _orderingPeers(moved, after);
  final beforeIds = [for (final note in beforePeers) note.id];
  final afterIds = [for (final note in afterPeers) note.id];
  if (beforeIds.length != afterIds.length ||
      !beforeIds.toSet().containsAll(afterIds) ||
      _sameOrder(beforeIds, afterIds)) {
    return null;
  }
  return _positionOf(moved.id, afterPeers);
}

/// Resolves the sparse position for [moved] inserted into an ordered column.
///
/// [ordered] must contain the incoming card at its intended visual slot. Cards
/// from the other pinning group are deliberately ignored when choosing the
/// numeric neighbours.
double? boardPositionForInsertion({
  required Note moved,
  required Iterable<Note> ordered,
}) => _positionOf(moved.id, _orderingPeers(moved, ordered));

List<Note> _orderingPeers(Note moved, Iterable<Note> notes) => [
  for (final note in notes)
    if (note.pinned == moved.pinned) note,
];

double? _positionOf(String movedId, List<Note> orderedPeers) {
  final index = orderedPeers.indexWhere((note) => note.id == movedId);
  if (index == -1) return null;
  final above = index > 0 ? orderedPeers[index - 1] : null;
  final below = index + 1 < orderedPeers.length
      ? orderedPeers[index + 1]
      : null;
  return _positionBetween(above, below);
}

/// A sparse position between two cards in the same board ordering group.
double _positionBetween(Note? above, Note? below) {
  if (above == null && below == null) return 1024.0;
  if (above == null) return below!.stagePosition - 1024.0;
  if (below == null) return above.stagePosition + 1024.0;
  return (above.stagePosition + below.stagePosition) / 2;
}

bool _sameOrder(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The board shows live notes only. Archived and trashed ones have left the
/// workflow, and a board that accumulates them stops being a board.
bool _isOnBoard(Note note) => !note.archived && !note.trashed;

/// Pinned cards ride at the top of their column; everything else follows the
/// board's own order. The board always uses [Note.stagePosition] rather than
/// the grid's sort mode, a board whose cards reshuffle themselves is not a
/// board.
int _byPinnedThenPosition(Note a, Note b) {
  if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
  return a.stagePosition.compareTo(b.stagePosition);
}
