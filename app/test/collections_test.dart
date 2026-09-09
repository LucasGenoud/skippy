import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/collection.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/models/saved_view.dart';
import 'package:skippy/models/workspace.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/state/local_cache.dart';
import 'package:skippy/state/pending_operation.dart';
import 'package:skippy/state/pending_operation_executor.dart';
import 'package:skippy/util/backup.dart';
import 'fake_api.dart';

void main() {
  test(
    'collections compose with labels and smart scopes, survive refresh',
    () async {
      final api = FakeApi();
      final store = NotesStore(api: api, currentUserId: 'u-me');
      addTearDown(store.dispose);
      await store.load();
      final recipes = store.createCollection('Recipes', 'masonry');
      final project = store.createCollection('Project', 'board');
      store.selectCollection(recipes.id);
      final label = store.createLabel('Urgent');
      final note = store.createDraft(labelIds: {label.id});
      store.updateNoteContent(note.id, title: 'Soup');
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(
        store
            .notesFor(ViewSelection.collection(recipes.id), '')
            .others
            .single
            .id,
        note.id,
      );
      expect(
        store.notesFor(ViewSelection.collection(project.id), '').isEmpty,
        isTrue,
      );
      final smart = store.addSavedView(
        name: 'Recipe priorities',
        query: 'label:Urgent',
        collectionIds: [recipes.id],
      );
      expect(
        store
            .notesFor(ViewSelection.smart(smart.id), smart.query)
            .others
            .single
            .id,
        note.id,
      );
      store.moveToCollection(note.id, project.id);
      expect(store.noteById(note.id)!.labelIds, {label.id});
      expect(
        store.notesFor(ViewSelection.smart(smart.id), smart.query).isEmpty,
        isTrue,
      );
      expect(
        store
            .notesFor(ViewSelection(NoteView.label, label.id), '')
            .others
            .single
            .id,
        note.id,
      );
      store.selectCollection(project.id);
      final stage = store.createStage('Doing');
      store.setNoteStage(note.id, stage.id);
      await Future<void>.delayed(const Duration(milliseconds: 650));
      await store.refresh();
      expect(store.noteById(note.id)!.collectionId, project.id);
      expect(store.stages.single.collectionId, project.id);
      expect(store.collectionById(project.id)!.layout, 'board');
      store.deleteCollection(project.id);
      expect(store.noteById(note.id)!.collectionId, 'inbox');
      expect(store.noteById(note.id)!.stageId, isNull);
      expect(store.noteById(note.id)!.labelIds, {label.id});
    },
  );

  test(
    'offline collections and notes restore and sync in dependency order',
    () async {
      final api = FakeApi();
      final cache = MemoryLocalCache();
      var store = NotesStore(api: api, currentUserId: 'u-me', cache: cache);
      await store.load();
      api.failWith = Exception('offline');
      final collection = store.createCollection('Offline project', 'board');
      store.selectCollection(collection.id);
      final note = store.createDraft();
      store.updateNoteContent(note.id, title: 'Offline note');
      await Future<void>.delayed(const Duration(milliseconds: 650));
      store.dispose();
      store = NotesStore(api: api, currentUserId: 'u-me', cache: cache);
      addTearDown(store.dispose);
      await store.load();
      expect(store.collectionById(collection.id)!.layout, 'board');
      expect(store.noteById(note.id)!.collectionId, collection.id);
      api.failWith = null;
      await store.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(
        api.workspaces['w-default']!.collections.any(
          (c) => c.id == collection.id,
        ),
        isTrue,
      );
      expect(api.notes[note.id]!.collectionId, collection.id);
    },
  );

  test(
    'queued create retains its original scope before a later move',
    () async {
      final api = FakeApi();
      final now = DateTime.now();
      final note = Note(
        id: 'n',
        workspaceId: 'w-default',
        collectionId: 'future',
        createdAt: now,
        updatedAt: now,
      );
      final executor = PendingOperationExecutor(
        api: api,
        noteById: (_) => note,
      );
      await executor.run(
        const PendingOp(
          PendingOpKind.create,
          id: 'n',
          data: {
            'workspace_id': 'w-default',
            'collection_id': 'inbox',
            'stage_id': null,
          },
        ),
      );
      expect(api.notes['n']!.collectionId, 'inbox');
    },
  );

  test(
    'backup restores collections, layouts, stages and smart scopes',
    () async {
      final now = DateTime.now();
      final archive = await createBackupArchive(
        workspaces: const [
          Workspace(
            id: 'w',
            name: 'Personal',
            isDefault: true,
            collections: [
              NoteCollection.inbox,
              NoteCollection(id: 'project', name: 'Project', layout: 'board'),
            ],
            savedViews: [
              SavedView(
                id: 'v',
                name: 'Project notes',
                query: 'has:title',
                collectionIds: ['project'],
              ),
            ],
          ),
        ],
        notes: [
          Note(
            id: 'n',
            workspaceId: 'w',
            collectionId: 'project',
            stageId: 's',
            title: 'Work',
            createdAt: now,
            updatedAt: now,
          ),
        ],
        labels: [],
        stages: const [
          Stage(
            id: 's',
            workspaceId: 'w',
            collectionId: 'project',
            name: 'Doing',
          ),
        ],
        readAttachment: (_) => throw StateError('no files'),
      );
      final backup = parseBackupArchive(archive);
      expect(backup.workspaces.single.collections.last.layout, 'board');
      expect(backup.workspaces.single.savedViews.single.collectionIds, [
        'project',
      ]);
      expect(backup.notes.single.collectionId, 'project');
      expect(backup.stages.single.collectionId, 'project');
      final api = FakeApi();
      final store = NotesStore(api: api, currentUserId: 'u-me');
      addTearDown(store.dispose);
      await store.load();
      await store.restoreBackup(backup);
      expect(api.notes.values.single.collectionId, 'project');
      expect(api.stages.values.single.collectionId, 'project');
      expect(store.collectionById('project')!.layout, 'board');
      expect(store.savedViews.single.collectionIds, ['project']);
    },
  );

  test('collection and smart-view wire models round-trip their scope', () {
    const collection = NoteCollection(
      id: 'project',
      name: 'Project',
      layout: 'board',
      position: 2048,
    );
    const view = SavedView(
      id: 'urgent-projects',
      name: 'Urgent projects',
      query: 'label:urgent',
      collectionIds: ['project'],
    );
    expect(NoteCollection.fromJson(collection.toJson()), collection);
    expect(SavedView.fromJson(view.toJson()), view);
  });

  test('invalid collection layouts fall back to masonry', () {
    final collection = NoteCollection.fromJson({
      'id': 'project',
      'name': 'Project',
      'layout': 'future-layout',
    });
    expect(collection.layout, 'masonry');
  });

  test('bulk move deduplicates notes and clears their stages', () async {
    final api = FakeApi();
    final store = NotesStore(api: api, currentUserId: 'u-me');
    addTearDown(store.dispose);
    await store.load();
    final target = store.createCollection('Project', 'board');
    store.selectCollection(target.id);
    final stage = store.createStage('Doing');
    final first = store.createDraft();
    final second = store.createDraft();
    store.setNoteStage(first.id, stage.id);
    store.setNoteStage(second.id, stage.id);

    store.moveNotesToCollection([first.id, second.id, first.id], 'inbox');

    expect(store.noteById(first.id)!.collectionId, 'inbox');
    expect(store.noteById(second.id)!.collectionId, 'inbox');
    expect(store.noteById(first.id)!.stageId, isNull);
    expect(store.noteById(second.id)!.stageId, isNull);
  });

  test('invalid or deleted collection selections fall back to Inbox', () async {
    final store = NotesStore(api: FakeApi(), currentUserId: 'u-me');
    addTearDown(store.dispose);
    await store.load();
    final collection = store.createCollection('Temporary', 'masonry');

    store.selectCollection('missing');
    expect(store.composeCollectionId, 'inbox');
    store.selectCollection(collection.id);
    store.deleteCollection(collection.id);
    expect(store.composeCollectionId, 'inbox');
    expect(store.collectionById(collection.id), isNull);
  });
}
