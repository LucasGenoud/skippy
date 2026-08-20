import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/state/link_preview_cache.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/state/settings_store.dart';
import 'package:skippy/util/snack.dart';
import 'package:skippy/widgets/masonry.dart';
import 'package:skippy/widgets/note_card.dart';

import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote;
import 'widget_test.dart' show flushTimers;

/// The shared harness with the notifications key attached: archiving posts an
/// Undo through it, and this is the gesture's whole safety net.
Widget phoneApp(NotesStore store, Widget child) => MultiProvider(
  providers: [
    ChangeNotifierProvider.value(value: store),
    ChangeNotifierProvider(create: (_) => SettingsStore(api: store.api)),
    Provider(create: (_) => LinkPreviewCache(api: store.api)),
  ],
  child: MaterialApp(
    scaffoldMessengerKey: scaffoldMessengerKey,
    home: Scaffold(body: child),
  ),
);

/// Archiving from the phone.
///
/// The card's action row is a mouse affordance — it appears on hover, and is
/// not built at all on touch — which left the phone reaching the archive
/// through a long press and a menu. A swipe either way does it in one gesture.
void main() {
  late FakeApi api;
  late NotesStore store;

  setUp(() {
    api = FakeApi();
    store = NotesStore(api: api, currentUserId: 'u-me');
  });
  tearDown(() => store.dispose());

  /// The touch platforms the gesture is for. Set through a variant rather than
  /// by hand: the framework restores it before it checks that no test left a
  /// foundation debug variable set.
  final phone = TargetPlatformVariant.only(TargetPlatform.android);

  /// One card, sized like a column of the phone's two-column grid, so its
  /// commit distance is 63px (35% of 180).
  Future<void> pumpCard(
    WidgetTester tester, {
    bool archived = false,
    bool trashed = false,
    bool selectionMode = false,
    bool swipeToArchive = true,
  }) async {
    api.notes['n1'] = serverNote(
      'n1',
      title: 'Groceries',
      archived: archived,
      trashed: trashed,
    );
    await store.refresh();
    await tester.pumpWidget(
      phoneApp(
        store,
        Center(
          child: SizedBox(
            width: 180,
            child: NoteTile(
              note: store.noteById('n1')!,
              selectionMode: selectionMode,
              swipeToArchive: swipeToArchive,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Puts a finger on the card and moves it [dx] across, in two hops: the
  /// first claims the gesture (the recognizer swallows the touch slop before
  /// it reports anything), the second is the travel the card sees.
  Future<TestGesture> beginSwipe(WidgetTester tester, double dx) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(NoteTile).first),
    );
    await gesture.moveBy(Offset(dx.sign * kDragSlopDefault, 0));
    await gesture.moveBy(Offset(dx, 0));
    await tester.pump();
    return gesture;
  }

  Future<void> swipe(WidgetTester tester, double dx) async {
    final gesture = await beginSwipe(tester, dx);
    await gesture.up();
    await tester.pumpAndSettle();
  }

  group('swipe to archive', () {
    testWidgets('archives on a swipe in either direction', (tester) async {
      for (final dx in [140.0, -140.0]) {
        await pumpCard(tester);
        expect(store.noteById('n1')!.archived, isFalse);

        await swipe(tester, dx);

        expect(
          store.noteById('n1')!.archived,
          isTrue,
          reason: 'swiping ${dx > 0 ? 'right' : 'left'} should archive',
        );
        await flushTimers(tester);
      }
    }, variant: phone);

    testWidgets('a short drag follows the finger and then springs back', (
      tester,
    ) async {
      await pumpCard(tester);
      final home = tester.getTopLeft(find.text('Groceries'));

      final gesture = await beginSwipe(tester, 40);
      expect(
        tester.getTopLeft(find.text('Groceries')).dx,
        greaterThan(home.dx),
        reason: 'the card should track the finger',
      );

      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Groceries')), home);
      expect(store.noteById('n1')!.archived, isFalse);
    }, variant: phone);

    testWidgets('a flick commits from short of the threshold', (tester) async {
      await pumpCard(tester);

      // 60px of travel, of which the recognizer keeps 40 after the slop: well
      // short of the 63 a slow drag would need, but thrown hard enough that
      // stopping the card there would feel like it stuck.
      await tester.fling(find.byType(NoteTile), const Offset(60, 0), 1200);
      await tester.pumpAndSettle();

      expect(store.noteById('n1')!.archived, isTrue);
      await flushTimers(tester);
    }, variant: phone);

    testWidgets('an archived note swipes back out of the archive', (
      tester,
    ) async {
      await pumpCard(tester, archived: true);

      await swipe(tester, 140);

      expect(store.noteById('n1')!.archived, isFalse);
      await flushTimers(tester);
    }, variant: phone);

    testWidgets('a card the view keeps comes back to its slot', (tester) async {
      // Most views drop the note as it is archived and the card goes with it.
      // A label view lists its archived notes, so there the card stays, and it
      // must not be left parked off its slot.
      await pumpCard(tester);
      final home = tester.getTopLeft(find.text('Groceries'));

      await swipe(tester, 140);

      expect(store.noteById('n1')!.archived, isTrue);
      expect(tester.getTopLeft(find.text('Groceries')), home);
      await flushTimers(tester);
    }, variant: phone);

    testWidgets('the gesture posts the same undoable notification the menu '
        'does', (tester) async {
      await pumpCard(tester);

      await swipe(tester, 140);

      expect(find.text('Note archived'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(store.noteById('n1')!.archived, isFalse);
      await flushTimers(tester);
    }, variant: phone);

    testWidgets('the panel revealed under the card names the action', (
      tester,
    ) async {
      await pumpCard(tester);
      // Nothing is revealed until the card moves.
      expect(find.byIcon(Icons.archive_outlined), findsNothing);

      final gesture = await beginSwipe(tester, 70);

      expect(find.byIcon(Icons.archive_outlined), findsOneWidget);
      expect(find.byIcon(Icons.unarchive_outlined), findsNothing);

      await gesture.up();
      await tester.pumpAndSettle();
      await flushTimers(tester);
    }, variant: phone);

    testWidgets('an archived card reveals the way back instead', (
      tester,
    ) async {
      await pumpCard(tester, archived: true);
      final gesture = await beginSwipe(tester, -70);

      expect(find.byIcon(Icons.unarchive_outlined), findsOneWidget);
      expect(find.byIcon(Icons.archive_outlined), findsNothing);

      await gesture.up();
      await tester.pumpAndSettle();
      await flushTimers(tester);
    }, variant: phone);
  });

  group('where the gesture is off', () {
    testWidgets('a note in the trash has nothing to archive', (tester) async {
      await pumpCard(tester, trashed: true);

      await swipe(tester, 140);

      expect(store.noteById('n1')!.archived, isFalse);
      expect(store.noteById('n1')!.trashed, isTrue);
    }, variant: phone);

    testWidgets('selecting notes owns the card, sideways too', (tester) async {
      await pumpCard(tester, selectionMode: true);

      await swipe(tester, 140);

      expect(store.noteById('n1')!.archived, isFalse);
    }, variant: phone);

    testWidgets('a card that never opted in stays put: the board pages '
        'between its columns with this gesture', (tester) async {
      await pumpCard(tester, swipeToArchive: false);

      await swipe(tester, 140);

      expect(store.noteById('n1')!.archived, isFalse);
    }, variant: phone);

    testWidgets(
      'a mouse drag still belongs to the reorder',
      (tester) async {
        await pumpCard(tester);

        await swipe(tester, 140);

        expect(store.noteById('n1')!.archived, isFalse);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  });

  group('in the grid', () {
    /// Two cards, one per column, so a swipe on either crosses the other.
    Future<void> pumpGrid(WidgetTester tester) async {
      api.notes['n1'] = serverNote('n1', title: 'First');
      api.notes['n2'] = serverNote('n2', title: 'Second');
      await store.refresh();
      await tester.pumpWidget(
        phoneApp(
          store,
          SizedBox(
            width: 400,
            child: AnimatedMasonry(
              notes: store.notesForWidgets,
              columns: 2,
              staggeredEntrance: false,
              // The grid's own gesture: a card lifts for a reorder after a
              // hold, so the swipe has to win the arena before that fires.
              onReorder: (_) => MasonryReorderDecision.keep,
              itemBuilder: (context, note) =>
                  NoteTile(note: note, swipeToArchive: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Tiles in the order the stack paints them, back to front.
    List<String> paintOrder(WidgetTester tester) => [
      for (final tile in tester.widgetList<NoteTile>(find.byType(NoteTile)))
        tile.note.id,
    ];

    testWidgets('the swiped card paints over its neighbours, then hands the '
        'order back', (tester) async {
      await pumpGrid(tester);
      final packed = paintOrder(tester);
      final swiped = packed.first;

      final gesture = await beginSwipe(tester, 60);

      expect(paintOrder(tester).last, swiped);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(paintOrder(tester), packed);
    }, variant: phone);

    testWidgets('a swipe beats the hold that would lift the card', (
      tester,
    ) async {
      await pumpGrid(tester);
      final swiped = paintOrder(tester).first;

      await swipe(tester, 140);

      expect(store.noteById(swiped)!.archived, isTrue);
      await flushTimers(tester);
    }, variant: phone);
  });
}
