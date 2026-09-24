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
    settings.setLlmLabelingEnabled(!settings.llmLabelingEnabled);
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
}
