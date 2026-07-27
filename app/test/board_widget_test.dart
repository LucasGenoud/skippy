import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/state/settings_store.dart';
import 'package:skippy/widgets/board/board_view.dart';
import 'package:skippy/widgets/board/move_to_stage_sheet.dart';

import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote;

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

    // One column at a time: the first page is Unassigned.
    expect(find.byType(PageView), findsOneWidget);
    expect(find.text('unplaced card'), findsOneWidget);
    expect(find.text('todo card'), findsNothing);

    // The strip names every column and moves between them.
    await tester.tap(find.text('Todo'));
    await tester.pumpAndSettle();
    expect(find.text('todo card'), findsOneWidget);
    expect(find.text('unplaced card'), findsNothing);
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
