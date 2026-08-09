import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/api/api_client.dart';
import 'package:skippy/models/dropped_file.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/models/workspace.dart';
import 'package:skippy/state/local_cache.dart';
import 'package:skippy/state/notes_store.dart';

import 'fake_api.dart';

Note serverNote(
  String id, {
  String title = '',
  String content = '',
  NoteKind kind = NoteKind.text,
  List<ChecklistItem> items = const [],
  bool pinned = false,
  bool archived = false,
  bool trashed = false,
  double position = 0,
  DateTime? createdAt,
  DateTime? updatedAt,
  Set<String> labelIds = const {},
  UserRef? owner,
  DateTime? reminderAt,
  String workspaceId = '',
  List<UserRef> collaborators = const [],
}) {
  final now = DateTime.now();
  return Note(
    id: id,
    kind: kind,
    title: title,
    content: content,
    items: items,
    pinned: pinned,
    archived: archived,
    trashed: trashed,
    position: position,
    reminderAt: reminderAt,
    workspaceId: workspaceId,
    createdAt: createdAt ?? now,
    updatedAt: updatedAt ?? now,
    labelIds: labelIds,
    owner: owner ?? const UserRef(id: 'u-me', name: 'me'),
    collaborators: collaborators,
  );
}

/// Let debounce timers (400ms) and queue flushes run out.
Future<void> settle() =>
    Future<void>.delayed(const Duration(milliseconds: 600));

/// Production waits 5s before calling an outage an outage (see
/// [NotesStore.offlineGrace]); tests wait 20ms for the same behaviour.
const testOfflineGrace = Duration(milliseconds: 20);

NotesStore testStore(
  FakeApi api, {
  LocalCache? cache,
  String cacheNamespace = '',
  bool migrateLegacyCache = false,
}) => NotesStore(
  api: api,
  cache: cache,
  currentUserId: 'u-me',
  cacheNamespace: cacheNamespace,
  migrateLegacyCache: migrateLegacyCache,
  offlineGrace: testOfflineGrace,
);

