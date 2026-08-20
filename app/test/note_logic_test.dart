import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/note_collection.dart';
import 'package:skippy/state/note_conversion.dart';
import 'package:skippy/state/pending_operation.dart';

void main() {
  final created = DateTime(2026, 1, 1);

  Note note(
    String id, {
    String title = '',
    bool pinned = false,
    bool trashed = false,
    DateTime? reminderAt,
    Set<String> labelIds = const {},
    String ownerId = 'me',
  }) => Note(
    id: id,
    title: title,
    pinned: pinned,
    trashed: trashed,
    reminderAt: reminderAt,
    labelIds: labelIds,
    owner: UserRef(id: ownerId, name: ownerId),
    createdAt: created,
    updatedAt: created,
  );

  group('note collection', () {
    test('searches label names and keeps pinned notes grouped', () {
      final result = selectNotes(
        notes: [
          note('pinned', pinned: true, labelIds: {'work'}),
          note('other', title: 'Personal'),
        ],
        labels: const [Label(id: 'work', name: 'Projects')],
        selection: ViewSelection.notes,
        query: 'project',
        sortMode: SortMode.custom,
        currentUserId: 'me',
      );

      expect(result.pinned.map((n) => n.id), ['pinned']);
      expect(result.others, isEmpty);
    });

    test('orders reminders by due date and hides collaborators trash', () {
      final reminders = selectNotes(
        notes: [
          note('later', reminderAt: DateTime(2026, 1, 3)),
          note('sooner', reminderAt: DateTime(2026, 1, 2)),
        ],
        labels: const [],
        selection: ViewSelection.reminders,
        query: '',
        sortMode: SortMode.custom,
        currentUserId: 'me',
      );
      expect(reminders.others.map((n) => n.id), ['sooner', 'later']);

      final trash = selectNotes(
        notes: [
          note('mine', trashed: true),
          note('shared', trashed: true, ownerId: 'someone-else'),
        ],
        labels: const [],
        selection: ViewSelection.trash,
        query: '',
        sortMode: SortMode.custom,
        currentUserId: 'me',
      );
      expect(trash.others.map((n) => n.id), ['mine']);
    });
  });

  test('note conversion preserves markdown task state', () {
    var nextId = 0;
    final source = note('n').copyWith(
      kind: NoteKind.markdown,
      content: '- [x] Milk\n- [ ] Bread\n* Apples',
    );

    final checklist = convertNoteKind(
      source,
      NoteKind.checklist,
      newItemId: () => 'item-${nextId++}',
    );
    expect(checklist.items.map((item) => item.text), [
      'Milk',
      'Bread',
      'Apples',
    ]);
    expect(checklist.items.map((item) => item.done), [true, false, false]);

    final markdown = convertNoteKind(
      checklist,
      NoteKind.markdown,
      newItemId: () => throw StateError('not needed'),
    );
    expect(markdown.content, '- [x] Milk\n- [ ] Bread\n- [ ] Apples');
  });

  test('note conversion carries nesting through the text', () {
    var nextId = 0;
    final list = note('n').copyWith(
      kind: NoteKind.checklist,
      items: const [
        ChecklistItem(id: 'i1', text: 'Trip'),
        ChecklistItem(id: 'i2', text: 'Pack', depth: 1),
        ChecklistItem(id: 'i3', text: 'Socks', depth: 2, done: true),
      ],
    );

    // Indented markdown, which is how a nested list is written anywhere else.
    final markdown = convertNoteKind(
      list,
      NoteKind.markdown,
      newItemId: () => throw StateError('not needed'),
    );
    expect(markdown.content, '- [ ] Trip\n  - [ ] Pack\n    - [x] Socks');

    // And back: the indentation is read as the nesting it was written from.
    final again = convertNoteKind(
      markdown,
      NoteKind.checklist,
      newItemId: () => 'item-${nextId++}',
    );
    expect(
      [for (final item in again.items) '${item.depth}:${item.text}'],
      ['0:Trip', '1:Pack', '2:Socks'],
    );
    expect(again.items.last.done, isTrue);
  });

  test('note conversion leaves no item reminder without an item', () {
    final list = note('n').copyWith(
      kind: NoteKind.checklist,
      items: const [ChecklistItem(id: 'i1', text: 'Milk')],
      itemReminders: {'i1': ItemReminder(itemId: 'i1', at: DateTime(2030))},
    );

    // The rows become prose, so their alarms have nothing left to point at.
    final text = convertNoteKind(
      list,
      NoteKind.text,
      newItemId: () => throw StateError('not needed'),
    );
    expect(text.itemReminders, isEmpty);

    // And rows minted back out of that text are new rows.
    var nextId = 0;
    final again = convertNoteKind(
      text,
      NoteKind.checklist,
      newItemId: () => 'item-${nextId++}',
    );
    expect(again.itemReminders, isEmpty);
  });

  test('pending operations keep the persisted wire format stable', () {
    const operation = PendingOp(
      PendingOpKind.patch,
      id: 'note-1',
      data: {'title': 'Updated'},
    );

    expect(PendingOp.fromJson(operation.toJson()).kind, PendingOpKind.patch);
    expect(
      PendingOp.fromJson({'kind': 'future-op'}).kind,
      PendingOpKind.unknown,
    );
  });
}
