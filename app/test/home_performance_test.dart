import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/models/collection.dart';
import 'package:skippy/screens/editor_screen.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/state/settings_store.dart';
import 'package:skippy/widgets/masonry.dart';
import 'package:skippy/widgets/note_card.dart';

import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote;
import 'widget_test.dart' show homeApp, flushTimers;

void main() {
  test(
    'unchanged selections reuse results; edits and filters invalidate them',
    () async {
      final api = FakeApi()..notes['n1'] = serverNote('n1', title: 'First');
      final store = NotesStore(api: api, currentUserId: 'u-me');
      addTearDown(store.dispose);
      await store.load();
      final first = store.notesFor(ViewSelection.notes, '');
      expect(store.notesFor(ViewSelection.notes, ''), same(first));

      store.togglePin('n1');
      final changed = store.notesFor(ViewSelection.notes, '');
      expect(changed, isNot(same(first)));
      expect(changed.pinned.single.id, 'n1');
      expect(store.notesFor(ViewSelection.notes, 'absent').isEmpty, isTrue);
      await Future<void>.delayed(Duration.zero);
    },
  );

  testWidgets('sorted list builds nearby cards and loads more on scroll', (
    tester,
  ) async {
    final api = FakeApi();
    for (var i = 0; i < 100; i++) {
      api.notes['n$i'] = serverNote('n$i', title: 'Card $i');
    }
    final store = NotesStore(api: api, currentUserId: 'u-me');
    addTearDown(store.dispose);
    await store.load();
    final collection = store.activeCollection!;
    store.saveCollection(
      NoteCollection(
        id: collection.id,
        workspaceId: collection.workspaceId,
        name: collection.name,
        layout: 'list',
        sort: 'newest',
      ),
    );
    await tester.pumpWidget(homeApp(store));
    await tester.pumpAndSettle();
    expect(find.byType(NoteTile).evaluate().length, lessThan(30));
    final before = tester
        .widgetList<NoteTile>(find.byType(NoteTile))
        .map((tile) => tile.note.id)
        .toSet();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
    await tester.pumpAndSettle();
    final after = tester
        .widgetList<NoteTile>(find.byType(NoteTile))
        .map((tile) => tile.note.id)
        .toSet();
    expect(after.difference(before), isNotEmpty);

    // Custom ordering retains the existing drag and sidebar-drop gestures.
    store.setSortMode(SortMode.custom);
    await tester.pumpAndSettle();
    expect(find.byType(AnimatedMasonry), findsOneWidget);
    await flushTimers(tester);
  });

  testWidgets('5000-note masonry mounts nearby cards as the grid scrolls', (
    tester,
  ) async {
    final api = FakeApi();
    for (var i = 0; i < 5000; i++) {
      api.notes['n$i'] = serverNote(
        'n$i',
        title: 'Card $i',
        position: i.toDouble(),
      );
    }
    final store = NotesStore(api: api, currentUserId: 'u-me');
    addTearDown(store.dispose);
    await store.load();
    await tester.pumpWidget(homeApp(store));
    await tester.pumpAndSettle();

    final initial = tester
        .widgetList<NoteTile>(find.byType(NoteTile))
        .map((card) => card.note.id)
        .toSet();
    expect(initial.length, lessThan(40));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
    await tester.pumpAndSettle();
    final scrolled = tester
        .widgetList<NoteTile>(find.byType(NoteTile))
        .map((card) => card.note.id)
        .toSet();
    expect(scrolled.length, lessThan(40));
    expect(scrolled.difference(initial), isNotEmpty);
    await flushTimers(tester);
  });

  testWidgets(
    'desktop selection reuses cards without breaking open and select',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      final api = FakeApi()
        ..notes['n1'] = serverNote('n1', title: 'First')
        ..notes['n2'] = serverNote('n2', title: 'Second');
      final store = NotesStore(api: api, currentUserId: 'u-me');
      addTearDown(store.dispose);
      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();

      await tester.tap(find.text('First'));
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();

      NoteTile secondCard() => tester
          .widgetList<NoteTile>(find.byType(NoteTile))
          .singleWhere((card) => card.note.id == 'n2');
      final before = secondCard();
      tester
          .widgetList<NoteTile>(find.byType(NoteTile))
          .singleWhere((card) => card.note.id == 'n1')
          .onSelectionChanged!(true);
      await tester.pumpAndSettle();
      expect(secondCard(), same(before));
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.text('Second'));
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);
      expect(find.byType(EditorScreen), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsOneWidget);
      await flushTimers(tester);
    },
  );

  testWidgets('card updates when the editor closes', (tester) async {
    final api = FakeApi()..notes['n1'] = serverNote('n1', title: 'Before');
    final store = NotesStore(api: api, currentUserId: 'u-me');
    addTearDown(store.dispose);
    await store.load();
    await tester.pumpWidget(homeApp(store));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(NoteTile).first);
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Title'), 'After');
    await tester.pump(const Duration(milliseconds: 250));
    expect(store.noteById('n1')!.title, 'After');
    expect(tester.widget<NoteTile>(find.byType(NoteTile)).note.title, 'Before');

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(tester.widget<NoteTile>(find.byType(NoteTile)).note.title, 'After');
    await flushTimers(tester);
  });

  testWidgets('unrelated settings leave the home grid widget intact', (
    tester,
  ) async {
    final api = FakeApi()..notes['n1'] = serverNote('n1', title: 'First');
    final store = NotesStore(api: api, currentUserId: 'u-me');
    addTearDown(store.dispose);
    await store.load();
    await tester.pumpWidget(homeApp(store));
    await tester.pumpAndSettle();
    final grid = tester.widget<AnimatedMasonry>(find.byType(AnimatedMasonry));
    store.setSortMode(store.sortMode);
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnimatedMasonry>(find.byType(AnimatedMasonry)),
      same(grid),
    );
    final settings = tester
        .element(find.byType(AnimatedMasonry))
        .read<SettingsStore>();
    settings.setLlmConfig(baseUrl: 'http://x/v1', apiKey: '', model: 'm');
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnimatedMasonry>(find.byType(AnimatedMasonry)),
      same(grid),
    );
    settings.setGridDensity(GridDensity.compact);
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnimatedMasonry>(find.byType(AnimatedMasonry)),
      isNot(same(grid)),
    );
    await flushTimers(tester);
  });

  group('switching collections', () {
    const ideas = 'ideas';

    /// Cards of uneven height, so a grid that guesses heights before measuring
    /// visibly puts them somewhere else first.
    Future<NotesStore> twoCollections() async {
      final api = FakeApi();
      for (var i = 0; i < 6; i++) {
        final body = List.filled(1 + i % 4, 'A line of text.').join('\n');
        api.notes['g$i'] = serverNote(
          'g$i',
          title: 'General $i',
          content: body,
          position: i.toDouble(),
          workspaceId: 'w-default',
        );
        api.notes['i$i'] = serverNote(
          'i$i',
          title: 'Idea $i',
          content: body,
          position: i.toDouble(),
          workspaceId: 'w-default',
        ).copyWith(collectionId: ideas);
      }
      final store = NotesStore(api: api, currentUserId: 'u-me');
      await store.load();
      store.saveCollection(
        const NoteCollection(
          id: ideas,
          workspaceId: 'w-default',
          name: 'Ideas',
        ),
      );
      return store;
    }

    /// Wide enough for several columns, where the packing depends on every
    /// card above.
    void desktopWindow(WidgetTester tester) {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    Map<String, Rect> cardRects(WidgetTester tester, String prefix) => {
      for (var i = 0; i < 6; i++)
        '$prefix $i': tester.getRect(find.text('$prefix $i')),
    };

    testWidgets('a collection shown before reopens where its cards settled', (
      tester,
    ) async {
      desktopWindow(tester);
      final store = await twoCollections();
      addTearDown(store.dispose);
      final general = store.activeCollection!.id;
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();
      final settled = cardRects(tester, 'General');

      store.selectCollection(ideas);
      await tester.pumpAndSettle();
      store.selectCollection(general);
      await tester.pump();

      expect(cardRects(tester, 'General'), settled);
      await tester.pumpAndSettle();
      await flushTimers(tester);
    });

    testWidgets('a collection shown for the first time does not glide', (
      tester,
    ) async {
      desktopWindow(tester);
      final store = await twoCollections();
      addTearDown(store.dispose);
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();

      store.selectCollection(ideas);
      // One frame lays the cards out on estimates; the next has measured
      // them and must put them straight where they belong.
      await tester.pump();
      await tester.pump();
      final early = cardRects(tester, 'Idea');
      await tester.pumpAndSettle();

      expect(early, cardRects(tester, 'Idea'));
      await flushTimers(tester);
    });

    testWidgets('a new grid mounts one screen of cards on its first frame', (
      tester,
    ) async {
      final api = FakeApi();
      for (var i = 0; i < 40; i++) {
        api.notes['i$i'] = serverNote(
          'i$i',
          title: 'Idea $i',
          position: i.toDouble(),
          workspaceId: 'w-default',
        ).copyWith(collectionId: ideas);
      }
      final store = NotesStore(api: api, currentUserId: 'u-me');
      addTearDown(store.dispose);
      await store.load();
      store.saveCollection(
        const NoteCollection(
          id: ideas,
          workspaceId: 'w-default',
          name: 'Ideas',
        ),
      );
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();
      int mounted() => find.textContaining('Idea ').evaluate().length;

      store.selectCollection(ideas);
      await tester.pump();
      // The rest of the margin below the screen can wait a frame.
      final firstFrame = mounted();
      final screen =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      final tops = [
        for (final card in find.textContaining('Idea ').evaluate())
          (card.renderObject! as RenderBox).localToGlobal(Offset.zero).dy,
      ];
      // Measured from the grid's own top: before it has a place on screen,
      // a new grid can only count a screen down from where it starts.
      final gridTop = tops.reduce((a, b) => a < b ? a : b);
      expect(tops, everyElement(lessThan(gridTop + screen)));
      await tester.pumpAndSettle();
      expect(mounted(), greaterThan(firstFrame));
      await flushTimers(tester);
    });

    testWidgets('the outgoing grid fades out while the new one fades in', (
      tester,
    ) async {
      desktopWindow(tester);
      final store = await twoCollections();
      addTearDown(store.dispose);
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();

      store.selectCollection(ideas);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      double opacityOf(String text) => tester
          .widgetList<FadeTransition>(
            find.ancestor(
              of: find.text(text),
              matching: find.byType(FadeTransition),
            ),
          )
          .fold(1.0, (value, fade) => value * fade.opacity.value);
      expect(opacityOf('General 0'), inExclusiveRange(0, 1));
      expect(opacityOf('Idea 0'), inExclusiveRange(0, 1));

      await tester.pumpAndSettle();
      expect(find.text('General 0'), findsNothing);
      expect(opacityOf('Idea 0'), 1);
      await flushTimers(tester);
    });
  });
}
