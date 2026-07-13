import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sticky_notes/models/note.dart';
import 'package:sticky_notes/util/note_export.dart';

void main() {
  final now = DateTime.utc(2026, 7, 13, 9, 30);
  final base = DateTime.utc(2026, 1, 1);

  final textNote = Note(
    id: 'n1',
    title: 'Trip ideas',
    content: 'Kyoto in autumn\nLisbon',
    color: 'teal',
    pinned: true,
    labelIds: {'l1'},
    createdAt: base,
    updatedAt: base,
  );
  final checklist = Note(
    id: 'n2',
    kind: NoteKind.checklist,
    title: 'Groceries',
    items: const [
      ChecklistItem(id: 'i1', text: 'Milk', done: true),
      ChecklistItem(id: 'i2', text: 'Eggs'),
    ],
    createdAt: base,
    updatedAt: base,
  );
  final labels = const [Label(id: 'l1', name: 'travel')];

  test('filename is timestamped with the right extension', () {
    expect(
      exportFilename(ExportFormat.markdown, now),
      'sticky-notes-2026-07-13.md',
    );
    expect(exportFilename(ExportFormat.json, now), 'sticky-notes-2026-07-13.json');
  });

  test('JSON export round-trips content, items, and label names', () {
    final raw = exportNotes(
      [textNote, checklist],
      ExportFormat.json,
      labels: labels,
      now: now,
    );
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['version'], 1);
    expect(decoded['exported_at'], '2026-07-13T09:30:00.000Z');
    final notes = decoded['notes'] as List;
    expect(notes, hasLength(2));

    final first = notes[0] as Map<String, dynamic>;
    expect(first['title'], 'Trip ideas');
    expect(first['content'], 'Kyoto in autumn\nLisbon');
    expect(first['pinned'], true);
    expect(first['labels'], ['travel']);

    final second = notes[1] as Map<String, dynamic>;
    expect(second['kind'], 'checklist');
    expect(second['items'], [
      {'text': 'Milk', 'done': true},
      {'text': 'Eggs', 'done': false},
    ]);
  });

  test('Markdown renders checkboxes and labels', () {
    final md = exportNotes(
      [textNote, checklist],
      ExportFormat.markdown,
      labels: labels,
      now: now,
    );
    expect(md, contains('# Sticky Notes export'));
    expect(md, contains('_Exported 2026-07-13 · 2 notes_'));
    expect(md, contains('## Trip ideas'));
    expect(md, contains('`travel`'));
    expect(md, contains('- [x] Milk'));
    expect(md, contains('- [ ] Eggs'));
  });

  test('Plain text drops markup but keeps structure', () {
    final txt = exportNotes(
      [textNote, checklist],
      ExportFormat.text,
      labels: labels,
      now: now,
    );
    expect(txt, contains('Trip ideas'));
    expect(txt, contains('Labels: travel'));
    expect(txt, contains('[x] Milk'));
    expect(txt, contains('[ ] Eggs'));
    expect(txt, isNot(contains('# ')));
    // Notes are divided by a rule.
    expect(txt, contains('—' * 40));
  });

  test('empty note list still produces a valid document', () {
    final json = exportNotes([], ExportFormat.json, now: now);
    expect((jsonDecode(json) as Map)['notes'], isEmpty);
    expect(exportNotes([], ExportFormat.text), '\n');
  });
}
