import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/state/settings_store.dart';
import 'package:skippy/widgets/board/board_column_view.dart';
import 'package:skippy/widgets/board/board_view.dart';
import 'package:skippy/widgets/board/move_to_stage_sheet.dart';

import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote;
import 'widget_test.dart' show homeApp;

Widget boardApp(NotesStore store) => MultiProvider(
  providers: [
    ChangeNotifierProvider.value(value: store),
    ChangeNotifierProvider(create: (_) => SettingsStore(api: store.api)),
  ],
  child: const MaterialApp(home: Scaffold(body: BoardView())),
);

/// Flush the store's debounce so no timers leak out of the test. A bare
/// `Future.delayed` would hang here: inside `testWidgets` only `pump` advances
/// time.
Future<void> flushTimers(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 700));
}

/// Sets the viewport, and restores it afterwards so one test's phone-sized
/// screen can't leak into the next.
Future<void> setViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  late FakeApi api;
  late NotesStore store;

  setUp(() {
    api = FakeApi();
    store = NotesStore(api: api, currentUserId: 'u-me');
    api.stages['todo'] = const Stage(
      id: 'todo',
      name: 'Todo',
      workspaceId: 'w-default',
      position: 1024,
    );
    api.stages['doing'] = const Stage(
      id: 'doing',
      name: 'Doing',
      workspaceId: 'w-default',
      position: 2048,
    );
  });

  tearDown(() => store.dispose());

  testWidgets('wide screens lay the columns out side by side', (tester) async {
    await setViewport(tester, const Size(1200, 900));
    api.notes['n1'] = serverNote('n1', title: 'card one');
    api.notes['n2'] = serverNote(
      'n2',
      title: 'card two',
    ).copyWith(stageId: 'todo');
    await store.load();
    await tester.pumpWidget(boardApp(store));
    await tester.pumpAndSettle();

    // Unassigned plus the two stages, all visible at once.
    expect(find.text('Unassigned'), findsOneWidget);
    expect(find.text('Todo'), findsOneWidget);
    expect(find.text('Doing'), findsOneWidget);
    expect(find.text('card one'), findsOneWidget);
    expect(find.text('card two'), findsOneWidget);
    await flushTimers(tester);
  });

  testWidgets('phones page through columns behind a strip', (tester) async {
    await setViewport(tester, const Size(390, 780));
    api.notes['n1'] = serverNote('n1', title: 'unplaced card');
    api.notes['n2'] = serverNote(
      'n2',
      title: 'todo card',
    ).copyWith(stageId: 'todo');
    await store.load();
    await tester.pumpWidget(boardApp(store));
    await tester.pumpAndSettle();

    // One column per page, opening on Unassigned.
    expect(find.byType(PageView), findsOneWidget);
    expect(find.text('unplaced card'), findsOneWidget);

    // Columns are narrower than the page so the neighbours peek in — what
    // makes a phone read as a board rather than as one list.
    final viewport = tester.getSize(find.byType(BoardView)).width;
    final column = tester.getSize(find.byType(BoardColumnView).first).width;
    expect(column, lessThan(viewport));

    // The strip names every column and moves between them.
    await tester.tap(find.text('Todo'));
    await tester.pumpAndSettle();
    expect(find.text('todo card'), findsOneWidget);
    await flushTimers(tester);
  });

  testWidgets('a workspace with no columns offers to build a board', (
    tester,
  ) async {
    await setViewport(tester, const Size(1200, 900));
    api.stages.clear();
    await store.load();
    await tester.pumpWidget(boardApp(store));
    await tester.pumpAndSettle();

    expect(find.textContaining('Add columns to build a board'), findsOneWidget);
    expect(find.text('Add a column'), findsOneWidget);
    await flushTimers(tester);
  });

  testWidgets('the move sheet files a card in another column', (tester) async {
    await setViewport(tester, const Size(1200, 900));
    api.notes['n1'] = serverNote('n1', title: 'card one');
    await store.load();
    await tester.pumpWidget(boardApp(store));
    await tester.pumpAndSettle();

    // Opened directly: reaching the sheet through the card's hover-revealed
    // overflow menu is the card's concern, not the board's.
    MoveToStageSheet.show(tester.element(find.byType(BoardView)), 'n1');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ListTile, 'Doing'));
    await tester.pumpAndSettle();

    expect(store.noteById('n1')!.stageId, 'doing');
    await flushTimers(tester);
  });

  /// The gesture the whole feature is for: pick a card up out of one column
  /// and drop it on another.
  testWidgets('dragging a card onto another column moves it', (tester) async {
    await setViewport(tester, const Size(1200, 900));
    api.notes['n1'] = serverNote('n1', title: 'card one');
    await store.load();
    await tester.pumpWidget(boardApp(store));
    await tester.pumpAndSettle();
    expect(store.noteById('n1')!.stageId, isNull);

    // Touch is the default test platform, so cards lift on long press (see
    // masonry's isTouchPrimaryPlatform branch).
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('card one')),
    );
    await tester.pump(const Duration(milliseconds: 400));

    // Carry it over the Doing column and let go.
    await gesture.moveTo(tester.getCenter(find.text('Doing')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(store.noteById('n1')!.stageId, 'doing');
    await flushTimers(tester);
  });

  /// A card dropped back on the column it came from is a no-op, not a write.
  testWidgets('dropping a card on its own column changes nothing', (
    tester,
  ) async {
    await setViewport(tester, const Size(1200, 900));
    api.notes['n1'] = serverNote(
      'n1',
      title: 'card one',
    ).copyWith(stageId: 'todo', stagePosition: 1024);
    await store.load();
    await tester.pumpWidget(boardApp(store));
    await tester.pumpAndSettle();
    api.log.clear();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('card one')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.moveTo(tester.getCenter(find.text('Todo')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(store.noteById('n1')!.stageId, 'todo');
    expect(api.log.where((l) => l.startsWith('patchNote')), isEmpty);
    await flushTimers(tester);
  });

  /// An empty column has no cards to lay out, so the drop target has to live
  /// on the column rather than inside its (zero-sized) masonry.
  testWidgets('an empty column still accepts a dropped card', (tester) async {
    await setViewport(tester, const Size(1200, 900));
    api.notes['n1'] = serverNote('n1', title: 'card one');
    await store.load();
    await tester.pumpWidget(boardApp(store));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('card one')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.moveTo(tester.getCenter(find.text('Drop notes here').first));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(store.noteById('n1')!.stageId, isNotNull);
    await flushTimers(tester);
  });

  /// The phone's move gesture: carry the card up to the strip rather than
  /// across pages, so nothing turns under the finger.
  testWidgets('a card dropped on a stage chip moves to that column', (
    tester,
  ) async {
    await setViewport(tester, const Size(390, 780));
    api.notes['n1'] = serverNote('n1', title: 'card one');
    await store.load();
    await tester.pumpWidget(boardApp(store));
    await tester.pumpAndSettle();

    // Todo's chip sits within the viewport at page 0; Doing's is past the
    // right edge until the strip scrolls, which is its own test below.
    final chip = tester.getCenter(find.text('Todo'));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('card one')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    // Step towards the chip: a DragTarget needs move events over it, not just
    // a release at its coordinates.
    await gesture.moveTo(Offset(chip.dx, chip.dy + 80));
    await tester.pump();
    await gesture.moveTo(chip);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(store.noteById('n1')!.stageId, 'todo');
    await flushTimers(tester);
  });

  /// A chip past the right edge cannot be dropped on, and you cannot scroll
  /// the strip while holding a card — so opening a column has to bring its
  /// chip into view.
  testWidgets('the strip scrolls the open column into view', (tester) async {
    await setViewport(tester, const Size(390, 780));
    for (var i = 0; i < 6; i++) {
      api.stages['s$i'] = Stage(
        id: 's$i',
        name: 'Column number $i',
        workspaceId: 'w-default',
        position: (i + 3) * 1024,
      );
    }
    await store.load();
    await tester.pumpWidget(boardApp(store));
    await tester.pumpAndSettle();

    // Page along to the far end of the board.
    for (var i = 0; i < 12; i++) {
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();
    }

    // The open column's chip has been scrolled back inside the viewport, so
    // it can be tapped — and dropped on.
    final viewport = tester.getSize(find.byType(BoardView)).width;
    final chip = tester.getRect(find.text('Column number 5'));
    expect(chip.right, lessThanOrEqualTo(viewport + 1));
    expect(chip.left, greaterThanOrEqualTo(-1));
    await flushTimers(tester);
  });

  /// Reordering inside a column takes the same single-patch path as a move
  /// between two, because it is a move to the stage the card is already in.
  testWidgets('dragging a card up its own column repositions it', (
    tester,
  ) async {
    await setViewport(tester, const Size(1200, 900));
    for (final (index, id) in ['a', 'b', 'c'].indexed) {
      api.notes[id] = serverNote(id, title: 'card $id').copyWith(
        stageId: 'todo',
        stagePosition: (index + 1) * 1024,
      );
    }
    await store.load();
    await tester.pumpWidget(boardApp(store));
    await tester.pumpAndSettle();
    api.log.clear();

    final target = tester.getCenter(find.text('card a'));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('card c')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    // c now sorts ahead of a, and it took one write to say so.
    expect(
      store.noteById('c')!.stagePosition,
      lessThan(store.noteById('a')!.stagePosition),
    );
    expect(store.noteById('c')!.stageId, 'todo');
    await flushTimers(tester);
    expect(api.log.where((l) => l.startsWith('patchNote')).length, 1);
  });

  /// The board has to be reachable from the app's own navigation, not just
  /// mountable in a test. The narrow drawer and the wide sidebar are separate
  /// widgets, and an entry added to one is not added to the other.
  group('reaching the board from the menus', () {
    testWidgets('from the drawer on a phone', (tester) async {
      await setViewport(tester, const Size(390, 780));
      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationDrawer), findsOneWidget);

      await tester.tap(find.widgetWithText(NavigationDrawerDestination, 'Board'));
      await tester.pumpAndSettle();
      expect(find.byType(BoardView), findsOneWidget);
      await flushTimers(tester);
    });

    testWidgets('from the sidebar on a wide screen', (tester) async {
      await setViewport(tester, const Size(1200, 900));
      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Board'));
      await tester.pumpAndSettle();
      expect(find.byType(BoardView), findsOneWidget);
      await flushTimers(tester);
    });
  });

  /// The unassigned column is capped so a mature workspace does not open onto
  /// a column holding every note it has.
  testWidgets('the unassigned column caps its preview and can expand', (
    tester,
  ) async {
    await setViewport(tester, const Size(1200, 2000));
    for (var i = 0; i < 25; i++) {
      api.notes['n$i'] = serverNote('n$i', title: 'card $i');
    }
    await store.load();
    await tester.pumpWidget(boardApp(store));
    await tester.pumpAndSettle();

    expect(find.text('Show 5 more'), findsOneWidget);
    await tester.tap(find.text('Show 5 more'));
    await tester.pumpAndSettle();
    expect(find.text('Show 5 more'), findsNothing);
    await flushTimers(tester);
  });
}
