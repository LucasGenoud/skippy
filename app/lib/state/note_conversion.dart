import '../models/note.dart';
import 'checklist_tree.dart';

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

/// Spaces one nesting level is written with, the usual markdown convention
/// for a nested list, so a converted note reads as a nested list anywhere else
/// too.
const int _indentWidth = 2;

List<ChecklistItem> _itemsFromText(
  String content,
  String Function() newItemId,
) {
  final items = <ChecklistItem>[];
  for (final rawLine in content.split('\n')) {
    if (rawLine.trim().isEmpty) continue;
    // Leading whitespace is the nesting, before it is trimmed away: a tab
    // counts as one level, spaces as one per [_indentWidth] of them.
    final indent = RegExp(r'^[ \t]*').firstMatch(rawLine)!.group(0)!;
    final tabs = indent.split('\t').length - 1;
    final spaces = indent.replaceAll('\t', '').length;
    final depth = tabs + spaces ~/ _indentWidth;
    var line = rawLine.trim();

    var done = false;
    final task = RegExp(r'^[-*+]\s+\[( |x|X)\]\s*').firstMatch(line);
    if (task != null) {
      done = task.group(1)!.toLowerCase() == 'x';
      line = line.substring(task.end).trim();
    } else {
      line = line.replaceFirst(RegExp(r'^[-*+]\s+'), '');
    }
    if (line.isEmpty) continue;
    items.add(
      ChecklistItem(
        id: newItemId(),
        text: line,
        done: done,
        depth: depth > kMaxItemDepth ? kMaxItemDepth : depth,
      ),
    );
  }
  // Text can indent anything by any amount; a checklist cannot.
  return normalizeDepths(items);
}

String _textFromItems(List<ChecklistItem> items, {required bool markdown}) => [
  for (final item in items)
    if (item.text.trim().isNotEmpty)
      '${' ' * (item.depth * _indentWidth)}'
          '${markdown ? '- [${item.done ? 'x' : ' '}] ' : ''}${item.text}',
].join('\n');