void main() {
  late FakeApi api;
  late NotesStore store;

  setUp(() {
    api = FakeApi();
    // A 20ms grace before a failure counts as "offline" keeps the production
    // behaviour (see NotesStore.offlineGrace) without a 5s wait per test.
    store = testStore(api);
  });

  tearDown(() => store.dispose());

  group('drafts', () {
    test('draft is only created on the server once it has content', () async {
      final draft = store.createDraft();
      expect(api.log.where((l) => l.startsWith('createNote')), isEmpty);

      store.updateNoteContent(draft.id, title: 'Hello', content: '');
      await settle();
      expect(api.notes.containsKey(draft.id), isTrue);
      expect(api.notes[draft.id]!.title, 'Hello');

      // Later edits patch instead of re-creating.
      store.updateNoteContent(draft.id, title: 'Hello', content: 'World');
      await settle();
      expect(api.notes[draft.id]!.content, 'World');
      expect(api.log.where((l) => l.startsWith('createNote')).length, 1);
    });

    test(
      'empty draft is discarded on finalize without any server call',
      () async {
        final draft = store.createDraft();
        final discarded = store.finalizeNote(draft.id);
        expect(discarded, isTrue);
        expect(store.noteById(draft.id), isNull);
        await settle();
        expect(api.log.where((l) => l.startsWith('createNote')), isEmpty);
        expect(api.log.where((l) => l.startsWith('deleteNote')), isEmpty);
      },
    );

    test('an empty draft can be retained for a personal reminder', () async {
      final draft = store.createDraft();

      expect(store.finalizeNote(draft.id, retainEmpty: true), isFalse);
      await settle();

      expect(store.noteById(draft.id), isNotNull);
      expect(api.notes.containsKey(draft.id), isTrue);
      expect(
        api.log.where((entry) => entry.startsWith('createNote')).length,
        1,
      );
    });

    test('a wordless draft with a reminder is kept, not discarded', () async {
      final at = DateTime.now().add(const Duration(hours: 2));
      final draft = store.createDraft();
      store.setReminder(draft.id, at);

      // Nothing was typed, but the alarm is worth keeping, so it materializes
      // immediately rather than waiting for editor close.
      await settle();
      expect(api.notes[draft.id]!.reminderAt!.toUtc(), at.toUtc());

      expect(store.finalizeNote(draft.id), isFalse);
      await settle();
      expect(store.noteById(draft.id), isNotNull);
      expect(api.notes[draft.id]!.reminderAt!.toUtc(), at.toUtc());
    });

    test('emptying a shared note does not discard it on finalize', () async {
      api.notes['n1'] = serverNote('n1', title: 'shared');
      await store.load();
      await store.addCollaborator('n1', 'friend@example.com');

      store.updateNoteContent('n1', title: '', content: '');
      await settle();

      expect(store.finalizeNote('n1'), isFalse);
      expect(store.noteById('n1'), isNotNull);
      expect(api.log.where((l) => l.startsWith('deleteNote')), isEmpty);
    });

    test('emptying a workspace-shared note does not discard it', () async {
      api.workspaces['shared'] = const Workspace(
        id: 'shared',
        name: 'Team',
        owner: UserRef(id: 'u-me', name: 'me'),
        members: [UserRef(id: 'u2', name: 'Ada')],
      );
      api.notes['n1'] = serverNote(
        'n1',
        title: 'shared',
        workspaceId: 'shared',
      );
      await store.load();

      store.updateNoteContent('n1', title: '', content: '');
      await settle();

      expect(store.finalizeNote('n1'), isFalse);
      expect(store.noteById('n1'), isNotNull);
      expect(api.log.where((l) => l.startsWith('deleteNote')), isEmpty);
    });

    test('rapid edits are debounced into few patches', () async {
      api.notes['n1'] = serverNote('n1', title: 'x');
      await store.load();
      for (final t in ['a', 'ab', 'abc', 'abcd']) {
        store.updateNoteContent('n1', title: t, content: '');
      }
      await settle();
      expect(api.notes['n1']!.title, 'abcd');
      final patches = api.log.where((l) => l.startsWith('patchNote:n1')).length;
      expect(patches, 1);
    });
  });

  group('note actions', () {
    test('pinning an archived note unarchives it', () async {
      api.notes['n1'] = serverNote('n1', title: 'a', archived: true);
      await store.load();
      store.togglePin('n1');
      final note = store.noteById('n1')!;
      expect(note.pinned, isTrue);
      expect(note.archived, isFalse);
      await settle();
      expect(api.notes['n1']!.pinned, isTrue);
      expect(api.notes['n1']!.archived, isFalse);
    });

    test('archiving unpins', () async {
      api.notes['n1'] = serverNote('n1', title: 'a', pinned: true);
      await store.load();
      store.setArchived('n1', true);
      expect(store.noteById('n1')!.pinned, isFalse);
      expect(store.noteById('n1')!.archived, isTrue);
    });

    test('reorder renumbers positions like the server will', () async {
      api.notes['a'] = serverNote('a', title: 'a', position: 1);
      api.notes['b'] = serverNote('b', title: 'b', position: 2);
      api.notes['c'] = serverNote('c', title: 'c', position: 3);
      await store.load();
      store.reorder(['c', 'a', 'b']);
      final ordered = store.notesFor(ViewSelection.notes, '').others;
      expect([for (final n in ordered) n.id], ['c', 'a', 'b']);
      expect(store.noteById('c')!.position, 1024.0);
      expect(store.noteById('b')!.position, 3 * 1024.0);
      await settle();
      expect(api.notes['c']!.position, 1024.0);
    });

    test(
      'duplicate copies content with fresh ids and no collaborators',
      () async {
        api.notes['n1'] = serverNote(
          'n1',
          title: 'orig',
          kind: NoteKind.checklist,
          items: [const ChecklistItem(id: 'i1', text: 'Milk', done: true)],
        );
        await store.load();
        store.duplicate('n1');
        final all = store.notesFor(ViewSelection.notes, '').others;
        expect(all.length, 2);
        final copy = all.firstWhere((n) => n.id != 'n1');
        expect(copy.title, 'orig');
        expect(copy.items.single.text, 'Milk');
        expect(copy.items.single.id, isNot('i1'));
        await settle();
        expect(api.notes.length, 2);
      },
    );

    test('convertKind maps lines to items and back', () async {
      api.notes['n1'] = serverNote('n1', content: 'Milk\n\nEggs');
      await store.load();
      store.convertKind('n1', NoteKind.checklist);
      var note = store.noteById('n1')!;
      expect(note.isChecklist, isTrue);
      expect([for (final i in note.items) i.text], ['Milk', 'Eggs']);
      expect(note.content, isEmpty);

      store.convertKind('n1', NoteKind.text);
      note = store.noteById('n1')!;
      expect(note.isChecklist, isFalse);
      expect(note.content, 'Milk\nEggs');
      expect(note.items, isEmpty);
    });

    test('markdown conversions keep content and map task syntax', () async {
      api.notes['n1'] = serverNote('n1', content: '# Plan\n- [x] Milk\n- Eggs');
      await store.load();

      // text -> markdown: content untouched, only the rendering changes.
      store.convertKind('n1', NoteKind.markdown);
      var note = store.noteById('n1')!;
      expect(note.kind, NoteKind.markdown);
      expect(note.content, '# Plan\n- [x] Milk\n- Eggs');

      // markdown -> checklist: task markers map onto the checkbox state.
      store.convertKind('n1', NoteKind.checklist);
      note = store.noteById('n1')!;
      expect(note.isChecklist, isTrue);
      expect(
        [for (final i in note.items) (i.text, i.done)],
        [('# Plan', false), ('Milk', true), ('Eggs', false)],
      );

      // checklist -> markdown: items become task-list lines.
      store.convertKind('n1', NoteKind.markdown);
      note = store.noteById('n1')!;
      expect(note.kind, NoteKind.markdown);
      expect(note.content, '- [ ] # Plan\n- [x] Milk\n- [ ] Eggs');
      await settle();
      expect(api.notes['n1']!.kind, NoteKind.markdown);
    });

    test(
      'addLabelToNote adds once and is idempotent (drag onto label)',
      () async {
        api.labels['l1'] = const Label(id: 'l1', name: 'work');
        api.notes['n1'] = serverNote('n1', title: 'a');
        await store.load();

        expect(store.addLabelToNote('n1', 'l1'), isTrue);
        expect(store.noteById('n1')!.labelIds, contains('l1'));

        // Dropping again is a no-op, never removes the label.
        expect(store.addLabelToNote('n1', 'l1'), isFalse);
        expect(store.noteById('n1')!.labelIds, contains('l1'));

        await settle();
        expect(api.notes['n1']!.labelIds, contains('l1'));
      },
    );

    test('reminders serialize to UTC and clear with null', () async {
      api.notes['n1'] = serverNote('n1', title: 'a');
      await store.load();
      final when = DateTime(2030, 1, 2, 9, 30);
      store.setReminder('n1', when, ReminderRepeat.weekly);
      expect(store.noteById('n1')!.reminderAt, when);
      expect(store.noteById('n1')!.reminderRepeat, ReminderRepeat.weekly);
      await settle();
      expect(api.notes['n1']!.reminderAt, isNotNull);
      expect(api.notes['n1']!.reminderRepeat, ReminderRepeat.weekly);
      store.setReminder('n1', null);
      await settle();
      expect(api.notes['n1']!.reminderAt, isNull);
    });
  });

  group('views and search', () {
    test('views filter correctly and trash only shows own notes', () async {
      api.notes['mine'] = serverNote('mine', title: 'mine', trashed: true);
      api.notes['shared-trashed'] = serverNote(
        'shared-trashed',
        title: 'theirs',
        trashed: true,
        owner: const UserRef(id: 'u-ada', name: 'ada'),
      );
      api.notes['active'] = serverNote('active', title: 'active');
      api.notes['archived'] = serverNote(
        'archived',
        title: 'arch',
        archived: true,
      );
      api.notes['due'] = serverNote(
        'due',
        title: 'due',
        reminderAt: DateTime(2030),
      );
      await store.load();

      expect([
        for (final n in store.notesFor(ViewSelection.notes, '').others) n.id,
      ], containsAll(['active', 'due']));
      expect(
        store.notesFor(ViewSelection.archive, '').others.single.id,
        'archived',
      );
      expect(store.notesFor(ViewSelection.trash, '').others.single.id, 'mine');
      expect(
        store.notesFor(ViewSelection.reminders, '').others.single.id,
        'due',
      );
    });

    test(
      'search matches title, content, checklist items, and label names',
      () async {
        api.labels['l1'] = const Label(id: 'l1', name: 'groceries');
        api.notes['a'] = serverNote('a', title: 'Zebra facts');
        api.notes['b'] = serverNote('b', content: 'the zebra crossed');
        api.notes['c'] = serverNote(
          'c',
          kind: NoteKind.checklist,
          items: [const ChecklistItem(id: 'i', text: 'zebra food')],
        );
        api.notes['d'] = serverNote('d', title: 'shopping', labelIds: {'l1'});
        api.notes['e'] = serverNote('e', title: 'unrelated');
        await store.load();

        final zebra = store.notesFor(ViewSelection.notes, 'zebra').others;
        expect([for (final n in zebra) n.id], containsAll(['a', 'b', 'c']));
        expect(zebra.length, 3);
        final byLabel = store.notesFor(ViewSelection.notes, 'grocer').others;
        expect(byLabel.single.id, 'd');
      },
    );

    test(
      'sort modes reorder the visible list without touching positions',
      () async {
        final now = DateTime.now();
        api.notes['old'] = serverNote(
          'old',
          title: 'old',
          position: 1,
          createdAt: now.subtract(const Duration(days: 2)),
          updatedAt: now.subtract(const Duration(minutes: 1)),
        );
        api.notes['new'] = serverNote(
          'new',
          title: 'new',
          position: 2,
          createdAt: now,
          updatedAt: now.subtract(const Duration(days: 1)),
        );
        await store.load();

        List<String> idsFor(SortMode mode) {
          store.setSortMode(mode);
          return [
            for (final n in store.notesFor(ViewSelection.notes, '').others)
              n.id,
          ];
        }

        expect(idsFor(SortMode.custom), ['old', 'new']);
        expect(idsFor(SortMode.newest), ['new', 'old']);
        expect(idsFor(SortMode.oldest), ['old', 'new']);
        expect(idsFor(SortMode.edited), ['old', 'new']); // edited more recently
        expect(store.noteById('old')!.position, 1); // untouched
      },
    );
  });

  group('setChecklistItemDone', () {
    test('is idempotent, so a replayed widget tick costs nothing', () async {
      api.notes['n1'] = serverNote(
        'n1',
        kind: NoteKind.checklist,
        items: [const ChecklistItem(id: 'i1', text: 'Milk')],
      );
      await store.load();

      store.setChecklistItemDone('n1', 'i1', true);
      await settle();
      final afterFirst = store.noteById('n1')!.updatedAt;
      final patches = api.log.where((l) => l.startsWith('patchNote')).length;

      // Same absolute value again: no edit, no rebuild, no second patch.
      store.setChecklistItemDone('n1', 'i1', true);
      await settle();
      expect(store.noteById('n1')!.items.single.done, isTrue);
      expect(store.noteById('n1')!.updatedAt, afterFirst);
      expect(api.log.where((l) => l.startsWith('patchNote')).length, patches);
    });

    test('ignores an unknown note or item', () async {
      api.notes['n1'] = serverNote(
        'n1',
        kind: NoteKind.checklist,
        items: [const ChecklistItem(id: 'i1', text: 'Milk')],
      );
      await store.load();

      store.setChecklistItemDone('nope', 'i1', true);
      store.setChecklistItemDone('n1', 'nope', true);
      await settle();

      expect(store.noteById('n1')!.items.single.done, isFalse);
    });
  });

  group('checklist history & suggestions', () {
    test('checking an item feeds local suggestions immediately', () async {
      api.notes['n1'] = serverNote(
        'n1',
        kind: NoteKind.checklist,
        items: [const ChecklistItem(id: 'i1', text: 'Milk')],
      );
      await store.load();
      expect(store.suggestionsFor('n1', 'mi'), isEmpty);
      store.toggleChecklistItem('n1', 'i1');
      expect(store.suggestionsFor('n1', 'mi'), ['Milk']);
      await settle();
      expect(api.notes['n1']!.items.single.done, isTrue);
    });

    test(
      'suggestions rank prefix over substring and exclude present items',
      () async {
        api.history = {
          'n1': ['Milk', 'Almond milk', 'Eggs', 'Mint'],
        };
        await store.load();
        expect(store.suggestionsFor('n1', 'mi'), [
          'Milk',
          'Mint',
          'Almond milk',
        ]);
        expect(store.suggestionsFor('n1', 'mi', exclude: {'milk'}), [
          'Mint',
          'Almond milk',
        ]);
        // Empty query = the note's whole history, most used first.
        expect(store.suggestionsFor('n1', ''), [
          'Milk',
          'Almond milk',
          'Eggs',
          'Mint',
        ]);
      },
    );

    test('suggestions never leak from other notes', () async {
      api.history = {
        'groceries': ['Milk', 'Eggs'],
        'hardware': ['Sand paper', 'Milk paint'],
      };
      await store.load();
      // Each note only sees its own history, even for shared prefixes.
      expect(store.suggestionsFor('groceries', 'mi'), ['Milk']);
      expect(store.suggestionsFor('hardware', 'mi'), ['Milk paint']);
      // A brand-new note (or none at all) has no history to draw from.
      expect(store.suggestionsFor('brand-new', ''), isEmpty);
      expect(store.suggestionsFor(null, 'mi'), isEmpty);
    });
  });

  group('offline queue', () {
    test(
      'failed ops keep local state, set offline, and replay in order',
      () async {
        api.notes['n1'] = serverNote('n1', title: 'a');
        await store.load();

        api.failWith = Exception('network down');
        store.setColor('n1', 'teal');
        store.togglePin('n1');
        await settle();
        expect(store.offline, isTrue);
        // Local state reflects both changes; server has neither.
        expect(store.noteById('n1')!.color, 'teal');
        expect(store.noteById('n1')!.pinned, isTrue);
        expect(api.notes['n1']!.color, 'default');

        api.failWith = null;
        store.retryNow();
        await settle();
        expect(store.offline, isFalse);
        expect(api.notes['n1']!.color, 'teal');
        expect(api.notes['n1']!.pinned, isTrue);
      },
    );

    test('4xx responses are dropped instead of wedging the queue', () async {
      api.notes['n1'] = serverNote('n1', title: 'a');
      await store.load();
      // Patch a note that was deleted server-side -> 404 -> dropped.
      api.notes.remove('n1');
      store.setColor('n1', 'teal');
      store.createLabel('after');
      await settle();
      expect(store.offline, isFalse);
      expect(api.labels.values.map((l) => l.name), contains('after'));
    });

    for (final status in [401, 408, 425, 429]) {
      test('$status retains an optimistic write for a later retry', () async {
        final cache = MemoryLocalCache();
        api.notes['n1'] = serverNote('n1', title: 'a');
        final s = testStore(api, cache: cache);
        await s.load();

        api.failWith = ApiException(status, 'retry later');
        s.setColor('n1', 'teal');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final pending = await cache.read('u-me');
        expect(pending!['queue'] as List, isNotEmpty);
        expect(api.notes['n1']!.color, 'default');
        expect(s.offline, status == 408);

        api.failWith = null;
        await s.retryNow();
        await settle();
        expect(api.notes['n1']!.color, 'teal');
        expect((await cache.read('u-me'))!['queue'] as List, isEmpty);
        s.dispose();
      });
    }

    test('deleting a never-synced draft makes no server calls', () async {
      final draft = store.createDraft();
      store.deleteForever(draft.id);
      await settle();
      expect(api.log.where((l) => l.contains(draft.id)), isEmpty);
    });

    test('reconnect cannot overwrite a debounced checklist edit', () async {
      api.notes['n1'] = serverNote(
        'n1',
        kind: NoteKind.checklist,
        items: [const ChecklistItem(id: 'i1', text: 'Milk')],
      );
      await store.load();

      api.failWith = Exception('network down');
      await store.checkConnectionNow();
      await Future<void>.delayed(testOfflineGrace * 3);
      expect(store.offline, isTrue);

      api.failWith = null;
      store.updateNoteContent(
        'n1',
        items: [const ChecklistItem(id: 'i1', text: 'Milk and eggs')],
      );

      // Hold the reconnect fetch after it captured the old server note. The
      // 400ms debounce then sends the checklist patch before that stale fetch
      // is allowed to finish, the ordering that used to discard the edit.
      final gate = api.fetchHistoryGate = Completer<void>();
      final reconnect = store.checkConnectionNow();
      await settle();
      expect(api.notes['n1']!.items.single.text, 'Milk and eggs');

      gate.complete();
      await reconnect;

      expect(store.noteById('n1')!.items.single.text, 'Milk and eggs');
      expect(api.notes['n1']!.items.single.text, 'Milk and eggs');
    });
  });

  group('labels with color + icon', () {
    test(
      'createLabel carries color + icon to local state and the server',
      () async {
        await store.load();
        final label = store.createLabel('work', color: '#1A73E8', icon: 'work');
        // Optimistic local copy.
        expect(store.labelById(label.id)!.color, '#1A73E8');
        expect(store.labelById(label.id)!.icon, 'work');
        await settle();
        // Synced to the (fake) server.
        expect(api.labels[label.id]!.color, '#1A73E8');
        expect(api.labels[label.id]!.icon, 'work');
      },
    );

    test(
      'updateLabel recolors, re-icons, and can clear back to default',
      () async {
        await store.load();
        final label = store.createLabel('todo', color: '#EA4335', icon: 'flag');
        await settle();

        store.updateLabel(label.id, name: 'todo', color: '#188038', icon: null);
        expect(store.labelById(label.id)!.color, '#188038');
        expect(store.labelById(label.id)!.icon, isNull);
        await settle();
        expect(api.labels[label.id]!.color, '#188038');
        expect(api.labels[label.id]!.icon, isNull);
      },
    );

    /// Drag-reordering the sidebar list moves a label immediately and syncs
    /// as a single patch, without touching its colour or icon.
    test('moveLabel reorders the sidebar and syncs one patch', () async {
      await store.load();
      final groceries = store.createLabel('Groceries', color: '#1A73E8');
      store.createLabel('Errands');
      store.createLabel('Chores');
      await settle();
      api.log.clear();

      // Send Groceries (index 0) to the end (index 2, post-removal).
      store.moveLabel(groceries.id, 2);
      expect(store.labels.map((l) => l.name), [
        'Errands',
        'Chores',
        'Groceries',
      ]);

      await settle();
      final patches = api.log
          .where((l) => l.startsWith('updateLabel:${groceries.id}'))
          .toList();
      expect(patches.length, 1);
      expect(api.labels[groceries.id]!.color, '#1A73E8');
      expect(api.labels[groceries.id]!.name, 'Groceries');
    });
  });

  group('composing inside a label', () {
    test('a draft born with a label keeps it through the create', () async {
      await store.load();
      final label = store.createLabel('Recipes');

      final draft = store.createDraft(labelIds: {label.id});
      expect(store.noteById(draft.id)!.labelIds, {label.id});
      // Before it has content it is only local; nothing has gone up yet.
      expect(api.notes, isEmpty);

      store.updateNoteContent(draft.id, content: 'Pancakes');
      await settle();

      // The label rides on the create request, a draft is never PATCHed, so
      // sending it later was never an option.
      expect(api.notes[draft.id]!.labelIds, {label.id});
      // And it shows in the view it was written in.
      final inLabel = store.notesFor(
        ViewSelection(NoteView.label, label.id),
        '',
      );
      expect(inLabel.others.single.id, draft.id);
    });

    test('an audio note started in a label view is filed under it', () async {
      await store.load();
      final label = store.createLabel('Ideas');
      final id = await store.createAudioNote(
        Uint8List(8),
        'audio/webm',
        labelIds: {label.id},
      );
      expect(store.noteById(id!)!.labelIds, {label.id});
      await settle();
    });
  });

  group('sync status', () {
    test('reflects synced / syncing / offline', () async {
      await store.load();
      expect(store.syncStatus, SyncStatus.synced);
      expect(store.hasPendingWork, isFalse);

      // An unsynced local draft = pending work; still online → syncing.
      store.createDraft();
      expect(store.hasPendingWork, isTrue);
      expect(store.syncStatus, SyncStatus.syncing);

      // Server unreachable → offline wins over syncing, once the failure has
      // outlasted the grace.
      api.failWith = ApiException(500, 'boom');
      await store.load();
      await Future<void>.delayed(testOfflineGrace * 3);
      expect(store.offline, isTrue);
      expect(store.syncStatus, SyncStatus.offline);
    });

    test(
      'active health probes quickly update and recover connectivity',
      () async {
        await store.load();
        store.startSync();
        // startSync probes immediately (that's what settles "connecting" on
        // launch); let it land before taking the server away.
        await pumpEventQueue();

        api.failWith = Exception('server unreachable');
        await store.checkConnectionNow();
        await Future<void>.delayed(testOfflineGrace * 3);
        expect(store.offline, isTrue);
        expect(store.syncStatus, SyncStatus.offline);

        api.failWith = null;
        await store.checkConnectionNow();
        expect(store.offline, isFalse);
        expect(api.log, contains('checkConnection'));
      },
    );

    test(
      'a failure that recovers within the grace is never announced',
      () async {
        await store.load();
        store.startSync();
        await pumpEventQueue(); // launch probe

        // One probe fails, the kind of blip a phone produces the instant its
        // radio wakes up. Nothing is said about it...
        api.failWith = Exception('radio still waking');
        await store.checkConnectionNow();
        expect(store.offline, isFalse);
        expect(store.syncStatus, isNot(SyncStatus.offline));

        // ...and the next probe, inside the grace, clears it for good.
        api.failWith = null;
        await store.checkConnectionNow();
        await Future<void>.delayed(testOfflineGrace * 3);
        expect(store.offline, isFalse);
      },
    );

    test('cached notes open as "connecting", never as "saved"', () async {
      final cache = MemoryLocalCache();
      await cache.write('u-me', {
        'notes': [serverNote('n1', title: 'cached').toJson()],
        'labels': <dynamic>[],
        'history': <String, dynamic>{},
        'queue': <dynamic>[],
      });
      api.failWith = Exception('offline');
      final s = testStore(api, cache: cache);

      final loaded = s.load();
      // The cache paints first, and while the server hasn't answered the badge
      // must not claim everything is saved, nothing has been checked yet.
      expect(s.syncStatus, SyncStatus.connecting);
      await loaded;
      expect(s.noteById('n1')?.title, 'cached');
      expect(s.syncStatus, SyncStatus.connecting);

      // Still nothing after the grace: now it's a confirmed outage.
      await Future<void>.delayed(testOfflineGrace * 3);
      expect(s.syncStatus, SyncStatus.offline);

      // Reconnecting settles it the other way.
      api.failWith = null;
      await s.checkConnectionNow();
      expect(s.syncStatus, SyncStatus.synced);
      s.dispose();
    });

    test(
      'resuming from the background drops a stale offline verdict',
      () async {
        await store.load();

        // The app went away while the server was unreachable.
        api.failWith = Exception('network down');
        await store.load();
        await Future<void>.delayed(testOfflineGrace * 3);
        expect(store.offline, isTrue);

        // Coming back: the verdict is dropped immediately (it describes a
        // connection nothing has tested since) and a fresh pull runs.
        api.failWith = null;
        api.notes['n9'] = serverNote('n9', title: 'added elsewhere');
        final resumed = store.onResumed();
        expect(store.offline, isFalse);
        await resumed;
        expect(store.noteById('n9')?.title, 'added elsewhere');
        expect(store.offline, isFalse);
      },
    );
  });

  group('manual refresh', () {
    test('re-pulls notes and labels from the server', () async {
      await store.load();
      expect(store.notesForExport, isEmpty);

      // Server gains a note + label out of band (e.g. another device).
      api.notes['n9'] = serverNote('n9', title: 'from elsewhere');
      api.labels['l9'] = const Label(
        id: 'l9',
        name: 'remote',
        color: '#00897B',
      );

      await store.refresh();
      expect(store.noteById('n9')!.title, 'from elsewhere');
      expect(store.labelById('l9')!.color, '#00897B');
    });
  });

  group('drag-drop files', () {
    DroppedFile file(String name, String mime, int size) =>
        DroppedFile(name: name, mime: mime, bytes: Uint8List(size));

    test('dropped files become one note with all attachments', () async {
      final id = await store.createNoteWithFiles([
        file('photo.png', 'image/png', 10),
        file('doc.pdf', 'application/pdf', 20),
      ]);
      expect(id, isNotNull);

      final note = store.noteById(id!)!;
      expect(note.attachments.length, 2);
      expect(note.attachments.first.filename, 'photo.png');
      expect(note.attachments.first.mime, 'image/png');
      // The note exists on the server even though it has no text.
      expect(api.notes[id]!.id, id);
      // A note whose only content is attachments is not "empty", finalize
      // must keep it.
      expect(store.finalizeNote(id), isFalse);
      expect(store.noteById(id), isNotNull);
    });

    test('when every upload fails the draft is discarded', () async {
      api.failWith = ApiException(500, 'boom');
      final id = await store.createNoteWithFiles([
        file('photo.png', 'image/png', 10),
      ]);
      expect(id, isNull);
      // No phantom note left behind locally or queued for the server.
      expect(
        store.notesFor(ViewSelection.notes, '').others.where((n) => n.isEmpty),
        isEmpty,
      );
    });
  });

  group('createTextNote (shared text/links)', () {
    test('shared text becomes one persisted text note', () async {
      final id = await store.createTextNote('https://example.com');
      expect(id, isNotNull);

      final note = store.noteById(id!)!;
      expect(note.kind, NoteKind.text);
      expect(note.content, 'https://example.com');
      // Persisted server-side, not left as a phantom draft.
      expect(api.notes[id]!.content, 'https://example.com');
    });

    test('a title rides along when provided', () async {
      final id = await store.createTextNote('body', title: 'Heading');
      final note = store.noteById(id!)!;
      expect(note.title, 'Heading');
      expect(note.content, 'body');
    });

    test('blank content creates nothing', () async {
      final id = await store.createTextNote('   \n  ');
      expect(id, isNull);
      await settle();
      // No draft left behind, no server call.
      expect(
        store.notesFor(ViewSelection.notes, '').others.where((n) => n.isEmpty),
        isEmpty,
      );
      expect(api.notes, isEmpty);
    });
  });

  group('audio notes', () {
    test(
      'createAudioNote starts transcribing only when Whisper is available',
      () async {
        final id = await store.createAudioNote(
          Uint8List.fromList(List.filled(64, 1)),
          'audio/webm',
          transcriptionAvailable: true,
        );
        expect(id, isNotNull);

        final note = store.noteById(id!)!;
        expect(note.kind, NoteKind.audio);
        // Shown as transcribing immediately, before the server responds.
        expect(note.transcriptStatus, 'pending');
        expect(note.transcribing, isTrue);
        // The clip is attached and recognized as audio.
        expect(note.audioClip, isNotNull);
        expect(note.audioClip!.mime, 'audio/webm');
        // Persisted server-side as an audio note.
        expect(api.notes[id]!.kind, NoteKind.audio);
      },
    );

    test(
      'createAudioNote stays playable when transcription is unavailable',
      () async {
        final id = await store.createAudioNote(Uint8List(16), 'audio/webm');
        expect(id, isNotNull);

        final note = store.noteById(id!)!;
        expect(note.kind, NoteKind.audio);
        expect(note.transcriptStatus, 'none');
        expect(note.transcribing, isFalse);
        expect(note.audioClip, isNotNull);
      },
    );

    test('a failed upload discards the draft', () async {
      api.failWith = ApiException(500, 'boom');
      final id = await store.createAudioNote(Uint8List(16), 'audio/webm');
      expect(id, isNull);
      expect(
        store.notesFor(ViewSelection.notes, '').others.where((n) => n.isAudio),
        isEmpty,
      );
    });

    test('retranscribe flips back to pending and calls the server', () async {
      api.notes['a1'] = serverNote(
        'a1',
        kind: NoteKind.audio,
      ).copyWith(transcriptStatus: 'failed');
      await store.load();
      expect(store.noteById('a1')!.transcriptFailed, isTrue);

      store.retranscribe('a1');
      expect(store.noteById('a1')!.transcriptStatus, 'pending');
      await settle();
      expect(api.log, contains('transcribe:a1'));
    });
  });

  group('sharing', () {
    test(
      'addCollaborator updates the roster; leaving removes the note',
      () async {
        api.notes['n1'] = serverNote('n1', title: 'shared');
        await store.load();
        await store.addCollaborator('n1', 'bob@example.test');
        expect(store.noteById('n1')!.collaborators.single.name, 'bob');

        // A collaborator leaving (self-removal) drops the note locally.
        store.removeCollaborator('n1', 'u-me');
        expect(store.noteById('n1'), isNull);
        await settle();
      },
    );

    test('addCollaborator surfaces server rejection', () async {
      api.notes['n1'] = serverNote('n1', title: 'shared');
      await store.load();
      await expectLater(
        store.addCollaborator('n1', 'nobody@example.test'),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('semantic search', () {
    test('returns local notes in server rank order, excluding trash', () async {
      api.notes['a'] = serverNote('a', title: 'milk and bread shopping');
      api.notes['b'] = serverNote(
        'b',
        content: 'milk delivery schedule',
        trashed: true,
      );
      api.notes['c'] = serverNote(
        'c',
        title: 'quarterly milk market report milk',
      );
      await store.load();
      final results = await store.semanticSearch('milk');
      expect([for (final n in results) n.id], isNot(contains('b')));
      expect(results, isNotEmpty);
    });
  });

  group('live sync', () {
    test('change events trigger a reload when idle', () async {
      api.notes['n1'] = serverNote('n1', title: 'before');
      await store.load();
      store.startSync();
      api.notes['n1'] = api.notes['n1']!.copyWith(title: 'after (remote)');
      api.pushChangeEvent();
      await settle();
      expect(store.noteById('n1')!.title, 'after (remote)');
    });
  });

  group('session lifecycle', () {
    test(
      'dispose stops an in-flight load before it makes another request',
      () async {
        final gatedApi = FakeApi();
        final gate = gatedApi.fetchWorkspacesGate = Completer<void>();
        final s = testStore(gatedApi);
        final loading = s.load();
        await pumpEventQueue();

        s.dispose();
        gate.complete();
        await loading;

        expect(gatedApi.log, ['fetchWorkspaces']);
      },
    );

    test(
      'dispose stops an old queue before it sends the next operation',
      () async {
        final gatedApi = FakeApi()..notes['n1'] = serverNote('n1', title: 'a');
        final s = testStore(gatedApi);
        await s.load();
        final gate = gatedApi.patchGate = Completer<void>();

        s.setColor('n1', 'teal');
        s.togglePin('n1');
        await pumpEventQueue();
        s.dispose();
        gate.complete();
        await pumpEventQueue();

        expect(
          gatedApi.log.where((entry) => entry.startsWith('patchNote:')).length,
          1,
        );
        expect(gatedApi.notes['n1']!.pinned, isFalse);
      },
    );

    test('an older overlapping load cannot replace a newer snapshot', () async {
      final gatedApi = FakeApi()..notes['n1'] = serverNote('n1', title: 'old');
      final gate = gatedApi.fetchLabelsGate = Completer<void>();
      final s = testStore(gatedApi);
      final oldLoad = s.load();
      while (!gatedApi.log.contains('fetchLabels')) {
        await pumpEventQueue();
      }

      gatedApi.notes['n1'] = serverNote('n1', title: 'new');
      await s.load();
      expect(s.noteById('n1')?.title, 'new');

      gate.complete();
      await oldLoad;
      expect(s.noteById('n1')?.title, 'new');
      s.dispose();
    });
  });

  group('offline persistence', () {
    test(
      'cache and pending writes are isolated by server as well as user',
      () async {
        final cache = MemoryLocalCache();
        final firstApi = FakeApi()
          ..notes['private'] = serverNote('private', title: 'server A only');
        final first = testStore(
          firstApi,
          cache: cache,
          cacheNamespace: 'https://a.example',
        );
        await first.load();
        await settle();
        first.dispose();

        final secondApi = FakeApi()..failWith = Exception('offline');
        final second = testStore(
          secondApi,
          cache: cache,
          cacheNamespace: 'https://b.example',
        );
        await second.load();
        expect(second.noteById('private'), isNull);
        second.dispose();

        final firstOfflineApi = FakeApi()..failWith = Exception('offline');
        final firstAgain = testStore(
          firstOfflineApi,
          cache: cache,
          cacheNamespace: 'https://a.example',
        );
        await firstAgain.load();
        expect(firstAgain.noteById('private')?.title, 'server A only');
        firstAgain.dispose();
      },
    );

    test(
      'saved-session migration moves the legacy cache only when allowed',
      () async {
        final cache = MemoryLocalCache();
        await cache.write('u-me', {
          'notes': [serverNote('legacy', title: 'offline').toJson()],
          'labels': <dynamic>[],
          'history': <String, dynamic>{},
          'queue': <dynamic>[],
        });
        final offlineApi = FakeApi()..failWith = Exception('offline');
        final migrated = testStore(
          offlineApi,
          cache: cache,
          cacheNamespace: 'https://known.example',
          migrateLegacyCache: true,
        );
        await migrated.load();
        expect(migrated.noteById('legacy')?.title, 'offline');
        expect(await cache.read('u-me'), isNull);
        migrated.dispose();
      },
    );

    test('fresh login permanently refuses an ambiguous legacy cache', () async {
      final cache = MemoryLocalCache();
      await cache.write('u-me', {
        'notes': [serverNote('legacy', title: 'server A').toJson()],
        'labels': <dynamic>[],
        'history': <String, dynamic>{},
        'queue': [
          {
            'kind': 'patch',
            'id': 'legacy',
            'data': {'color': 'red'},
          },
        ],
      });
      final firstApi = FakeApi()..failWith = Exception('offline');
      final freshLogin = testStore(
        firstApi,
        cache: cache,
        cacheNamespace: 'https://server-b.example',
      );
      await freshLogin.load();
      expect(freshLogin.noteById('legacy'), isNull);
      freshLogin.dispose();

      // On the next launch the token is now a restored session. The empty
      // namespaced marker must still win over A's untouched legacy queue.
      final restoredApi = FakeApi()..failWith = Exception('offline');
      final restored = testStore(
        restoredApi,
        cache: cache,
        cacheNamespace: 'https://server-b.example',
        migrateLegacyCache: true,
      );
      await restored.load();
      expect(restored.noteById('legacy'), isNull);
      expect(restoredApi.log, isNot(contains('patchNote:legacy')));
      expect(await cache.read('u-me'), isNotNull);
      restored.dispose();
    });

    test('edits are written to the local cache', () async {
      final cache = MemoryLocalCache();
      api.notes['n1'] = serverNote('n1', title: 'a');
      final s = testStore(api, cache: cache);
      await s.load();

      s.setColor('n1', 'teal');
      await settle();

      final doc = await cache.read('u-me');
      final notes = (doc!['notes'] as List).cast<Map<String, dynamic>>();
      expect(notes.single['color'], 'teal');
      expect(doc['queue'] as List, isEmpty); // synced; nothing left pending
      s.dispose();
    });

    test('opens from cache when the server is unreachable', () async {
      final cache = MemoryLocalCache();
      // Seed a previous session's snapshot.
      await cache.write('u-me', {
        'notes': [serverNote('n1', title: 'cached').toJson()],
        'labels': <dynamic>[],
        'history': <String, dynamic>{},
        'queue': <dynamic>[],
      });
      api.failWith = Exception('offline');

      final s = testStore(api, cache: cache);
      await s.load();

      // Cached notes render straight away; the outage is only *announced*
      // once it has outlasted the grace.
      expect(s.noteById('n1')?.title, 'cached'); // rendered with no network
      expect(s.offline, isFalse);
      await Future<void>.delayed(testOfflineGrace * 3);
      expect(s.offline, isTrue);
      s.dispose();
    });

    test('a note created offline syncs on the next (online) launch', () async {
      final cache = MemoryLocalCache();

      // Session 1: offline. Compose a note; it never reaches the server.
      api.failWith = Exception('offline');
      final s1 = testStore(api, cache: cache);
      await s1.load();
      final draft = s1.createDraft();
      s1.updateNoteContent(draft.id, title: 'written offline');
      await settle();
      expect(s1.offline, isTrue);
      expect(api.notes, isEmpty);
      s1.dispose();

      // Session 2: same cache, back online. The note pushes up on its own.
      api.failWith = null;
      final s2 = testStore(api, cache: cache);
      await s2.load();
      await settle();
      expect(api.notes[draft.id]?.title, 'written offline');
      s2.dispose();
    });

    test('persisted pending writes replay on the next launch', () async {
      final cache = MemoryLocalCache();
      api.notes['n1'] = serverNote('n1', title: 'a');
      await cache.write('u-me', {
        'notes': [api.notes['n1']!.copyWith(color: 'teal').toJson()],
        'labels': <dynamic>[],
        'history': <String, dynamic>{},
        'queue': [
          {
            'kind': 'patch',
            'id': 'n1',
            'data': {'color': 'teal'},
          },
        ],
      });

      final s = testStore(api, cache: cache);
      await s.load();
      await settle();

      expect(api.notes['n1']!.color, 'teal'); // queued patch reached the server
      final doc = await cache.read('u-me');
      expect(doc!['queue'] as List, isEmpty); // and drained from the cache
      s.dispose();
    });

    test('a rejected (4xx) pending write is dropped, not wedged', () async {
      final cache = MemoryLocalCache();
      await cache.write('u-me', {
        'notes': <dynamic>[],
        'labels': <dynamic>[],
        'history': <String, dynamic>{},
        'queue': [
          {
            'kind': 'patch',
            'id': 'ghost', // no such note server-side -> 404
            'data': {'color': 'teal'},
          },
        ],
      });

      final s = testStore(api, cache: cache);
      await s.load();
      await settle();

      expect(s.offline, isFalse);
      final doc = await cache.read('u-me');
      expect(doc!['queue'] as List, isEmpty);
      s.dispose();
    });

    test(
      'a content edit still mid-debounce is captured in the cache',
      () async {
        final cache = MemoryLocalCache();
        api.notes['n1'] = serverNote('n1', title: 'a');
        final s = testStore(api, cache: cache);
        await s.load();

        s.updateNoteContent('n1', content: 'typed, then reloaded');
        // Trigger an immediate (queue-driven) cache write while the 400ms
        // content debounce is still pending; the mid-debounce edit must be
        // folded into the persisted doc. (State-only writes are batched on
        // a 1s timer now, so a bare delay would not persist anything yet.)
        s.setColor('n1', 'teal');
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final doc = await cache.read('u-me');
        final queue = (doc!['queue'] as List).cast<Map<String, dynamic>>();
        final patch = queue.firstWhere(
          (op) =>
              op['kind'] == 'patch' &&
              op['id'] == 'n1' &&
              (op['data'] as Map).containsKey('content'),
          orElse: () => <String, dynamic>{},
        );
        expect((patch['data'] as Map?)?['content'], 'typed, then reloaded');
        s.dispose();
      },
    );

    test(
      'flushForBackground pushes a mid-debounce edit without the 400ms wait',
      () async {
        final cache = MemoryLocalCache();
        api.notes['n1'] = serverNote('n1', title: 'a');
        final s = testStore(api, cache: cache);
        await s.load();

        s.updateNoteContent('n1', content: 'typed, then backgrounded');
        // The OS is about to suspend us: the debounced patch must reach the
        // server (and the cache) immediately, not after the timer fires.
        s.flushForBackground();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(api.notes['n1']!.content, 'typed, then backgrounded');
        final doc = await cache.read('u-me');
        final cached = (doc!['notes'] as List).cast<Map<String, dynamic>>();
        expect(
          cached.singleWhere((n) => n['id'] == 'n1')['content'],
          'typed, then backgrounded',
        );
        s.dispose();
      },
    );
  });

  group('version history', () {
    test('noteVersions flushes pending edits before reading history', () async {
      api.notes['n1'] = serverNote('n1', title: 'a');
      api.versions['n1'] = [
        NoteVersion(
          id: 'v1',
          noteId: 'n1',
          title: 'a',
          createdAt: DateTime.now(),
        ),
      ];
      await store.load();

      // A still-debounced edit must reach the server first, or the timeline
      // wouldn't reflect what the user just typed.
      store.updateNoteContent('n1', title: 'b', content: '');
      final versions = await store.noteVersions('n1');

      expect(api.notes['n1']!.title, 'b');
      final patchIdx = api.log.indexWhere((l) => l.startsWith('patchNote:n1'));
      final fetchIdx = api.log.indexOf('fetchVersions:n1');
      expect(patchIdx, isNonNegative);
      expect(fetchIdx, greaterThan(patchIdx));
      expect(versions.single.id, 'v1');
    });

    test('noteVersions materializes a draft before reading', () async {
      final draft = store.createDraft();
      store.updateNoteContent(draft.id, title: 'fresh', content: '');
      api.versions[draft.id] = const [];

      final versions = await store.noteVersions(draft.id);

      expect(api.notes.containsKey(draft.id), isTrue);
      expect(versions, isEmpty);
      final createIdx = api.log.indexWhere(
        (l) => l.startsWith('createNote:${draft.id}'),
      );
      final fetchIdx = api.log.indexOf('fetchVersions:${draft.id}');
      expect(createIdx, isNonNegative);
      expect(fetchIdx, greaterThan(createIdx));
    });

    test('restore flushes edits, rolls content back, replaces local', () async {
      api.notes['n1'] = serverNote('n1', title: 'current', content: 'now');
      api.versions['n1'] = [
        NoteVersion(
          id: 'v1',
          noteId: 'n1',
          title: 'old',
          content: 'then',
          createdAt: DateTime.now(),
        ),
      ];
      await store.load();

      store.updateNoteContent('n1', title: 'edited', content: 'edited body');
      await store.restoreNoteVersion('n1', 'v1');

      // The pending edit lands before the restore, then content rolls back.
      final patchIdx = api.log.indexWhere((l) => l.startsWith('patchNote:n1'));
      final restoreIdx = api.log.indexOf('restoreVersion:n1:v1');
      expect(patchIdx, isNonNegative);
      expect(restoreIdx, greaterThan(patchIdx));

      final note = store.noteById('n1')!;
      expect(note.title, 'old');
      expect(note.content, 'then');
      expect(api.notes['n1']!.title, 'old');
    });
  });

  group('stages', () {
    /// A stage change is one queued write carrying both fields, not a stage
    /// patch chased by a reorder.
    test('setNoteStage is optimistic and syncs as a single patch', () async {
      api.stages['todo'] = const Stage(
        id: 'todo',
        name: 'Todo',
        workspaceId: 'w-default',
      );
      api.notes['n1'] = serverNote('n1', title: 'card');
      await store.load();

      store.setNoteStage('n1', 'todo');
      // Local state moves without awaiting the network.
      expect(store.noteById('n1')!.stageId, 'todo');

      await settle();
      final patches = api.log
          .where((l) => l.startsWith('patchNote:n1'))
          .toList();
      expect(patches.length, 1);
      expect(patches.single, contains('stage_id'));
      expect(patches.single, contains('stage_position'));
      expect(api.notes['n1']!.stageId, 'todo');
    });

    test('moving to a column places the card at its end', () async {
      api.stages['todo'] = const Stage(
        id: 'todo',
        name: 'Todo',
        workspaceId: 'w-default',
      );
      api.notes['a'] = serverNote(
        'a',
      ).copyWith(stageId: 'todo', stagePosition: 4096);
      api.notes['b'] = serverNote('b');
      await store.load();

      store.setNoteStage('b', 'todo');
      expect(store.noteById('b')!.stagePosition, greaterThan(4096));
    });

    test('setNoteStage(null) sends the card back to unassigned', () async {
      api.stages['todo'] = const Stage(
        id: 'todo',
        name: 'Todo',
        workspaceId: 'w-default',
      );
      api.notes['n1'] = serverNote('n1').copyWith(stageId: 'todo');
      await store.load();

      store.setNoteStage('n1', null);
      await settle();
      expect(store.noteById('n1')!.stageId, isNull);
      expect(api.notes['n1']!.stageId, isNull);
    });

    /// Stages and labels are independent: moving a card between columns says
    /// nothing about its taxonomy.
    test('changing stage leaves labels alone', () async {
      api.stages['todo'] = const Stage(
        id: 'todo',
        name: 'Todo',
        workspaceId: 'w-default',
      );
      api.labels['work'] = const Label(
        id: 'work',
        name: 'work',
        workspaceId: 'w-default',
      );
      api.notes['n1'] = serverNote('n1', labelIds: const {'work'});
      await store.load();

      store.setNoteStage('n1', 'todo');
      await settle();
      expect(store.noteById('n1')!.labelIds, {'work'});
      expect(api.notes['n1']!.labelIds, {'work'});
    });

    test('deleting a stage keeps its notes, unassigned', () async {
      api.stages['todo'] = const Stage(
        id: 'todo',
        name: 'Todo',
        workspaceId: 'w-default',
      );
      api.notes['n1'] = serverNote('n1').copyWith(stageId: 'todo');
      await store.load();

      store.deleteStage('todo');
      expect(store.noteById('n1'), isNotNull);
      expect(store.noteById('n1')!.stageId, isNull);
      await settle();
      expect(api.stages.containsKey('todo'), isFalse);
      expect(api.notes['n1'], isNotNull);
      expect(api.notes['n1']!.stageId, isNull);
    });

    test('created stages append to the right of the board', () async {
      await store.load();
      store.createStage('Todo');
      store.createStage('Doing');
      await settle();
      expect(store.stages.map((s) => s.name), ['Todo', 'Doing']);
      expect(api.stages.length, 2);
    });

    /// Drag-reordering a column moves it in the local order immediately and
    /// syncs as a single patch carrying the new position, without touching
    /// the column's name or colour.
    test('moveStage reorders the board and syncs one patch', () async {
      await store.load();
      final todo = store.createStage('Todo', color: '#1A73E8');
      store.createStage('Doing');
      store.createStage('Done');
      await settle();
      api.log.clear();

      // Send Todo (index 0) to the end (index 2, post-removal).
      store.moveStage(todo.id, 2);
      expect(store.stages.map((s) => s.name), ['Doing', 'Done', 'Todo']);

      await settle();
      final patches = api.log
          .where((l) => l.startsWith('updateStage:${todo.id}'))
          .toList();
      expect(patches.length, 1);
      // Colour survives the reorder unchanged.
      expect(api.stages[todo.id]!.color, '#1A73E8');
      expect(api.stages[todo.id]!.name, 'Todo');
    });

    /// Reordering inside a column is a move to the stage the card is already
    /// in, so it takes the same single-patch path as a cross-column move.
    test('a reposition within a column is one patch', () async {
      api.stages['todo'] = const Stage(
        id: 'todo',
        name: 'Todo',
        workspaceId: 'w-default',
      );
      api.notes['a'] = serverNote(
        'a',
      ).copyWith(stageId: 'todo', stagePosition: 1024);
      api.notes['b'] = serverNote(
        'b',
      ).copyWith(stageId: 'todo', stagePosition: 2048);
      api.notes['c'] = serverNote(
        'c',
      ).copyWith(stageId: 'todo', stagePosition: 3072);
      await store.load();

      // Drop c between a and b.
      store.setNoteStage('c', 'todo', position: 1536);
      expect(store.noteById('c')!.stagePosition, 1536.0);

      await settle();
      expect(api.log.where((l) => l.startsWith('patchNote:c')).length, 1);
      expect(api.notes['c']!.stagePosition, 1536.0);
      expect(api.notes['c']!.stageId, 'todo');
    });

    test('dropping a card where it already sits queues nothing', () async {
      api.stages['todo'] = const Stage(
        id: 'todo',
        name: 'Todo',
        workspaceId: 'w-default',
      );
      api.notes['a'] = serverNote(
        'a',
      ).copyWith(stageId: 'todo', stagePosition: 1024);
      await store.load();
      api.log.clear();

      store.setNoteStage('a', 'todo', position: 1024);
      await settle();
      expect(api.log.where((l) => l.startsWith('patchNote')), isEmpty);
    });

    test('a stage change survives an app restart', () async {
      final cache = MemoryLocalCache();
      api.stages['todo'] = const Stage(
        id: 'todo',
        name: 'Todo',
        workspaceId: 'w-default',
      );
      api.notes['n1'] = serverNote('n1');
      final first = testStore(api, cache: cache);
      await first.load();
      api.failWith = Exception('network down');
      first.setNoteStage('n1', 'todo');
      await settle();
      first.dispose();

      // The write never reached the server, but the queue outlived the launch.
      expect(api.notes['n1']!.stageId, isNull);
      api.failWith = null;
      final second = testStore(api, cache: cache);
      await second.load();
      await settle();
      expect(api.notes['n1']!.stageId, 'todo');
      second.dispose();
    });
  });
}
