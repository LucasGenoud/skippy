import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/note_links.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/state/starter_notes.dart';

import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote;

NotesStore storeFor(FakeApi api, AccountOrigin origin) =>
    NotesStore(api: api, currentUserId: 'u-me', accountOrigin: origin);

void main() {
  test('a new account opens on the starter notes, welcome first', () async {
    final api = FakeApi();
    final store = storeFor(api, AccountOrigin.justCreated);
    addTearDown(store.dispose);

    await store.load();

    final titles = store.notesForWidgets.map((note) => note.title).toList();
    expect(titles.first, 'Welcome to Skippy');
    expect(titles, hasLength(3));
    expect(
      store.notesForWidgets.map((note) => note.kind),
      containsAll([NoteKind.markdown, NoteKind.checklist]),
    );
  });

  test('starter notes reach the server and file in the workspace', () async {
    final api = FakeApi();
    final store = storeFor(api, AccountOrigin.justCreated);
    addTearDown(store.dispose);

    await store.load();
    await pumpEventQueue();

    expect(api.notes, hasLength(3));
    for (final note in api.notes.values) {
      expect(note.workspaceId, api.defaultWorkspaceId);
    }
  });

  test('the welcome note links to the other starter notes', () async {
    final api = FakeApi();
    final store = storeFor(api, AccountOrigin.justCreated);
    addTearDown(store.dispose);

    await store.load();

    final welcome = store.notesForWidgets.first;
    final linked = findNoteLinks(welcome.content).map((l) => l.noteId).toSet();
    final others = store.notesForWidgets.skip(1).map((note) => note.id).toSet();
    expect(linked, others);
  });

  test('an existing account never gets starter notes', () async {
    final api = FakeApi();
    final store = storeFor(api, AccountOrigin.existing);
    addTearDown(store.dispose);

    await store.load();
    await pumpEventQueue();

    expect(store.notesForWidgets, isEmpty);
    expect(api.notes, isEmpty);
  });

  test('an account that already holds notes is left alone', () async {
    final api = FakeApi()..notes['n1'] = serverNote('n1', title: 'Mine');
    final store = storeFor(api, AccountOrigin.justCreated);
    addTearDown(store.dispose);

    await store.load();

    expect(store.notesForWidgets.map((note) => note.id), ['n1']);
  });

  test('a failed first load waits, and a later load adds them once', () async {
    final api = FakeApi()..failWith = Exception('offline');
    final store = storeFor(api, AccountOrigin.justCreated);
    addTearDown(store.dispose);

    await store.load();
    expect(store.notesForWidgets, isEmpty);

    api.failWith = null;
    await store.load();
    await store.load();
    await pumpEventQueue();

    expect(api.notes, hasLength(3));
  });
}
