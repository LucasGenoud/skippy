import '../models/note.dart';

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
    return note.copyWith(kind: target, content: content, items: []);
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
