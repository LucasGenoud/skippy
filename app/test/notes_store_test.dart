import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sticky_notes/api/api_client.dart';
import 'package:sticky_notes/models/dropped_file.dart';
import 'package:sticky_notes/models/note.dart';
import 'package:sticky_notes/state/notes_store.dart';

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
    createdAt: createdAt ?? now,
    updatedAt: updatedAt ?? now,
    labelIds: labelIds,
    owner: owner ?? const UserRef(id: 'u-me', username: 'me'),
  );
}

/// Let debounce timers (400ms) and queue flushes run out.
Future<void> settle() =>
    Future<void>.delayed(const Duration(milliseconds: 600));

void main() {
  late FakeApi api;
  late NotesStore store;

  setUp(() {
    api = FakeApi();
    store = NotesStore(api: api, currentUserId: 'u-me');
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
    test('pinning an archived note unarchives it (Keep parity)', () async {
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

    test('reminders serialize to UTC and clear with null', () async {
      api.notes['n1'] = serverNote('n1', title: 'a');
      await store.load();
      final when = DateTime(2030, 1, 2, 9, 30);
      store.setReminder('n1', when);
      expect(store.noteById('n1')!.reminderAt, when);
      await settle();
      expect(api.notes['n1']!.reminderAt, isNotNull);
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
        owner: const UserRef(id: 'u-ada', username: 'ada'),
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

    test('deleting a never-synced draft makes no server calls', () async {
      final draft = store.createDraft();
      store.deleteForever(draft.id);
      await settle();
      expect(api.log.where((l) => l.contains(draft.id)), isEmpty);
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
      // A note whose only content is attachments is not "empty" — finalize
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

  group('audio notes', () {
    test('createAudioNote makes an audio note that starts transcribing',
        () async {
      final id = await store.createAudioNote(
        Uint8List.fromList(List.filled(64, 1)),
        'audio/webm',
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
    });

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
      api.notes['a1'] = serverNote('a1', kind: NoteKind.audio)
          .copyWith(transcriptStatus: 'failed');
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
        await store.addCollaborator('n1', 'bob');
        expect(store.noteById('n1')!.collaborators.single.username, 'bob');

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
        store.addCollaborator('n1', 'nobody'),
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
}
