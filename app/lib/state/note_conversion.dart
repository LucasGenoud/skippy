import '../models/note.dart';

/// Title a duplicate carries, so the copy is never mistaken for the original
/// in the grid, in search results, or on a home-screen widget. The marker
/// trails the title so notes stay sorted and scanned by their own names; an
/// untitled note's copy is titled "(copy)" rather than left blank, since the
/// title is the only place the difference can show.
String copyTitle(String title) => '$title (copy)'.trim();

/// Converts a note's content between text, markdown, and checklist forms.
///
/// The caller supplies [newItemId], keeping UUID generation out of this pure
/// transformation and making the conversion rules independently testable.
Note convertNoteKind(
  Note note,
  NoteKind target, {
  required String Function() newItemId,
}) {
  if (note.kind == target) return note;

  if (target == NoteKind.checklist) {
    return note.copyWith(
      kind: target,
      content: '',
      items: _itemsFromText(note.content, newItemId),
      // Rows minted from text are new rows, so nothing that was scheduled
      // before the conversion has anything left to point at.
      itemReminders: const {},
    );
  }

  if (note.isChecklist) {
    final itemText = _textFromItems(
      note.items,
      markdown: target == NoteKind.markdown,
    );
    final content = note.content.trim().isEmpty
        ? itemText
        : '${note.content}\n$itemText';
    // The rows become prose; their reminders go with them, which is what the
    // server does with the same patch.
    return note.copyWith(
      kind: target,
      content: content,
      items: [],
      itemReminders: const {},
    );
  }

  // Text and markdown share the same content representation.
  return note.copyWith(kind: target);
}

List<ChecklistItem> _itemsFromText(
  String content,
  String Function() newItemId,
) {
  final items = <ChecklistItem>[];
  for (final rawLine in content.split('\n')) {
    var line = rawLine.trim();
    if (line.isEmpty) continue;

    var done = false;
    final task = RegExp(r'^[-*+]\s+\[( |x|X)\]\s*').firstMatch(line);
    if (task != null) {
      done = task.group(1)!.toLowerCase() == 'x';
      line = line.substring(task.end).trim();
    } else {
      line = line.replaceFirst(RegExp(r'^[-*+]\s+'), '');
    }
    if (line.isEmpty) continue;
    items.add(ChecklistItem(id: newItemId(), text: line, done: done));
  }
  return items;
}

String _textFromItems(List<ChecklistItem> items, {required bool markdown}) => [
  for (final item in items)
    if (item.text.trim().isNotEmpty)
      markdown ? '- [${item.done ? 'x' : ' '}] ${item.text}' : item.text,
].join('\n');
