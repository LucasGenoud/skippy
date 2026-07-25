import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/api/api_client.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/models/workspace.dart';
import 'package:skippy/state/local_cache.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/widgets/app_drawer.dart';
import 'package:skippy/widgets/workspace_menu.dart';

import 'fake_api.dart';
import 'widget_test.dart' show homeApp;

Note noteIn(
  String workspaceId,
  String id, {
  String title = '',
  Set<String> labelIds = const {},
  bool trashed = false,
  UserRef? owner,
}) => Note(
  id: id,
  workspaceId: workspaceId,
  title: title,
  labelIds: labelIds,
  trashed: trashed,
  createdAt: DateTime.now(),
  updatedAt: DateTime.now(),
  owner: owner ?? const UserRef(id: 'u-me', name: 'me'),
);

/// Let debounce timers (400ms) and queue flushes run out.
Future<void> settle() =>
    Future<void>.delayed(const Duration(milliseconds: 600));

void main() {
  late FakeApi api;
  late NotesStore store;

  /// A second workspace on the server, alongside the seeded default one.
  const work = 'w-work';

  setUp(() {
    api = FakeApi();
    api.workspaces[work] = const Workspace(
      id: work,
      name: 'Work',
      owner: UserRef(id: 'u-me', name: 'Me Example'),
    );
    store = NotesStore(api: api, currentUserId: 'u-me');
  });

  group('workspace selection', () {
    test('opens in the default workspace and lists only its notes', () async {
      api.notes['a'] = noteIn('w-default', 'a', title: 'home');
      api.notes['b'] = noteIn(work, 'b', title: 'job');
      await store.load();

      expect(store.activeWorkspaceId, 'w-default');
      expect(store.workspaces.first.isDefault, isTrue);
      expect(
        store.notesFor(ViewSelection.notes, '').others.map((n) => n.id),
        ['a'],
      );

      store.setActiveWorkspace(work);
      expect(
        store.notesFor(ViewSelection.notes, '').others.map((n) => n.id),
        ['b'],
      );
    });

    test('a note shared from a workspace we are not in shows in the default'
        ' one', () async {
      // Reached through a per-note share: its workspace belongs to someone
      // else, so it has to surface somewhere.
      api.notes['s'] = noteIn(
        'w-someone-else',
        's',
        title: 'shared with me',
        owner: const UserRef(id: 'u-ada', name: 'Ada'),
      );
      await store.load();

      expect(
        store.notesFor(ViewSelection.notes, '').others.map((n) => n.id),
        ['s'],
      );
      store.setActiveWorkspace(work);
      expect(store.notesFor(ViewSelection.notes, '').others, isEmpty);
    });

    test('labels are the open workspace\'s taxonomy', () async {
      api.labels['l1'] = const Label(
        id: 'l1',
        workspaceId: 'w-default',
        name: 'Home',
      );
      api.labels['l2'] = const Label(
        id: 'l2',
        workspaceId: work,
        name: 'Urgent',
      );
      await store.load();

      expect(store.labels.map((l) => l.id), ['l1']);
      store.setActiveWorkspace(work);
      expect(store.labels.map((l) => l.id), ['l2']);
      // labelById still resolves across workspaces, so a moved note can tell
      // which of its labels it is leaving behind.
      expect(store.labelById('l1')?.name, 'Home');
    });

    test('new notes and labels are filed in the open workspace', () async {
      await store.load();
      store.setActiveWorkspace(work);

      final draft = store.createDraft();
      expect(draft.workspaceId, work);
      store.updateNoteContent(draft.id, content: 'hello');
      final label = store.createLabel('Urgent');
      expect(label.workspaceId, work);
      await settle();

      expect(api.notes[draft.id]!.workspaceId, work);
      expect(api.labels[label.id]!.workspaceId, work);
    });

    test('semantic search is scoped to the open workspace', () async {
      api.notes['a'] = noteIn('w-default', 'a', title: 'milk');
      api.notes['b'] = noteIn(work, 'b', title: 'milk');
      await store.load();

      expect((await store.semanticSearch('milk')).map((n) => n.id), ['a']);
      store.setActiveWorkspace(work);
      expect((await store.semanticSearch('milk')).map((n) => n.id), ['b']);
    });
  });

  group('workspace mutations', () {
    test('creating one switches to it immediately and syncs', () async {
      await store.load();
      final created = store.createWorkspace('Trips');

      expect(store.activeWorkspaceId, created.id);
      expect(store.workspaceById(created.id)?.name, 'Trips');
      await settle();
      expect(api.workspaces[created.id]?.name, 'Trips');
    });

    test('renaming is optimistic', () async {
      await store.load();
      store.renameWorkspace(work, 'Day job');
      expect(store.workspaceById(work)?.name, 'Day job');
      await settle();
      expect(api.workspaces[work]?.name, 'Day job');
    });

    test('the default workspace cannot be deleted', () async {
      await store.load();
      expect(store.canDeleteWorkspace('w-default'), isFalse);
      store.deleteWorkspace('w-default');
      expect(store.workspaceById('w-default'), isNotNull);
    });

    test('deleting one returns our notes home and drops its labels', () async {
      api.labels['l2'] = const Label(
        id: 'l2',
        workspaceId: work,
        name: 'Urgent',
      );
      api.notes['b'] = noteIn(work, 'b', title: 'job', labelIds: {'l2'});
      api.notes['c'] = noteIn(
        work,
        'c',
        title: 'theirs',
        owner: const UserRef(id: 'u-ada', name: 'Ada'),
      );
      await store.load();
      store.setActiveWorkspace(work);

      store.deleteWorkspace(work);

      expect(store.workspaceById(work), isNull);
      // The view falls back to the default workspace rather than stranding.
      expect(store.activeWorkspaceId, 'w-default');
      final mine = store.noteById('b')!;
      expect(mine.workspaceId, 'w-default');
      expect(mine.labelIds, isEmpty);
      // A member's note goes home with them, off our shelf.
      expect(store.noteById('c'), isNull);
      expect(store.labels, isEmpty);

      await settle();
      expect(api.workspaces.containsKey(work), isFalse);
    });

    test('leaving one keeps our notes and forgets the rest', () async {
      api.workspaces[work] = const Workspace(
        id: work,
        name: 'Work',
        owner: UserRef(id: 'u-ada', name: 'Ada'),
        members: [UserRef(id: 'u-me', name: 'Me Example')],
      );
      api.notes['b'] = noteIn(work, 'b', title: 'mine');
      api.notes['c'] = noteIn(
        work,
        'c',
        title: 'theirs',
        owner: const UserRef(id: 'u-ada', name: 'Ada'),
      );
      await store.load();

      expect(store.canDeleteWorkspace(work), isFalse, reason: 'not the owner');
      store.leaveWorkspace(work);

      expect(store.workspaceById(work), isNull);
      expect(store.noteById('b')?.workspaceId, 'w-default');
      expect(store.noteById('c'), isNull);
      await settle();
      expect(api.workspaces[work]?.members, isEmpty);
    });

    test('inviting a member surfaces the server rejection', () async {
      await store.load();
      await expectLater(
        store.addWorkspaceMember(work, 'nobody'),
        throwsA(isA<ApiException>()),
      );
      await store.addWorkspaceMember(work, 'ada@example.test');
      expect(store.workspaceById(work)?.members.single.name, 'ada');
    });
  });

  group('moving notes', () {
    test('moves the note and drops the labels it leaves behind', () async {
      api.labels['l1'] = const Label(
        id: 'l1',
        workspaceId: 'w-default',
        name: 'Home',
      );
      api.notes['a'] = noteIn('w-default', 'a', title: 'n', labelIds: {'l1'});
      await store.load();

      store.moveNoteToWorkspace('a', work);

      expect(store.noteById('a')?.workspaceId, work);
      expect(store.noteById('a')?.labelIds, isEmpty);
      await settle();
      expect(api.notes['a']?.workspaceId, work);
    });

    test('only the owner can move a note', () async {
      api.notes['a'] = noteIn(
        'w-default',
        'a',
        owner: const UserRef(id: 'u-ada', name: 'Ada'),
      );
      await store.load();

      store.moveNoteToWorkspace('a', work);
      expect(store.noteById('a')?.workspaceId, 'w-default');
    });
  });

  group('workspace switcher', () {
    testWidgets('names the open workspace and switches the grid', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      api.notes['a'] = noteIn('w-default', 'a', title: 'home note');
      api.notes['b'] = noteIn(work, 'b', title: 'work note');
      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();

      expect(find.text('My notes'), findsOneWidget);
      expect(find.text('home note'), findsOneWidget);
      expect(find.text('work note'), findsNothing);

      await tester.tap(find.byType(WorkspaceMenu));
      await tester.pumpAndSettle();
      // The row's Text is not the tap target; the menu item is.
      await tester.tap(
        find.ancestor(
          of: find.text('Work'),
          matching: find.byType(PopupMenuItem<String>),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Work'), findsWidgets);
      expect(find.text('work note'), findsOneWidget);
      expect(find.text('home note'), findsNothing);
      store.dispose();
    });

    testWidgets('switching away from a label view falls back to Notes', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      api.labels['l1'] = const Label(
        id: 'l1',
        workspaceId: 'w-default',
        name: 'Home',
      );
      api.notes['a'] = noteIn('w-default', 'a', title: 'home note',
          labelIds: {'l1'});
      api.notes['b'] = noteIn(work, 'b', title: 'work note');
      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();

      // 'Home' is also the label chip on the card; the sidebar row is the one
      // that navigates.
      await tester.tap(
        find.descendant(
          of: find.byType(AppSidebar),
          matching: find.text('Home'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('home note'), findsOneWidget);

      store.setActiveWorkspace(work);
      await tester.pumpAndSettle();

      // The label is gone with its workspace; the grid shows the new
      // workspace's notes rather than an empty label view.
      expect(find.text('work note'), findsOneWidget);
      expect(find.text('No notes with this label yet'), findsNothing);
      store.dispose();
    });

    testWidgets('creating one from the menu switches straight into it', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(WorkspaceMenu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New workspace'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'Trips');
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      expect(store.activeWorkspace?.name, 'Trips');
      expect(find.text('Trips'), findsWidgets);
      await tester.pump(const Duration(milliseconds: 700));
      store.dispose();
    });
  });

  test('the open workspace survives a restart', () async {
    final cache = MemoryLocalCache();
    final first = NotesStore(api: api, cache: cache, currentUserId: 'u-me');
    await first.load();
    first.setActiveWorkspace(work);
    await settle();
    first.dispose();

    // Opens straight into the cached workspace, before the network answers.
    api.failWith = Exception('offline');
    final second = NotesStore(api: api, cache: cache, currentUserId: 'u-me');
    await second.load();
    expect(second.activeWorkspaceId, work);
    second.dispose();
  });
}
