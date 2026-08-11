import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/api/api_client.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/models/workspace.dart';
import 'package:skippy/screens/workspace_settings_screen.dart';
import 'package:skippy/screens/workspace_stats_screen.dart';
import 'package:skippy/state/local_cache.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/state/settings_store.dart';
import 'package:skippy/theme.dart';
import 'package:skippy/widgets/app_drawer.dart';
import 'package:skippy/widgets/board/board_view.dart';
import 'package:skippy/widgets/workspace_menu.dart';

import 'fake_api.dart';
import 'widget_test.dart' show homeApp;

Note noteIn(
  String workspaceId,
  String id, {
  String title = '',
  Set<String> labelIds = const {},
  bool trashed = false,
  bool pinned = false,
  UserRef? owner,
  List<UserRef> collaborators = const [],
}) => Note(
  id: id,
  workspaceId: workspaceId,
  title: title,
  labelIds: labelIds,
  trashed: trashed,
  pinned: pinned,
  createdAt: DateTime.now(),
  updatedAt: DateTime.now(),
  owner: owner ?? const UserRef(id: 'u-me', name: 'me'),
  collaborators: collaborators,
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
      expect(store.notesFor(ViewSelection.notes, '').others.map((n) => n.id), [
        'a',
      ]);

      store.setActiveWorkspace(work);
      expect(store.notesFor(ViewSelection.notes, '').others.map((n) => n.id), [
        'b',
      ]);
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

      expect(store.notesFor(ViewSelection.notes, '').others.map((n) => n.id), [
        's',
      ]);
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

    test(
      'workspace views are enabled by default and update optimistically',
      () async {
        await store.load();
        expect(store.workspaceById(work)?.notesEnabled, isTrue);
        expect(store.workspaceById(work)?.boardEnabled, isTrue);

        store.updateWorkspaceViews(
          id: work,
          notesEnabled: false,
          boardEnabled: true,
        );
        expect(store.workspaceById(work)?.notesEnabled, isFalse);
        expect(store.workspaceById(work)?.boardEnabled, isTrue);
        await settle();
        expect(api.workspaces[work]?.notesEnabled, isFalse);
        expect(api.workspaces[work]?.boardEnabled, isTrue);
      },
    );

    test('the default workspace cannot be deleted', () async {
      await store.load();
      expect(store.canDeleteWorkspace('w-default'), isFalse);
      store.deleteWorkspace('w-default');
      expect(store.workspaceById('w-default'), isNotNull);
    });

    test('deleting one permanently removes all of its notes', () async {
      api.labels['l2'] = const Label(
        id: 'l2',
        workspaceId: work,
        name: 'Urgent',
      );
      api.notes['b'] = noteIn(
        work,
        'b',
        title: 'job',
        labelIds: {'l2'},
        pinned: true,
      );
      api.notes['c'] = noteIn(
        work,
        'c',
        title: 'theirs',
        owner: const UserRef(id: 'u-ada', name: 'Ada'),
      );
      api.notes['d'] = noteIn(
        work,
        'd',
        title: 'shared directly',
        labelIds: {'l2'},
        owner: const UserRef(id: 'u-ada', name: 'Ada'),
        collaborators: const [UserRef(id: 'u-me', name: 'Me Example')],
      );
      await store.load();
      store.setActiveWorkspace(work);

      store.deleteWorkspace(work);

      expect(store.workspaceById(work), isNull);
      // The view falls back to the default workspace rather than stranding.
      expect(store.activeWorkspaceId, 'w-default');
      expect(store.noteById('b'), isNull);
      expect(store.noteById('c'), isNull);
      expect(store.noteById('d'), isNull);
      final homeSections = store.notesFor(ViewSelection.notes, '');
      expect([...homeSections.pinned, ...homeSections.others], isEmpty);
      expect(store.labels, isEmpty);

      await settle();
      expect(api.workspaces.containsKey(work), isFalse);
      expect(api.notes.containsKey('b'), isFalse);
      expect(api.notes.containsKey('c'), isFalse);
      expect(api.notes.containsKey('d'), isFalse);
    });

    test(
      'leaving keeps notes in the workspace and retains direct shares',
      () async {
        api.workspaces[work] = const Workspace(
          id: work,
          name: 'Work',
          owner: UserRef(id: 'u-ada', name: 'Ada'),
          members: [UserRef(id: 'u-me', name: 'Me Example')],
        );
        api.notes['b'] = noteIn(
          work,
          'b',
          title: 'workspace note',
          owner: const UserRef(id: 'u-ada', name: 'Ada'),
        );
        api.notes['c'] = noteIn(
          work,
          'c',
          title: 'shared directly too',
          owner: const UserRef(id: 'u-ada', name: 'Ada'),
          collaborators: const [UserRef(id: 'u-me', name: 'Me Example')],
        );
        await store.load();

        expect(
          store.canDeleteWorkspace(work),
          isFalse,
          reason: 'not the owner',
        );
        store.leaveWorkspace(work);

        expect(store.workspaceById(work), isNull);
        expect(store.noteById('b'), isNull);
        expect(store.noteById('c')?.workspaceId, work);
        expect(
          store.notesFor(ViewSelection.notes, '').others.map((note) => note.id),
          contains('c'),
        );
        await settle();
        expect(api.workspaces[work]?.members, isEmpty);
        // Leaving changes access, not ownership or placement. Both rows remain
        // in the workspace on the server; only the direct share stays visible.
        expect(api.notes['b']?.workspaceId, work);
        expect(api.notes['c']?.workspaceId, work);
      },
    );

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

    testWidgets('the tick moves to the new workspace as the menu dismisses', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // The name of the row the tick currently sits in.
      String ticked() {
        final row = find.ancestor(
          of: find.byIcon(Icons.check),
          matching: find.byType(PopupMenuItem<String>),
        );
        return tester
            .widget<Text>(
              find.descendant(of: row, matching: find.byType(Text)).first,
            )
            .data!;
      }

      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(WorkspaceMenu));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(ticked(), 'My notes');

      await tester.tap(
        find.ancestor(
          of: find.text('Work'),
          matching: find.byType(PopupMenuItem<String>),
        ),
      );
      // A frame into the dismiss, while the menu is still on screen, the
      // tick has already moved, and there is still only ever one of it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.byType(PopupMenuItem<String>), findsWidgets);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(ticked(), 'Work');

      await tester.pumpAndSettle();
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
      api.notes['a'] = noteIn(
        'w-default',
        'a',
        title: 'home note',
        labelIds: {'l1'},
      );
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

    testWidgets(
      'disabled workspace views disappear and the open view falls back',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        api.workspaces[work] = const Workspace(
          id: work,
          name: 'Work',
          notesEnabled: false,
          owner: UserRef(id: 'u-me', name: 'Me Example'),
        );
        api.notes['b'] = noteIn(work, 'b', title: 'board only');
        await store.load();
        await tester.pumpWidget(homeApp(store));
        await tester.pumpAndSettle();

        store.setActiveWorkspace(work);
        await tester.pumpAndSettle();

        final sidebar = find.byType(AppSidebar);
        expect(
          find.descendant(of: sidebar, matching: find.text('Notes')),
          findsNothing,
        );
        expect(
          find.descendant(of: sidebar, matching: find.text('Board')),
          findsOneWidget,
        );
        expect(find.byType(BoardView), findsOneWidget);
        store.dispose();
      },
    );

    testWidgets('each workspace reopens its own last view', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();

      final sidebar = find.byType(AppSidebar);
      await tester.tap(
        find.descendant(of: sidebar, matching: find.text('Board')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BoardView), findsOneWidget);

      // An unseen workspace inherits the current destination.
      store.setActiveWorkspace(work);
      await tester.pumpAndSettle();
      expect(find.byType(BoardView), findsOneWidget);

      await tester.tap(
        find.descendant(of: sidebar, matching: find.text('Notes')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BoardView), findsNothing);

      store.setActiveWorkspace('w-default');
      await tester.pumpAndSettle();
      expect(find.byType(BoardView), findsOneWidget);

      store.setActiveWorkspace(work);
      await tester.pumpAndSettle();
      expect(find.byType(BoardView), findsNothing);
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

    testWidgets('phone drawer closes before its workspace form opens', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationDrawer), findsOneWidget);

      await tester.tap(find.byType(WorkspaceMenu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New workspace'));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationDrawer), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.widgetWithText(AppBar, 'New workspace'), findsOneWidget);

      // The form used to overlap the closing drawer route and could disappear
      // again immediately. It must still be the active page after both
      // animations would have finished.
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.widgetWithText(AppBar, 'New workspace'), findsOneWidget);
      store.dispose();
    });
  });

  group('delete confirmation', () {
    testWidgets('the Delete button stays off until the name matches', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      api.notes['a'] = noteIn(work, 'a', title: 'work note');
      await store.load();
      store.setActiveWorkspace(work);
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(WorkspaceMenu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Workspace settings'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Delete workspace'));
      await tester.pumpAndSettle();

      expect(find.text('Delete "Work"?'), findsOneWidget);
      expect(
        find.text(
          '1 note and all its attachments will be permanently deleted. '
          'This can\'t be undone.',
        ),
        findsOneWidget,
      );
      // The settings page's own invite field is still mounted underneath, so
      // scope to the confirm dialog rather than grabbing the wrong TextField.
      final confirmDialog = find.ancestor(
        of: find.text('Delete "Work"?'),
        matching: find.byType(AlertDialog),
      );
      final nameField = find.descendant(
        of: confirmDialog,
        matching: find.byType(TextField),
      );
      final deleteButton = find.widgetWithText(FilledButton, 'Delete');
      expect(tester.widget<FilledButton>(deleteButton).onPressed, isNull);

      await tester.enterText(nameField, 'wrong name');
      await tester.pump();
      expect(tester.widget<FilledButton>(deleteButton).onPressed, isNull);

      await tester.enterText(nameField, 'Work');
      await tester.pump();
      expect(tester.widget<FilledButton>(deleteButton).onPressed, isNotNull);

      await tester.tap(deleteButton);
      await tester.pumpAndSettle();

      expect(store.workspaceById(work), isNull);
      expect(store.noteById('a'), isNull);
      store.dispose();
    });
  });

  group('workspace settings', () {
    /// Open the workspace settings page for the workspace the switcher shows.
    Future<void> openSettings(WidgetTester tester, NotesStore store) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(WorkspaceMenu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Workspace settings'));
      await tester.pumpAndSettle();
    }

    testWidgets('the page carries the views, roster, and a stats summary', (
      tester,
    ) async {
      api.workspaces[work] = const Workspace(
        id: work,
        name: 'Work',
        owner: UserRef(id: 'u-me', name: 'Me Example'),
        members: [UserRef(id: 'u-ada', name: 'Ada')],
      );
      api.notes['a'] = noteIn(work, 'a', title: 'work note');
      api.notes['b'] = noteIn(work, 'b', title: 'other note');
      api.notes['gone'] = noteIn(work, 'gone', title: 'binned', trashed: true);
      api.labels['l1'] = const Label(id: 'l1', name: 'urgent', workspaceId: work);
      await store.load();
      store.setActiveWorkspace(work);
      await openSettings(tester, store);

      expect(find.widgetWithText(AppBar, 'Work'), findsOneWidget);
      expect(find.text('Owned by you'), findsOneWidget);
      expect(find.widgetWithText(SwitchListTile, 'Notes'), findsOneWidget);
      expect(find.widgetWithText(SwitchListTile, 'Board'), findsOneWidget);
      expect(find.text('Ada'), findsOneWidget);
      // The summary counts live notes only, and agrees with the grid.
      expect(find.text('2 notes · 1 label'), findsOneWidget);
      store.dispose();
    });

    testWidgets('a member sees no owner controls and can leave', (
      tester,
    ) async {
      api.workspaces[work] = const Workspace(
        id: work,
        name: 'Work',
        owner: UserRef(id: 'u-ada', name: 'Ada'),
        members: [UserRef(id: 'u-me', name: 'Me Example')],
      );
      await store.load();
      store.setActiveWorkspace(work);
      await openSettings(tester, store);

      expect(find.text('Owned by Ada'), findsOneWidget);
      // View switches are the owner's to change.
      final notesSwitch = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Notes'),
      );
      expect(notesSwitch.onChanged, isNull);
      expect(find.text('Only the owner can change workspace views.'),
          findsOneWidget);
      expect(find.text('Invite people by email'), findsNothing);
      // Leaving, not deleting: the notes are not this member's to remove.
      expect(find.text('Delete workspace'), findsNothing);

      await tester.tap(find.text('Leave workspace'));
      await tester.pumpAndSettle();
      expect(store.workspaceById(work), isNull);
      store.dispose();
    });

    testWidgets('the default workspace offers neither delete nor leave', (
      tester,
    ) async {
      await store.load();
      await openSettings(tester, store);

      expect(find.text('Your default workspace'), findsOneWidget);
      expect(find.text('Delete workspace'), findsNothing);
      expect(find.text('Leave workspace'), findsNothing);
      store.dispose();
    });

    testWidgets('statistics counts what the workspace holds', (tester) async {
      final now = DateTime.now();
      api.notes['a'] = noteIn(work, 'a', title: 'one');
      api.notes['b'] = noteIn(work, 'b', title: 'two', pinned: true);
      api.notes['t'] = noteIn(work, 't', title: 'binned', trashed: true);
      api.notes['c'] = Note(
        id: 'c',
        workspaceId: work,
        kind: NoteKind.checklist,
        items: const [
          ChecklistItem(id: 'i1', text: 'milk', done: true),
          ChecklistItem(id: 'i2', text: 'eggs'),
        ],
        createdAt: now,
        updatedAt: now,
        owner: const UserRef(id: 'u-me', name: 'me'),
      );
      // A note in another workspace must not be counted here.
      api.notes['elsewhere'] = noteIn('w-default', 'elsewhere', title: 'nope');
      await store.load();
      store.setActiveWorkspace(work);
      await openSettings(tester, store);

      await tester.tap(find.text('Statistics'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, 'Statistics'), findsOneWidget);
      // Three live notes, one in the trash, counted separately.
      expect(find.text('Notes'), findsOneWidget);
      expect(find.text('In trash'), findsOneWidget);
      expect(find.text('1 of 2 items ticked'), findsOneWidget);
      expect(find.text('Checklists'), findsWidgets);
      store.dispose();
    });

    /// Phone, tablet, and desktop, in both themes. A layout that overflows
    /// throws here, which is what stands in for eyeballing the page at every
    /// size: the month bars in particular are laid out against whatever the
    /// labels leave, and a fixed-height chart hid an overflow once already.
    testWidgets('both pages lay out at every width and in the dark', (
      tester,
    ) async {
      final now = DateTime.now();
      for (var i = 0; i < 14; i++) {
        api.notes['n$i'] = Note(
          id: 'n$i',
          workspaceId: work,
          title: 'Note number $i with a title long enough to need wrapping',
          kind: i.isEven ? NoteKind.text : NoteKind.checklist,
          items: i.isOdd
              ? [
                  ChecklistItem(id: 'a$i', text: 'first', done: i % 3 == 0),
                  ChecklistItem(id: 'b$i', text: 'second'),
                ]
              : const [],
          labelIds: {'l1'},
          stageId: i % 3 == 0 ? 's1' : null,
          attachments: const [
            Attachment(id: 'f', mime: 'image/png', size: 4096),
          ],
          reminderAt: i == 2 ? now : null,
          createdAt: DateTime(now.year, now.month - (i % 12), 1 + (i % 27)),
          updatedAt: now,
          owner: i.isEven
              ? const UserRef(id: 'u-me', name: 'Me Example')
              : const UserRef(id: 'u-ada', name: 'Ada Lovelace'),
        );
      }
      api.labels['l1'] = const Label(
        id: 'l1',
        name: 'a label with a fairly long name',
        workspaceId: work,
      );
      api.stages['s1'] = const Stage(id: 's1', name: 'Doing', workspaceId: work);
      await store.load();
      store.setActiveWorkspace(work);

      for (final size in const [
        Size(390, 844), // phone
        Size(834, 1112), // tablet
        Size(1440, 900), // desktop
      ]) {
        for (final brightness in Brightness.values) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              theme: buildTheme(brightness),
              home: MultiProvider(
                providers: [
                  ChangeNotifierProvider.value(value: store),
                  ChangeNotifierProvider(
                    create: (_) => SettingsStore(api: api),
                  ),
                ],
                child: WorkspaceStatsScreen(workspaceId: work),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'stats overflowed at $size in $brightness',
          );
          expect(find.text('Notes'), findsWidgets);

          await tester.pumpWidget(
            MaterialApp(
              theme: buildTheme(brightness),
              home: MultiProvider(
                providers: [
                  ChangeNotifierProvider.value(value: store),
                  ChangeNotifierProvider(
                    create: (_) => SettingsStore(api: api),
                  ),
                ],
                child: WorkspaceSettingsScreen(workspaceId: work),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'settings overflowed at $size in $brightness',
          );
        }
      }
      store.dispose();
    });

    testWidgets('statistics says so when there is nothing to count', (
      tester,
    ) async {
      await store.load();
      store.setActiveWorkspace(work);
      await openSettings(tester, store);

      expect(find.text('0 notes · 0 labels'), findsOneWidget);
      await tester.tap(find.text('Statistics'));
      await tester.pumpAndSettle();

      expect(
        find.text('Nothing to count yet. Add a note and come back.'),
        findsOneWidget,
      );
      store.dispose();
    });
  });

  test('the open workspace and its view survive a restart', () async {
    final cache = MemoryLocalCache();
    final first = NotesStore(api: api, cache: cache, currentUserId: 'u-me');
    await first.load();
    first.setActiveWorkspace(work);
    first.rememberWorkspaceView(ViewSelection.board);
    await settle();
    first.dispose();

    // Opens straight into the cached workspace, before the network answers.
    api.failWith = Exception('offline');
    final second = NotesStore(api: api, cache: cache, currentUserId: 'u-me');
    await second.load();
    expect(second.activeWorkspaceId, work);
    expect(second.lastWorkspaceView(work), ViewSelection.board);
    second.dispose();
  });
}
