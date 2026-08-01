import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/util/widget_payload.dart';

void main() {
  final base = DateTime.utc(2026, 1, 1);

  Note note(
    String id, {
    String title = '',
    String content = '',
    List<ChecklistItem> items = const [],
    NoteKind kind = NoteKind.text,
    String color = 'default',
    bool trashed = false,
    bool archived = false,
    DateTime? updatedAt,
  }) => Note(
    id: id,
    title: title,
    content: content,
    items: items,
    kind: kind,
    color: color,
    trashed: trashed,
    archived: archived,
    createdAt: base,
    updatedAt: updatedAt ?? base,
  );

  ChecklistItem item(String id, String text, {bool done = false}) =>
      ChecklistItem(id: id, text: text, done: done);

  WidgetNoteColors noColors(String key) => (light: null, dark: null);

  Map<String, dynamic> notesOf(Map<String, dynamic> doc) =>
      doc['notes'] as Map<String, dynamic>;

  group('widgetDisplayTitle', () {
    test('prefers the title', () {
      expect(widgetDisplayTitle(note('a', title: ' Groceries ')), 'Groceries');
    });

    test('falls back to the first non-blank content line, then an item', () {
      expect(
        widgetDisplayTitle(note('a', content: '\n\n  hello\nworld')),
        'hello',
      );
      expect(
        widgetDisplayTitle(note('a', items: [item('i', 'Milk')])),
        'Milk',
      );
    });

    test('names an empty note rather than returning a blank header', () {
      expect(widgetDisplayTitle(note('a')), 'Untitled note');
    });
  });

  group('orderedWidgetItems', () {
    test('puts pending first, keeping each group in its original order', () {
      final ordered = orderedWidgetItems([
        item('1', 'a', done: true),
        item('2', 'b'),
        item('3', 'c', done: true),
        item('4', 'd'),
      ]);
      expect(ordered.map((i) => i.id).toList(), ['2', '4', '1', '3']);
    });
  });

  group('buildWidgetNote', () {
    test('caps items but reports the note-wide totals', () {
      final n = note(
        'a',
        kind: NoteKind.checklist,
        items: [
          for (var i = 0; i < 10; i++) item('i$i', 'item $i', done: i.isEven),
        ],
      );
      final payload = buildWidgetNote(n, resolveColor: noColors, maxItems: 3);

      expect((payload['items'] as List), hasLength(3));
      // Totals describe the whole note, so "+N more" can be honest past the cap.
      expect(payload['itemCount'], 10);
      expect(payload['pendingCount'], 5);
      // The three published items are pending ones, never completed.
      for (final published in payload['items'] as List) {
        expect((published as Map)['done'], isFalse);
      }
    });

    test('publishes resolved colours only for a coloured note', () {
      final plain = buildWidgetNote(note('a'), resolveColor: noColors);
      expect(plain.containsKey('colorLight'), isFalse);
      expect(plain.containsKey('colorDark'), isFalse);

      final coloured = buildWidgetNote(
        note('b', color: 'amber'),
        resolveColor: (key) =>
            key == 'amber' ? (light: '#FFF6C344', dark: '#FF3A3226') : noColors(key),
      );
      expect(coloured['colorLight'], '#FFF6C344');
      expect(coloured['colorDark'], '#FF3A3226');
    });

    test('truncates long body text', () {
      final long = 'x' * (kWidgetContentChars + 50);
      final payload = buildWidgetNote(note('a', content: long), resolveColor: noColors);
      expect((payload['content'] as String).length, kWidgetContentChars + 1);
      expect(payload['content'], endsWith('…'));
    });
  });

  group('buildWidgetNotesDoc', () {
    test('excludes trashed notes but keeps archived ones', () {
      final doc = buildWidgetNotesDoc(
        [
          note('live'),
          note('binned', trashed: true),
          note('filed', archived: true),
        ],
        resolveColor: noColors,
      );
      expect(notesOf(doc).keys, containsAll(['live', 'filed']));
      expect(notesOf(doc).containsKey('binned'), isFalse);
    });

    test('keeps the most recently updated notes when over the cap', () {
      final doc = buildWidgetNotesDoc(
        [
          note('old', updatedAt: DateTime.utc(2026, 1, 1)),
          note('new', updatedAt: DateTime.utc(2026, 6, 1)),
          note('mid', updatedAt: DateTime.utc(2026, 3, 1)),
        ],
        resolveColor: noColors,
        maxNotes: 2,
      );
      expect(notesOf(doc).keys.toList(), ['new', 'mid']);
    });

    test('publishes a note past the cap when a widget still wants it', () {
      final doc = buildWidgetNotesDoc(
        [
          note('old', updatedAt: DateTime.utc(2020, 1, 1)),
          note('new', updatedAt: DateTime.utc(2026, 6, 1)),
        ],
        resolveColor: noColors,
        maxNotes: 1,
        keep: {'old'},
      );
      expect(notesOf(doc).keys, containsAll(['new', 'old']));
    });

    test('a trashed note is dropped even when a widget wants it', () {
      final doc = buildWidgetNotesDoc(
        [note('gone', trashed: true)],
        resolveColor: noColors,
        keep: {'gone'},
      );
      expect(notesOf(doc), isEmpty);
    });

    test('carries a version so a widget can tell an incompatible payload', () {
      final doc = buildWidgetNotesDoc(const [], resolveColor: noColors);
      expect(doc['version'], kWidgetPayloadVersion);
    });
  });

  group('buildWidgetIndex', () {
    test('lists pickable notes newest first with their counts', () {
      final index = buildWidgetIndex([
        note('a', title: 'Old', updatedAt: DateTime.utc(2026, 1, 1)),
        note(
          'b',
          title: 'New',
          kind: NoteKind.checklist,
          items: [item('1', 'x', done: true), item('2', 'y')],
          updatedAt: DateTime.utc(2026, 6, 1),
        ),
      ]);
      expect(index.map((e) => e['id']).toList(), ['b', 'a']);
      expect(index.first['title'], 'New');
      expect(index.first['kind'], 'checklist');
      expect(index.first['itemCount'], 2);
      expect(index.first['pendingCount'], 1);
    });
  });

  group('parseWidgetOps', () {
    test('reads well-formed ops oldest first', () {
      final ops = parseWidgetOps([
        {
          'noteId': 'n1',
          'itemId': 'i1',
          'done': true,
          'at': '2026-07-31T10:00:00Z',
        },
        {
          'noteId': 'n1',
          'itemId': 'i1',
          'done': false,
          'at': '2026-07-31T09:00:00Z',
        },
      ]);
      expect(ops, hasLength(2));
      // Replaying out of order would land on the wrong value.
      expect(ops.first.done, isFalse);
      expect(ops.last.done, isTrue);
      expect(ops.first.noteId, 'n1');
    });

    test('drops malformed entries without losing the good ones', () {
      final ops = parseWidgetOps([
        {'noteId': 'n1', 'itemId': 'i1', 'done': true},
        {'noteId': 'n1', 'itemId': 'i2'}, // no done
        {'noteId': '', 'itemId': 'i3', 'done': true}, // empty id
        {'noteId': 'n2', 'itemId': 'i4', 'done': 'yes'}, // wrong type
        'nonsense',
      ]);
      expect(ops, hasLength(1));
      expect(ops.single.itemId, 'i1');
      expect(ops.single.at, isNull);
    });

    test('tolerates a missing or wrongly-typed queue', () {
      expect(parseWidgetOps(null), isEmpty);
      expect(parseWidgetOps('[]'), isEmpty);
      expect(parseWidgetOps(const {}), isEmpty);
    });
  });

  group('parseWantedIds', () {
    test('keeps non-empty strings only', () {
      expect(parseWantedIds(['a', '', 3, null, 'b']), ['a', 'b']);
      expect(parseWantedIds(null), isEmpty);
    });
  });
}
