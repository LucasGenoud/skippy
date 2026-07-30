import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/models/workspace.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/util/backup.dart';

import 'fake_api.dart';

void main() {
  final created = DateTime.utc(2020, 1, 2, 3, 4, 5);
  final updated = DateTime.utc(2021, 6, 7, 8, 9, 10);

  test(
    'zip backup round-trips owned workspace data and attachment bytes',
    () async {
      final note = Note(
        id: 'note-old',
        workspaceId: 'w-travel',
        kind: NoteKind.checklist,
        title: 'Packing',
        items: const [
          ChecklistItem(id: 'item-old', text: 'Passport', done: true),
        ],
        color: 'teal',
        pinned: true,
        archived: true,
        trashed: true,
        position: 42,
        stageId: 'stage-old',
        stagePosition: 84,
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
        workspaces: const [
          Workspace(id: 'w-default', name: 'My notes', isDefault: true),
          Workspace(id: 'w-travel', name: 'Travel', notesEnabled: false),
        ],
        notes: [note],
        labels: const [
          Label(
            id: 'label-old',
            workspaceId: 'w-travel',
            name: 'Travel',
            color: '#123456',
            icon: 'flight',
            position: 12,
          ),
        ],
        stages: const [
          Stage(
            id: 'stage-old',
            workspaceId: 'w-travel',
            name: 'Ready',
            color: '#abcdef',
            position: 24,
          ),
        ],
        readAttachment: (_) async => Uint8List.fromList([1, 2, 3]),
        now: DateTime.utc(2026, 7, 22),
      );

      final restored = parseBackupArchive(bytes);
      expect(restored.workspaces.map((workspace) => workspace.name), [
        'My notes',
        'Travel',
      ]);
      final travel = restored.workspaces.last;
      expect(travel.notesEnabled, isFalse);
      expect(travel.boardEnabled, isTrue);
      expect(travel.labels.single.name, 'Travel');
      expect(travel.labels.single.position, 12);
      expect(travel.stages.single.name, 'Ready');
      expect(travel.stages.single.position, 24);
      expect(travel.notes.single.title, 'Packing');
      expect(travel.notes.single.kind, NoteKind.checklist);
      expect(travel.notes.single.items.single.id, 'item-old');
      expect(travel.notes.single.items.single.text, 'Passport');
      expect(travel.notes.single.items.single.done, isTrue);
      expect(travel.notes.single.archived, isTrue);
      expect(travel.notes.single.trashed, isTrue);
      expect(travel.notes.single.position, 42);
      expect(travel.notes.single.stageId, 'stage-old');
      expect(travel.notes.single.stagePosition, 84);
      expect(travel.notes.single.labelIds, ['label-old']);
      expect(travel.notes.single.attachments.single.filename, '../ticket.pdf');
      expect(travel.notes.single.attachments.single.bytes, [1, 2, 3]);
      expect(
        backupFilename(DateTime.utc(2026, 7, 22)),
        'skippy-backup-2026-07-22.zip',
      );
    },
  );

  test('invalid archives are rejected before restore', () {
    expect(
      () => parseBackupArchive(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'restore replaces owned workspaces and leaves invited workspaces alone',
    () async {
      final api = FakeApi();
      api.workspaces['w-old'] = const Workspace(
        id: 'w-old',
        name: 'Old project',
        owner: UserRef(id: 'u-me', name: 'Me'),
      );
      api.workspaces['w-invited'] = const Workspace(
        id: 'w-invited',
        name: 'Shared with me',
        owner: UserRef(id: 'u-other', name: 'Other'),
      );
      api.notes['old-default'] = Note(
        id: 'old-default',
        workspaceId: 'w-default',
        title: 'Delete me',
        createdAt: created,
        updatedAt: updated,
        owner: const UserRef(id: 'u-me', name: 'Me'),
      );
      api.notes['old-project'] = Note(
        id: 'old-project',
        workspaceId: 'w-old',
        title: 'Delete me too',
        createdAt: created,
        updatedAt: updated,
        owner: const UserRef(id: 'u-me', name: 'Me'),
      );
      api.notes['invited-note'] = Note(
        id: 'invited-note',
        workspaceId: 'w-invited',
        title: 'Keep me',
        createdAt: created,
        updatedAt: updated,
        owner: const UserRef(id: 'u-other', name: 'Other'),
      );
      api.labels['old-label'] = const Label(
        id: 'old-label',
        workspaceId: 'w-default',
        name: 'Old',
      );
      api.stages['old-stage'] = const Stage(
        id: 'old-stage',
        workspaceId: 'w-default',
        name: 'Old',
      );
      final store = NotesStore(api: api, currentUserId: 'u-me');
      addTearDown(store.dispose);
      await store.load();
      expect(
        store.ownedWorkspaces.map((workspace) => workspace.id),
        containsAll(['w-default', 'w-old']),
      );
      expect(
        store.ownedWorkspaces.map((workspace) => workspace.id),
        isNot(contains('w-invited')),
      );
      expect(
        store.notesForBackup.map((note) => note.id),
        containsAll(['old-default', 'old-project']),
      );
      expect(
        store.notesForBackup.map((note) => note.id),
        isNot(contains('invited-note')),
      );

      final backup = BackupBundle(
        workspaces: [
          BackupWorkspace(
            id: 'backup-default',
            name: 'Restored home',
            isDefault: true,
            labels: const [
              BackupLabel(id: 'old-travel', name: 'Travel', position: 10),
            ],
            stages: const [
              BackupStage(id: 'old-ready', name: 'Ready', position: 20),
            ],
            notes: [
              BackupNote(
                id: 'backup-home-note',
                kind: NoteKind.text,
                title: 'Home',
                content: 'Restored',
                items: const [],
                color: 'blue',
                pinned: false,
                archived: false,
                position: 30,
                stageId: 'old-ready',
                stagePosition: 40,
                reminderAt: null,
                createdAt: created,
                updatedAt: updated,
                labelIds: const ['old-travel'],
                attachments: const [],
              ),
            ],
          ),
          BackupWorkspace(
            id: 'backup-project',
            name: 'New project',
            isDefault: false,
            boardEnabled: false,
            labels: const [],
            stages: const [],
            notes: [
              BackupNote(
                id: 'backup-project-note',
                kind: NoteKind.markdown,
                title: 'Imported',
                content: '**kept**',
                items: const [],
                color: 'green',
                pinned: true,
                archived: true,
                trashed: true,
                reminderAt: DateTime.utc(2027, 2, 3),
                createdAt: created,
                updatedAt: updated,
                labelIds: const [],
                attachments: [
                  BackupAttachment(
                    filename: 'doc.txt',
                    mime: 'text/plain',
                    bytes: Uint8List.fromList([4, 5, 6]),
                  ),
                ],
              ),
            ],
          ),
          const BackupWorkspace(
            id: 'backup-skipped',
            name: 'Do not restore',
            isDefault: false,
            labels: [],
            stages: [],
            notes: [],
          ),
        ],
      );
      var progress = (done: 0, total: 0);
      final result = await store.restoreBackup(
        backup,
        workspaceIds: const {'backup-default', 'backup-project'},
        onProgress: (done, total) => progress = (done: done, total: total),
      );

      expect(result.workspaces, 2);
      expect(result.notes, 2);
      expect(result.attachments, 1);
      expect(result.labels, 1);
      expect(result.stages, 1);
      expect(progress.done, progress.total);
      expect(
        api.workspaces.values.map((workspace) => workspace.name),
        containsAll(['Restored home', 'New project', 'Shared with me']),
      );
      expect(
        api.workspaces.values.map((workspace) => workspace.name),
        isNot(contains('Old project')),
      );
      expect(
        api.workspaces.values.map((workspace) => workspace.name),
        isNot(contains('Do not restore')),
      );
      expect(
        api.workspaces.values
            .singleWhere((workspace) => workspace.name == 'New project')
            .boardEnabled,
        isFalse,
      );
      expect(api.notes, isNot(contains('old-default')));
      expect(api.notes, isNot(contains('old-project')));
      expect(api.notes['invited-note']?.title, 'Keep me');
      expect(
        api.notes.values.map((note) => note.title),
        containsAll(['Home', 'Imported', 'Keep me']),
      );
      final restoredHome = api.notes.values.singleWhere(
        (note) => note.title == 'Home',
      );
      expect(restoredHome.labelIds, hasLength(1));
      expect(restoredHome.stageId, isNotNull);
      final restoredProject = api.notes.values.singleWhere(
        (note) => note.title == 'Imported',
      );
      expect(restoredProject.trashed, isTrue);
      expect(restoredProject.attachments.single.filename, 'doc.txt');
    },
  );
}
