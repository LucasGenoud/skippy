import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/screens/editor_screen.dart';
import 'package:skippy/theme.dart';
import 'package:skippy/state/settings_store.dart';
import 'package:skippy/widgets/board/board_column_view.dart';
import 'package:skippy/widgets/board/board_view.dart';
import 'package:skippy/widgets/board/move_to_stage_sheet.dart';
import 'package:skippy/util/snack.dart';
import 'package:skippy/widgets/form_dialog.dart';
import 'package:skippy/widgets/masonry.dart';
import 'package:skippy/widgets/note_card.dart';

import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote;
import 'widget_test.dart' show homeApp;

/// [theme] is only worth passing for tests that judge colour, everything else
/// reads the same under Material's default.
Widget boardApp(NotesStore store, {ThemeData? theme}) => MultiProvider(
  providers: [
    ChangeNotifierProvider.value(value: store),
    ChangeNotifierProvider(create: (_) => SettingsStore(api: store.api)),
  ],
  child: MaterialApp(
    theme: theme,
    // Notification behavior in board actions posts through this key.
    scaffoldMessengerKey: scaffoldMessengerKey,
    home: const Scaffold(body: BoardView()),
  ),
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

    // Columns are narrower than the page so the neighbours peek in, what
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

  /// Arriving in a column and choosing a place in it are one gesture: the
  /// card goes where it was let go of, not onto the end of the pile.
  group('a card crossing into a column lands where it was dropped', () {
    /// Two cards in Todo to aim between, and a loose one to carry over.
    Future<void> seed(WidgetTester tester) async {
      await setViewport(tester, const Size(1200, 900));
      api.notes['n1'] = serverNote('n1', title: 'card one');
      for (final (index, id) in ['a', 'b'].indexed) {
        api.notes[id] = serverNote(id, title: 'card $id').copyWith(
          stageId: 'todo',
          stagePosition: (index + 1) * 1024,
        );
      }
      await store.load();
      await tester.pumpWidget(boardApp(store));
      await tester.pumpAndSettle();
    }

    testWidgets('dropped at the top, it goes above them', (tester) async {
      await seed(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('card one')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      // The column's header: as high as the column goes.
      await gesture.moveTo(tester.getCenter(find.text('Todo')));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(store.noteById('n1')!.stageId, 'todo');
      expect(
        store.noteById('n1')!.stagePosition,
        lessThan(store.noteById('a')!.stagePosition),
      );
      await flushTimers(tester);
    });

    testWidgets('dropped past the last card, it goes below them', (
      tester,
    ) async {
      await seed(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('card one')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      // Empty space in the column, well under both cards.
      await gesture.moveTo(
        Offset(tester.getCenter(find.text('card b')).dx, 700),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(store.noteById('n1')!.stageId, 'todo');
      expect(
        store.noteById('n1')!.stagePosition,
        greaterThan(store.noteById('b')!.stagePosition),
      );
      await flushTimers(tester);
    });

    /// A column hears about a card moving over it even when it just refused
    /// it, so the one a card is being lifted *out* of must not open a slot for
    /// a card it already holds.
    testWidgets('the column it is leaving opens no slot for it', (
      tester,
    ) async {
      await seed(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('card a')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      // Still inside Todo, over its own neighbour.
      await gesture.moveTo(tester.getCenter(find.text('card b')));
      await tester.pump();

      final masonry = tester.widget<AnimatedMasonry>(
        find.byType(AnimatedMasonry).at(1),
      );
      expect(masonry.incomingIndex, isNull);

      await gesture.up();
      await tester.pumpAndSettle();
      await flushTimers(tester);
    });

    /// A drag drop is silent, no confirmation snack, since the card visibly
    /// gliding into place already says where it went.
    testWidgets('dropping a card raises no confirmation', (tester) async {
      await seed(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('card one')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.moveTo(tester.getCenter(find.text('Todo')));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(store.noteById('n1')!.stageId, 'todo');
      expect(find.byType(SnackBar), findsNothing);
      await flushTimers(tester);
    });
  });

  /// A card carried out of a busy column crosses its neighbours on the way,
  /// and the column reflows around it as it goes. That rearrangement must not
  /// be written: the card is leaving, and a reorder reporting it would file it
  /// straight back where it came from, undoing the drop.
  testWidgets('leaving a column does not write the shuffle on the way out', (
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

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('card c')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    // Up over its own neighbours first, this is what reflows Todo, and only
    // then across into Doing.
    await gesture.moveTo(tester.getCenter(find.text('card a')));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text('Doing')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(store.noteById('c')!.stageId, 'doing');
    await flushTimers(tester);
    // One write: the drop. Not a second one putting it back in Todo.
    expect(api.log.where((l) => l.startsWith('patchNote')).length, 1);
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
  /// the strip while holding a card, so opening a column has to bring its
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
    // it can be tapped, and dropped on.
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

  /// Pinned cards are sorted as a separate group at the top of a column. Their
  /// numeric stage positions must not be used as neighbours when an unpinned
  /// card is moved to the head of the unpinned group, or a high position on
  /// the pinned card can make the dragged card sort straight back to the end.
  testWidgets('the last card reorders below a pinned card', (tester) async {
    await setViewport(tester, const Size(1200, 900));
    api.notes['pinned'] = serverNote(
      'pinned',
      title: 'pinned card',
    ).copyWith(stageId: 'todo', stagePosition: 4096, pinned: true);
    api.notes['a'] = serverNote(
      'a',
      title: 'card a',
    ).copyWith(stageId: 'todo', stagePosition: 1024);
    api.notes['b'] = serverNote(
      'b',
      title: 'card b',
    ).copyWith(stageId: 'todo', stagePosition: 2048);
    await store.load();
    await tester.pumpWidget(boardApp(store));
    await tester.pumpAndSettle();
    api.log.clear();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('card b')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.moveTo(tester.getCenter(find.text('card a')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      store.noteById('b')!.stagePosition,
      lessThan(store.noteById('a')!.stagePosition),
    );
    await flushTimers(tester);
    expect(api.log.where((l) => l.startsWith('patchNote')).length, 1);
  });

  testWidgets('phones keep an in-column card reorder after the drop', (
    tester,
  ) async {
    await setViewport(tester, const Size(390, 780));
    for (final (index, id) in ['a', 'b', 'c'].indexed) {
      api.notes[id] = serverNote(
        id,
        title: 'card $id',
      ).copyWith(stageId: 'todo', stagePosition: (index + 1) * 1024);
    }
    await store.load();
    await tester.pumpWidget(boardApp(store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Todo'));
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

    expect(
      store.noteById('c')!.stagePosition,
      lessThan(store.noteById('a')!.stagePosition),
    );
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

  group('selection', () {
    /// Selection was dead on the board: cards were built without any of the
    /// selection props, so the top bar's action row had nothing to act on.
    testWidgets('a long press selects a card instead of lifting it', (
      tester,
    ) async {
      await setViewport(tester, const Size(1200, 900));
      api.notes['n1'] = serverNote('n1', title: 'card one');
      await store.load();

      final selected = <String>{};
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: store),
            ChangeNotifierProvider(create: (_) => SettingsStore(api: api)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => BoardView(
                  selectionMode: selected.isNotEmpty,
                  selectedIds: selected,
                  onSelectionChanged: (id, on) => setState(
                    () => on ? selected.add(id) : selected.remove(id),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Hold without moving: the grid's rule is that this selects.
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('card one')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(selected, {'n1'});
      // And the card now renders in its selected state.
      expect(
        tester.widget<NoteTile>(find.byType(NoteTile)).selected,
        isTrue,
      );
      await flushTimers(tester);
    });

    /// The point of selecting on a board: file them all at once.
    testWidgets('the sheet moves every selected note into one column', (
      tester,
    ) async {
      await setViewport(tester, const Size(1200, 900));
      api.notes['a'] = serverNote('a', title: 'card a');
      api.notes['b'] = serverNote(
        'b',
        title: 'card b',
      ).copyWith(stageId: 'todo');
      await store.load();
      await tester.pumpWidget(boardApp(store));
      await tester.pumpAndSettle();

      MoveToStageSheet.showForNotes(
        tester.element(find.byType(BoardView)),
        ['a', 'b'],
      );
      await tester.pumpAndSettle();
      expect(find.text('Move 2 notes to column'), findsOneWidget);

      await tester.tap(find.widgetWithText(ListTile, 'Doing'));
      await tester.pumpAndSettle();

      expect(store.noteById('a')!.stageId, 'doing');
      expect(store.noteById('b')!.stageId, 'doing');
      expect(find.byType(SnackBar), findsNothing);
      await flushTimers(tester);
    });
  });

  /// Semantic search bypassed the board entirely: it built its columns from a
  /// keyword match and never saw the server's ranking.
  testWidgets('semantic results filter the board, keeping stage order', (
    tester,
  ) async {
    await setViewport(tester, const Size(1200, 900));
    api.notes['hit'] = serverNote('hit', title: 'wifi password').copyWith(
      stageId: 'todo',
      stagePosition: 2048,
    );
    api.notes['also'] = serverNote('also', title: 'router notes').copyWith(
      stageId: 'todo',
      stagePosition: 1024,
    );
    api.notes['miss'] = serverNote('miss', title: 'buy milk');
    await store.load();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: store),
          ChangeNotifierProvider(create: (_) => SettingsStore(api: api)),
        ],
        child: const MaterialApp(
          home: Scaffold(
            // Ranked worst-first on purpose: the board must keep stage order
            // rather than adopt the ranking's.
            body: BoardView(rankedIds: {'hit', 'also'}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('wifi password'), findsOneWidget);
    expect(find.text('router notes'), findsOneWidget);
    expect(find.text('buy milk'), findsNothing);
    // Stage order, not rank order.
    expect(
      tester.getCenter(find.text('router notes')).dy,
      lessThan(tester.getCenter(find.text('wifi password')).dy),
    );
    await flushTimers(tester);
  });

  /// On a phone the board opens a note full-screen, which puts the card and
  /// its drag gesture out of reach, so the only way to refile a note you are
  /// reading was to close it first.
  testWidgets('a note opened from the board can be refiled from its menu', (
    tester,
  ) async {
    await setViewport(tester, const Size(390, 844));
    // Unassigned, so the card is on the page the phone board opens onto.
    api.notes['n1'] = serverNote('n1', title: 'card one');
    await store.load();
    await tester.pumpWidget(boardApp(store));
    await tester.pumpAndSettle();

    await tester.tap(find.text('card one'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Note actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to column'));
    await tester.pumpAndSettle();

    // Scoped to the sheet: the board is still mounted underneath, column names
    // and all.
    await tester.tap(
      find.descendant(
        of: find.byType(MoveToStageSheet),
        matching: find.text('Doing'),
      ),
    );
    await tester.pumpAndSettle();

    expect(store.noteById('n1')?.stageId, 'doing');
    // And the note stayed open, moving it is not a way out of the editor.
    expect(find.byType(EditorScreen), findsOneWidget);

    Navigator.of(tester.element(find.byType(EditorScreen))).pop();
    await tester.pumpAndSettle();
    scaffoldMessengerKey.currentState?.clearSnackBars();
    await flushTimers(tester);
  });

  /// A column needs its own way to start a note, or filing one there means
  /// creating it loose and moving it.
  testWidgets('the column header composes a note already in that column', (
    tester,
  ) async {
    await setViewport(tester, const Size(1200, 900));
    await store.load();
    await tester.pumpWidget(boardApp(store));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add a note to Doing'));
    await tester.pumpAndSettle();

    // The editor opens carrying the column. The draft itself stays unwritten
    // until there is content, an empty one is never persisted, so what this
    // pins is that composing here files the note in this column.
    final editor = tester.widget<EditorScreen>(find.byType(EditorScreen));
    expect(editor.stageId, 'doing');

    // Close it inside the test: the editor snacks from dispose(), and a tree
    // torn down at teardown has no messenger left for that to land in.
    Navigator.of(tester.element(find.byType(EditorScreen))).pop();
    await tester.pumpAndSettle();
    scaffoldMessengerKey.currentState?.clearSnackBars();
    await flushTimers(tester);
  });

  /// Cards were invisible on a freshly opened board: the masonry's entrance
  /// holds every tile at opacity 0 until all heights are measured, and on the
  /// board that never resolved, the column showed its count but no cards, and
  /// only a resize or a rebuild brought them back. Every other test here
  /// settles first, which is exactly why they all missed it.
  testWidgets('cards are visible on the board\'s very first frame', (
    tester,
  ) async {
    await setViewport(tester, const Size(1200, 900));
    api.notes['n1'] = serverNote('n1', title: 'card one');
    await store.load();

    await tester.pumpWidget(boardApp(store));
    // One frame only, deliberately no pumpAndSettle.
    await tester.pump();

    final faded = tester
        .widgetList<Opacity>(find.byType(Opacity))
        .where((o) => o.opacity == 0);
    expect(
      faded,
      isEmpty,
      reason: 'a board card must not be painted fully transparent',
    );
    await tester.pumpAndSettle();
    await flushTimers(tester);
  });

  /// A column on a wide board is a trough the cards sit in, so it has to read
  /// as its own surface. Light mode used to fill it with the exact colour of
  /// the scaffold, leaving nothing but a hairline to say a column was there.
  group('wide columns are set off from the canvas', () {
    for (final brightness in Brightness.values) {
      testWidgets('in ${brightness.name} mode', (tester) async {
        await setViewport(tester, const Size(1600, 900));
        await store.load();
        await tester.pumpWidget(
          boardApp(store, theme: buildTheme(brightness)),
        );
        await tester.pumpAndSettle();

        final fill =
            tester
                    .widgetList<Container>(
                      find.ancestor(
                        of: find.byType(BoardColumnView).first,
                        matching: find.byType(Container),
                      ),
                    )
                    .map((c) => c.decoration)
                    .whereType<BoxDecoration>()
                    .firstWhere((d) => d.color != null)
                    .color;
        final canvas = Theme.of(
          tester.element(find.byType(BoardView)),
        ).scaffoldBackgroundColor;

        expect(fill, isNot(canvas));
        await flushTimers(tester);
      });
    }
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

  /// The empty state's "Add a column" button vanishes with the first stage, so
  /// a board that already has columns needs its own way to the editor. Every
  /// other test here starts from a board that is already set up and so never
  /// asked whether a second column could be added at all.
  group('adding a column to a board that already has some', () {
    /// Walks the two dialogs: pick "Add column", name it, confirm, close.
    Future<void> addColumnNamed(WidgetTester tester, String name) async {
      expect(find.text('Edit columns'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(FormDialog),
          matching: find.text('Add column'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), name);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
    }

    testWidgets('from the tile at the end of a wide board', (tester) async {
      await setViewport(tester, const Size(1600, 900));
      await store.load();
      await tester.pumpWidget(boardApp(store));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add column'));
      await tester.pumpAndSettle();
      await addColumnNamed(tester, 'Blocked');

      expect(store.stages.map((stage) => stage.name), contains('Blocked'));
      // And the board grew a column, not just the store a stage.
      expect(find.text('Blocked'), findsOneWidget);
      await flushTimers(tester);
    });

    testWidgets('from the trailing chip in the phone strip', (tester) async {
      await setViewport(tester, const Size(390, 780));
      await store.load();
      await tester.pumpWidget(boardApp(store));
      await tester.pumpAndSettle();

      // The chip sits past the last column, off the end of a phone strip.
      await tester.drag(find.text('Todo'), const Offset(-240, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add column'));
      await tester.pumpAndSettle();
      await addColumnNamed(tester, 'Blocked');

      expect(store.stages.map((stage) => stage.name), contains('Blocked'));
      expect(find.text('Blocked'), findsOneWidget);
      await flushTimers(tester);
    });
  });
}
