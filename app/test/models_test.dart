import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';

void main() {
  test('Note.fromJson parses the full server shape', () {
    final note = Note.fromJson({
      'id': 'n1',
      'kind': 'checklist',
      'title': 'Groceries',
      'content': '',
      'items': [
        {'id': 'i1', 'text': 'Milk', 'done': true},
        {'id': 'i2', 'text': 'Eggs', 'done': false},
      ],
      'color': 'teal',
      'pinned': true,
      'archived': false,
      'trashed': false,
      'position': 2048.0,
      'reminder_at': '2030-05-01T07:00:00+00:00',
      'created_at': '2026-07-01T10:00:00+00:00',
      'updated_at': '2026-07-02T10:00:00+00:00',
      'label_ids': ['l1'],
      'owner': {'id': 'u1', 'name': 'ada'},
      'collaborators': [
        {'id': 'u2', 'name': 'bob'},
      ],
      'attachments': [
        {'id': 'a1', 'mime': 'image/png'},
      ],
    });

    expect(note.isChecklist, isTrue);
    expect(note.items, hasLength(2));
    expect(note.items.first.done, isTrue);
    expect(note.color, 'teal');
    expect(note.pinned, isTrue);
    expect(note.reminderAt, isNotNull);
    // RFC3339 UTC converts to local without losing the instant.
    expect(note.reminderAt!.toUtc(), DateTime.utc(2030, 5, 1, 7));
    expect(note.labelIds, {'l1'});
    expect(note.owner!.name, 'ada');
    expect(note.collaborators.single.name, 'bob');
    expect(note.attachments.single.mime, 'image/png');
    expect(note.isShared, isTrue);
    expect(note.isOwnedBy('u1'), isTrue);
    expect(note.isOwnedBy('u2'), isFalse);
  });

  test('missing optional fields fall back to sane defaults', () {
    final note = Note.fromJson({
      'id': 'n1',
      'created_at': '2026-07-01T10:00:00+00:00',
      'updated_at': '2026-07-01T10:00:00+00:00',
    });
    expect(note.kind, NoteKind.text);
    expect(note.items, isEmpty);
    expect(note.color, 'default');
    expect(note.reminderAt, isNull);
    expect(note.collaborators, isEmpty);
    expect(note.owner, isNull);
    expect(note.isOwnedBy('anyone'), isTrue); // ownerless = mine
  });

  test('auto-discard distinguishes content from reminder and sharing', () {
    final now = DateTime.now();
    Note base({
      String title = '',
      String content = '',
      List<ChecklistItem> items = const [],
      List<Attachment> attachments = const [],
      DateTime? reminderAt,
      List<UserRef> collaborators = const [],
    }) => Note(
      id: 'n',
      title: title,
      content: content,
      items: items,
      attachments: attachments,
      reminderAt: reminderAt,
      collaborators: collaborators,
      createdAt: now,
      updatedAt: now,
    );

    expect(base().isEmpty, isTrue);
    expect(base(title: '  ').isEmpty, isTrue);
    expect(base(title: 'x').isEmpty, isFalse);
    expect(base(content: 'x').isEmpty, isFalse);
    expect(
      base(
        items: [const ChecklistItem(id: 'i', text: '  ')],
      ).isEmpty,
      isTrue,
    );
    expect(
      base(
        items: [const ChecklistItem(id: 'i', text: 'x')],
      ).isEmpty,
      isFalse,
    );
    expect(
      base(
        attachments: [const Attachment(id: 'a', mime: 'image/png')],
      ).isEmpty,
      isFalse,
    );
    expect(base().canAutoDiscard, isTrue);

    // These notes are still empty, so their cards can say so and content-only
    // actions stay disabled. They must nevertheless survive editor close.
    final reminded = base(reminderAt: DateTime(2030));
    expect(reminded.isEmpty, isTrue);
    expect(reminded.canAutoDiscard, isFalse);
    final shared = base(
      collaborators: [const UserRef(id: 'u2', name: 'Ada')],
    );
    expect(shared.isEmpty, isTrue);
    expect(shared.canAutoDiscard, isFalse);
  });

  test('copyWith reminder sentinel distinguishes clear from keep', () {
    final now = DateTime.now();
    final note = Note(
      id: 'n',
      reminderAt: DateTime(2030),
      createdAt: now,
      updatedAt: now,
    );
    expect(note.copyWith(title: 'x').reminderAt, DateTime(2030)); // untouched
    expect(note.copyWith(reminderAt: null).reminderAt, isNull); // cleared
    expect(
      note.copyWith(reminderAt: DateTime(2031)).reminderAt,
      DateTime(2031),
    );
  });

  test('checklist items round-trip through json', () {
    const item = ChecklistItem(id: 'i1', text: 'Milk', done: true);
    expect(ChecklistItem.fromJson(item.toJson()), item);
  });
}
