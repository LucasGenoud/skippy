import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/util/backup.dart';

import 'fake_api.dart';

void main() {
  final created = DateTime.utc(2020, 1, 2, 3, 4, 5);
  final updated = DateTime.utc(2021, 6, 7, 8, 9, 10);

  test('zip backup round-trips notes, labels, and attachment bytes', () async {
    final note = Note(
      id: 'note-old',
      kind: NoteKind.checklist,
      title: 'Packing',
      items: const [
        ChecklistItem(id: 'item-old', text: 'Passport', done: true),
      ],
      color: 'teal',
      pinned: true,
      archived: true,
      reminderAt: DateTime.utc(2027, 1, 1),
      createdAt: created,
      updatedAt: updated,
      labelIds: const {'label-old'},
      attachments: const [
        Attachment(
          id: 'attachment-old',
          mime: 'application/pdf',
          filename: '../ticket.pdf',
          size: 3,
        ),
      ],
    );
    final bytes = await createBackupArchive(
      notes: [note],
      labels: const [
        Label(
          id: 'label-old',
          name: 'Travel',
          color: '#123456',
          icon: 'flight',
        ),
      ],
      readAttachment: (_) async => Uint8List.fromList([1, 2, 3]),
      now: DateTime.utc(2026, 7, 22),
    );

    final restored = parseBackupArchive(bytes);
    expect(restored.labels.single.name, 'Travel');
    expect(restored.labels.single.color, '#123456');
    expect(restored.notes.single.title, 'Packing');
    expect(restored.notes.single.kind, NoteKind.checklist);
    expect(restored.notes.single.items.single.text, 'Passport');
    expect(restored.notes.single.items.single.done, isTrue);
    expect(restored.notes.single.archived, isTrue);
    expect(restored.notes.single.labelIds, ['label-old']);
    expect(restored.notes.single.attachments.single.filename, '../ticket.pdf');
    expect(restored.notes.single.attachments.single.bytes, [1, 2, 3]);
    expect(
      backupFilename(DateTime.utc(2026, 7, 22)),
      'skippy-backup-2026-07-22.zip',
    );
  });

  test('invalid archives are rejected before restore', () {
    expect(
      () => parseBackupArchive(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<FormatException>()),
    );
  });

  test('restore is additive, reuses labels, and uploads files', () async {
    final api = FakeApi();
    api.labels['existing'] = const Label(id: 'existing', name: 'Travel');
    final store = NotesStore(api: api, currentUserId: 'u-me');
    addTearDown(store.dispose);
    await store.load();

    final backup = BackupBundle(
      labels: const [
        BackupLabel(id: 'old-travel', name: 'travel'),
        BackupLabel(id: 'old-work', name: 'Work', color: '#654321'),
      ],
      notes: [
        BackupNote(
          id: 'old-note',
          kind: NoteKind.markdown,
          title: 'Imported',
          content: '**kept**',
          items: const [],
          color: 'blue',
          pinned: true,
          archived: true,
          reminderAt: DateTime.utc(2027, 2, 3),
          createdAt: created,
          updatedAt: updated,
          labelIds: const ['old-travel', 'old-work'],
          attachments: [
            BackupAttachment(
              filename: 'doc.txt',
              mime: 'text/plain',
              bytes: Uint8List.fromList([4, 5, 6]),
            ),
          ],
        ),
      ],
    );
    var progress = (done: 0, total: 0);
    final result = await store.restoreBackup(
      backup,
      onProgress: (done, total) => progress = (done: done, total: total),
    );

    expect(result.notes, 1);
    expect(result.skippedNotes, 0);
    expect(result.attachments, 1);
    expect(result.labelsCreated, 1);
    expect(result.labelsReused, 1);
    expect(progress, (done: 4, total: 4));
    expect(api.notes, hasLength(1));
    final note = api.notes.values.single;
    expect(note.id, 'old-note');
    expect(note.title, 'Imported');
    expect(note.archived, isTrue);
    expect(note.pinned, isTrue);
    expect(note.createdAt, created);
    expect(note.updatedAt, updated);
    expect(note.labelIds, hasLength(2));
    expect(note.attachments.single.filename, 'doc.txt');
    expect(
      store.labels.map((label) => label.name),
      containsAll(['Travel', 'Work']),
    );

    final uploadCount = api.log
        .where((entry) => entry.startsWith('upload:'))
        .length;
    final repeated = await store.restoreBackup(backup);
    expect(repeated.notes, 0);
    expect(repeated.skippedNotes, 1);
    expect(repeated.attachments, 0);
    expect(api.notes, hasLength(1));
    expect(
      api.log.where((entry) => entry.startsWith('upload:')),
      hasLength(uploadCount),
    );
  });
}
