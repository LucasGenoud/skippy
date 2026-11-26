import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/screens/history_screen.dart';
import 'package:skippy/screens/workspace_settings_screen.dart';
import 'package:skippy/screens/workspace_stats_screen.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/models/collection.dart';
import 'package:skippy/state/settings_store.dart';
import 'package:skippy/widgets/move_note_sheet.dart';
import 'package:skippy/widgets/public_link_dialog.dart';
import 'package:skippy/widgets/share_dialog.dart';
import 'package:skippy/widgets/user_avatar.dart';

import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote;
import 'widget_test.dart' show homeApp, flushTimers;

/// Left edge of [text] on screen.
double _left(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text).first).dx;

/// Centre of the icon leading the list row titled [title].
double _iconCentre(WidgetTester tester, String title) => tester
    .getCenter(
      find
          .descendant(
            of: find.widgetWithText(ListTile, title),
            matching: find.byType(Icon),
          )
          .first,
    )
    .dx;

void main() {
  late NotesStore store;

  setUp(() => store = NotesStore(api: FakeApi(), currentUserId: 'u-me'));
  tearDown(() => store.dispose());

  // The search field stops growing at its widest; the room it leaves must
  // not end up past the actions, stranding them short of the edge.
  testWidgets('on a wide window the top bar actions reach its end', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await store.load();
    await tester.pumpWidget(homeApp(store));
    await tester.pumpAndSettle();

    final avatar = tester.getRect(find.byType(UserAvatar).first);
    expect(1800 - avatar.right, lessThanOrEqualTo(24));
    await flushTimers(tester);
  });

  // People are listed among icon rows: a name, a field's text and a row's
  // title start on one line, and the field's icon sits on the icon column.
  testWidgets('workspace people line up with the rows around them', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await store.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: store),
          ChangeNotifierProvider(create: (_) => SettingsStore(api: store.api)),
        ],
        child: const MaterialApp(
          home: WorkspaceSettingsScreen(workspaceId: 'w-default'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final title = _left(tester, 'Duplicate workspace');
    expect(_left(tester, 'You'), moreOrLessEquals(title, epsilon: 1));
    expect(
      _left(tester, 'Invite people by email'),
      moreOrLessEquals(title, epsilon: 1),
    );
    expect(
      tester.getCenter(find.byIcon(Icons.person_add_alt)).dx,
      moreOrLessEquals(_iconCentre(tester, 'Duplicate workspace'), epsilon: 1),
    );
  });

  testWidgets('the share dialog lines its rows up the same way', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = store.api as FakeApi;
    api.notes['n'] = serverNote('n', title: 'Plan', workspaceId: 'w-default');
    await store.load();
    await tester.pumpWidget(homeApp(store));
    await tester.pumpAndSettle();
    ShareDialog.show(tester.element(find.text('Plan').first), 'n');
    await tester.pumpAndSettle();

    final title = _left(tester, 'Public link');
    expect(_left(tester, 'Owner'), moreOrLessEquals(title, epsilon: 1));
    expect(
      _left(tester, 'Add people by email'),
      moreOrLessEquals(title, epsilon: 1),
    );
    expect(
      tester.getCenter(find.byIcon(Icons.person_add_alt)).dx,
      moreOrLessEquals(_iconCentre(tester, 'Public link'), epsilon: 1),
    );
    await flushTimers(tester);
  });

  // Every section of the sidebar opens the same distance below the divider
  // before it, and the dividers span exactly the width of a row's highlight.
  testWidgets('sidebar sections keep one rhythm', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await store.load();
    store.createLabel('Home');
    await tester.pumpWidget(homeApp(store));
    await tester.pumpAndSettle();

    final dividers = tester
        .widgetList<Divider>(find.byType(Divider))
        .where((d) => d.indent != null)
        .toList();
    expect(dividers.map((d) => d.height).toSet(), hasLength(1));

    final highlight = tester.getRect(
      find
          .ancestor(of: find.text('General'), matching: find.byType(InkWell))
          .first,
    );
    final rule = tester.getRect(
      find.byWidgetPredicate((w) => w is Divider && w.indent != null).first,
    );
    expect(rule.left + dividers.first.indent!, highlight.left);
    expect(rule.right - dividers.first.endIndent!, highlight.right);
    await flushTimers(tester);
  });

  // A sheet's rows start where its title does, like a dialog's body.
  testWidgets('the move sheet lines its rows up with its title', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = store.api as FakeApi;
    api.workspaces['w-default'] = api.workspaces['w-default']!.copyWith(
      collections: const [
        NoteCollection(
          id: 'w-default-general',
          workspaceId: 'w-default',
          name: 'General',
        ),
        NoteCollection(
          id: 'reading',
          workspaceId: 'w-default',
          name: 'Reading',
        ),
      ],
    );
    api.notes['n'] = serverNote(
      'n',
      title: 'Plan',
      workspaceId: 'w-default',
    ).copyWith(collectionId: 'w-default-general');
    await store.load();
    await tester.pumpWidget(homeApp(store));
    await tester.pumpAndSettle();
    MoveNoteSheet.show(
      tester.element(find.byType(Scaffold).first),
      'n',
      targets: const [NoteMoveTarget.collection, NoteMoveTarget.workspace],
    );
    await tester.pumpAndSettle();

    final title = _left(tester, 'Move to');
    final row = tester.getTopLeft(
      find
          .descendant(
            of: find.widgetWithText(ListTile, 'Reading'),
            matching: find.byType(Icon),
          )
          .first,
    );
    expect(row.dx, moreOrLessEquals(title, epsilon: 1));
    await flushTimers(tester);
  });

  // On a phone the tiles share the row evenly instead of leaving a ragged
  // gap, and the workspace's name sits under the title it qualifies.
  testWidgets('statistics fill the width and line up their header', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    (store.api as FakeApi).notes['n'] = serverNote(
      'n',
      title: 'Plan',
      workspaceId: 'w-default',
    );
    await store.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: store),
          ChangeNotifierProvider(create: (_) => SettingsStore(api: store.api)),
        ],
        child: const MaterialApp(home: Scaffold(body: SizedBox())),
      ),
    );
    Navigator.of(
      tester.element(find.byType(Scaffold)),
    ).push(WorkspaceStatsScreen.route('w-default'));
    await tester.pumpAndSettle();

    Rect tile(String label) => tester.getRect(
      find
          .ancestor(of: find.text(label), matching: find.byType(Container))
          .first,
    );
    final content = tester.getRect(find.byType(Divider).first);
    expect(tile('Archived').right, moreOrLessEquals(content.right, epsilon: 1));
    expect(
      _left(tester, 'My notes'),
      moreOrLessEquals(_left(tester, 'Statistics'), epsilon: 1),
    );
    await flushTimers(tester);
  });

  // Restore ends on the card's content edge, where Current sits.
  testWidgets('history lines Restore up with the Current badge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = store.api as FakeApi;
    api.notes['b'] = serverNote('b', title: 'Trip', workspaceId: 'w-default');
    final now = DateTime.now();
    api.versions['b'] = [
      for (final (id, age) in [('v2', 1), ('v1', 24)])
        NoteVersion(
          id: id,
          noteId: 'b',
          kind: NoteKind.text,
          title: 'Trip',
          content: id,
          items: const [],
          createdAt: now.subtract(Duration(hours: age)),
        ),
    ];
    await store.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: store),
          ChangeNotifierProvider(create: (_) => SettingsStore(api: store.api)),
        ],
        child: const MaterialApp(home: NoteHistoryScreen(noteId: 'b')),
      ),
    );
    await tester.pumpAndSettle();

    final current = tester
        .getRect(
          find
              .ancestor(
                of: find.text('Current'),
                matching: find.byType(Container),
              )
              .first,
        )
        .right;
    final restore = tester.getRect(find.text('Restore').first).right;
    expect(restore, moreOrLessEquals(current, epsilon: 1));
    await flushTimers(tester);
  });

  // A dialog's buttons end on the content edge, filled or not, the same as a
  // sheet's footer does.
  testWidgets('dialog actions end on the content edge', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await store.load();
    await tester.pumpWidget(homeApp(store));
    await tester.pumpAndSettle();
    PublicLinkDialog.show(
      tester.element(find.byType(Scaffold).first),
      target: PublicLinkTarget.note('n', 'Plan'),
      api: store.api,
    );
    await tester.pumpAndSettle();

    final field = tester.getRect(
      find
          .descendant(
            of: find.byType(Dialog),
            matching: find.byType(InputDecorator),
          )
          .first,
    );
    final create = tester.getRect(
      find.ancestor(
        of: find.text('Create link'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(create.right, moreOrLessEquals(field.right, epsilon: 1));
    await flushTimers(tester);
  });

  // "+N more" under a card's checklist starts where the items' text does.
  testWidgets('a card checklist lines its overflow up with its items', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    (store.api as FakeApi).notes['c'] = serverNote(
      'c',
      title: 'Long list',
      kind: NoteKind.checklist,
      workspaceId: 'w-default',
      items: [
        for (var i = 0; i < 40; i++) ChecklistItem(id: '$i', text: 'Item $i'),
      ],
    );
    await store.load();
    await tester.pumpWidget(homeApp(store));
    await tester.pumpAndSettle();

    final more = tester.getTopLeft(
      find.textContaining('more', findRichText: true).first,
    );
    final item = tester.getTopLeft(
      find.text('Item 0', findRichText: true).first,
    );
    expect(more.dx, moreOrLessEquals(item.dx, epsilon: 0.5));
    await flushTimers(tester);
  });

  // A roster's remove buttons and the invite row's send button share one
  // trailing column.
  testWidgets('share dialog trailing buttons share a column', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    (store.api as FakeApi).notes['n'] = serverNote(
      'n',
      title: 'Plan',
      workspaceId: 'w-default',
      collaborators: const [UserRef(id: 'u-ada', name: 'Ada')],
    );
    await store.load();
    await tester.pumpWidget(homeApp(store));
    await tester.pumpAndSettle();
    ShareDialog.show(tester.element(find.byType(Scaffold).first), 'n');
    await tester.pumpAndSettle();

    final remove = tester.getCenter(find.byIcon(Icons.close).last).dx;
    final send = tester.getCenter(find.byIcon(Icons.send)).dx;
    expect(send, moreOrLessEquals(remove, epsilon: 1));
    await flushTimers(tester);
  });

  testWidgets('workspace roster trailing buttons share a column', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = store.api as FakeApi;
    api.workspaces['w-default'] = api.workspaces['w-default']!.copyWith(
      members: const [UserRef(id: 'u-ada', name: 'Ada')],
    );
    await store.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: store),
          ChangeNotifierProvider(create: (_) => SettingsStore(api: store.api)),
        ],
        child: const MaterialApp(
          home: WorkspaceSettingsScreen(workspaceId: 'w-default'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final remove = tester.getCenter(find.byIcon(Icons.close).first).dx;
    final send = tester.getCenter(find.byIcon(Icons.send)).dx;
    expect(send, moreOrLessEquals(remove, epsilon: 1));
  });
}
