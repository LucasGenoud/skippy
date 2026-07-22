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
