import '../models/note.dart';
import '../util/search_query.dart';

/// [board] is a view like the others rather than a third state of the
/// grid/list toggle: it is incompatible with trash, archive, reminders and
/// label views, and has its own empty state and compose target.
///
/// [smart] is a saved search (see `models/saved_view.dart`). It shows the same
/// notes the grid does, narrowed by the view's stored query, which the home
/// screen supplies alongside whatever is typed in the search box.
enum NoteView { notes, board, reminders, archive, trash, label, smart }

enum SortMode { custom, edited, newest, oldest }

class ViewSelection {
  final NoteView view;
  final String? labelId;

  /// Which saved view is open, for [NoteView.smart]. The query itself lives in
  /// the settings document, not here: a selection stays a pointer, so renaming
  /// or editing a smart view takes effect without re-selecting it.
  final String? savedViewId;

  const ViewSelection(this.view, [this.labelId]) : savedViewId = null;

  const ViewSelection.smart(String id)
    : view = NoteView.smart,
      labelId = null,
      savedViewId = id;

  static const notes = ViewSelection(NoteView.notes);
  static const board = ViewSelection(NoteView.board);
  static const reminders = ViewSelection(NoteView.reminders);
  static const archive = ViewSelection(NoteView.archive);
  static const trash = ViewSelection(NoteView.trash);

  @override
  bool operator ==(Object other) =>
      other is ViewSelection &&
      other.view == view &&
      other.labelId == labelId &&
      other.savedViewId == savedViewId;

  @override
  int get hashCode => Object.hash(view, labelId, savedViewId);
}

/// Which workspace's notes a view shows.
///
/// A note shared with you directly can live in a workspace you're not a member
/// of. It still has to appear somewhere, so those fall into the default
/// workspace, the one place every account has.
class WorkspaceScope {
  /// The open workspace, or null to show every note the user can see.
  final String? workspaceId;

  /// Whether [workspaceId] is the user's default workspace, which also
  /// collects notes from workspaces they don't belong to.
  final bool isDefault;

  /// The workspaces the user belongs to; a note filed outside all of them
  /// reached them through a direct share.
  final Set<String> known;

  const WorkspaceScope({
    required this.workspaceId,
    required this.isDefault,
    required this.known,
  });

  /// No filtering, used by exports, search, and tests that predate
  /// workspaces.
  const WorkspaceScope.all()
    : workspaceId = null,
      isDefault = false,
      known = const {};

  bool contains(Note note) => containsWorkspace(note.workspaceId);

  /// Whether content filed in [id] shows in this scope. Content from a
  /// workspace the user doesn't belong to, a directly shared note, or a
  /// cache written before workspaces existed, surfaces in the default one.
  bool containsWorkspace(String id) {
    final active = workspaceId;
    if (active == null) return true;
    if (id == active) return true;
    return isDefault && !known.contains(id);
  }
}

class NoteSections {
  final List<Note> pinned;
  final List<Note> others;

  const NoteSections(this.pinned, this.others);

  bool get isEmpty => pinned.isEmpty && others.isEmpty;
}

/// Selects, searches, sorts, and groups notes for the home screen.
///
/// Keeping this as a pure function makes the view rules independent from the
/// optimistic persistence and synchronization responsibilities of NotesStore.
NoteSections selectNotes({
  required Iterable<Note> notes,
  required Iterable<Label> labels,
  required ViewSelection selection,
  required String query,
  required SortMode sortMode,
  required String? currentUserId,
  WorkspaceScope scope = const WorkspaceScope.all(),
}) {
  final visible = filterNotes(
    notes: notes,
    labels: labels,
    selection: selection,
    query: parseSearchQuery(query),
    currentUserId: currentUserId,
    scope: scope,
  );

  if (selection.view == NoteView.reminders) {
    // Soonest first, of either kind: a note whose only alarm sits on one of
    // its checklist items belongs among the rest, not after them.
    visible.sort((a, b) => a.nextReminderAt!.compareTo(b.nextReminderAt!));
    return NoteSections(const [], visible);
  }

  _sortNotes(visible, sortMode);
  final splitPins =
      selection.view == NoteView.notes ||
      selection.view == NoteView.label ||
      selection.view == NoteView.smart;
  if (!splitPins) return NoteSections(const [], visible);

  return NoteSections(
    visible.where((note) => note.pinned).toList(),
    visible.where((note) => !note.pinned).toList(),
  );
}

