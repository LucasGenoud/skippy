import '../models/note.dart';

enum NoteView { notes, reminders, archive, trash, label }

enum SortMode { custom, edited, newest, oldest }

class ViewSelection {
  final NoteView view;
  final String? labelId;

  const ViewSelection(this.view, [this.labelId]);

  static const notes = ViewSelection(NoteView.notes);
  static const reminders = ViewSelection(NoteView.reminders);
  static const archive = ViewSelection(NoteView.archive);
  static const trash = ViewSelection(NoteView.trash);

  @override
  bool operator ==(Object other) =>
      other is ViewSelection && other.view == view && other.labelId == labelId;

  @override
  int get hashCode => Object.hash(view, labelId);
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
}) {
  final normalizedQuery = query.trim().toLowerCase();
  final labelsById = {for (final label in labels) label.id: label};
  final visible = notes
      .where(
        (note) =>
            _isInView(note, selection, currentUserId) &&
            _matchesQuery(note, normalizedQuery, labelsById),
      )
      .toList();

  if (selection.view == NoteView.reminders) {
    visible.sort((a, b) => a.reminderAt!.compareTo(b.reminderAt!));
    return NoteSections(const [], visible);
  }

  _sortNotes(visible, sortMode);
  final splitPins =
      selection.view == NoteView.notes || selection.view == NoteView.label;
  if (!splitPins) return NoteSections(const [], visible);

  return NoteSections(
    visible.where((note) => note.pinned).toList(),
    visible.where((note) => !note.pinned).toList(),
  );
}

bool _matchesQuery(Note note, String query, Map<String, Label> labelsById) {
  if (query.isEmpty) return true;
  if (note.title.toLowerCase().contains(query)) return true;
  if (note.content.toLowerCase().contains(query)) return true;
  if (note.items.any((item) => item.text.toLowerCase().contains(query))) {
    return true;
  }
  return note.labelIds.any(
    (id) => labelsById[id]?.name.toLowerCase().contains(query) ?? false,
  );
}

bool _isInView(Note note, ViewSelection selection, String? currentUserId) =>
    switch (selection.view) {
      NoteView.notes => !note.archived && !note.trashed,
      NoteView.reminders => note.reminderAt != null && !note.trashed,
      NoteView.archive => note.archived && !note.trashed,
      // Collaborators cannot trash notes. If an owner trashes a shared note,
      // it disappears for collaborators instead of entering their trash.
      NoteView.trash => note.trashed && note.isOwnedBy(currentUserId),
      NoteView.label =>
        !note.trashed && note.labelIds.contains(selection.labelId),
    };

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