/// Which notes belong in [selection] under [query], in whatever order they
/// arrived.
///
/// Split out of [selectNotes] because the semantic path needs exactly this and
/// nothing else: the server's relevance ranking IS the order there, so it
/// sorts nothing, but the view's rules and the query's filters still have to
/// apply. Sharing this function is what keeps `label:work is:pinned` meaning
/// the same thing with meaning-ranking on as with it off.
List<Note> filterNotes({
  required Iterable<Note> notes,
  required Iterable<Label> labels,
  required ViewSelection selection,

  /// Already parsed, so the semantic path can hand over
  /// [SearchQuery.filtersOnly] rather than a string it would have to
  /// re-serialize.
  required SearchQuery query,
  required String? currentUserId,
  WorkspaceScope scope = const WorkspaceScope.all(),
}) {
  final context = SearchContext(labels);
  // An explicit `is:archived` / `is:trashed` is more specific than the view's
  // own state filter, so it replaces it: searching for archived notes from the
  // notes view finds them instead of matching nothing.
  final override = query.stateOverride;
  return notes
      .where(
        (note) =>
            scope.contains(note) &&
            _isInView(note, selection, currentUserId, override) &&
            query.matches(note, context),
      )
      .toList();
}

bool _isInView(
  Note note,
  ViewSelection selection,
  String? currentUserId,
  StateOverride? override,
) {
  // Views that show live notes hand their state filter over to an explicit
  // `is:` operator. Archive and trash already are that state, and reminders
  // spans both, so none of them defer.
  final defers =
      selection.view == NoteView.notes ||
      selection.view == NoteView.board ||
      selection.view == NoteView.label ||
      selection.view == NoteView.smart;
  if (defers && override != null) {
    final passesState = switch (override) {
      // Collaborators never see a trashed note (see the trash view below), so
      // an override cannot reveal one either.
      StateOverride.trashed => note.trashed && note.isOwnedBy(currentUserId),
      StateOverride.archived => note.archived && !note.trashed,
    };
    if (!passesState) return false;
    return selection.view != NoteView.label ||
        note.labelIds.contains(selection.labelId);
  }
  return switch (selection.view) {
    // A smart view starts from the live notes and lets its saved query narrow
    // them, so one that says nothing about state behaves like the grid.
    NoteView.notes || NoteView.smart => !note.archived && !note.trashed,
    // The board groups notes by stage rather than filtering a flat list, so
    // it builds its own columns (see state/board_layout.dart) and never
    // reaches selectNotes. Matching `notes` keeps the switch total and any
    // caller that does pass it here sensible.
    NoteView.board => !note.archived && !note.trashed,
    NoteView.reminders => note.hasReminder && !note.trashed,
    NoteView.archive => note.archived && !note.trashed,
    // Collaborators cannot trash notes. If an owner trashes a shared note,
    // it disappears for collaborators instead of entering their trash.
    NoteView.trash => note.trashed && note.isOwnedBy(currentUserId),
    NoteView.label =>
      !note.trashed && note.labelIds.contains(selection.labelId),
  };
}

void _sortNotes(List<Note> notes, SortMode mode) {
  switch (mode) {
    case SortMode.custom:
      break; // The store keeps its source collection position-sorted.
    case SortMode.edited:
      notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    case SortMode.newest:
      notes.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    case SortMode.oldest:
      notes.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }
}
