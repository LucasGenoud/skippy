import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/collection.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/widgets/marquee_selection.dart';

import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote;
import 'widget_test.dart' show homeApp, flushTimers;

void main() {
  testWidgets('desktop drag from background selects intersecting cards', (
    tester,
  ) async {
    var selected = <String>{'old'};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => MarqueeSelection(
              selectedIds: selected,
              onSelected: (ids) => update(() => selected = ids),
              child: MarqueeRegion.canvas(
                child: Stack(
                  children: [
                    for (final (id, left) in [('a', 60.0), ('b', 240.0)])
                      Positioned(
                        left: left,
                        top: 60,
                        width: 100,
                        height: 100,
                        child: MarqueeRegion.note(
                          id: id,
                          child: const ColoredBox(color: Colors.blue),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.down(const Offset(20, 20));
    await mouse.moveTo(const Offset(180, 180));
    await tester.pump();
    expect(selected, {'a'});
    expect(find.byKey(const Key('marquee-selection-rect')), findsOneWidget);
    await mouse.up();
    await tester.pump();
    expect(find.byKey(const Key('marquee-selection-rect')), findsNothing);

    // A card's own drag remains its gesture, and a click on the background
    // does not clear the selection.
    await mouse.down(const Offset(80, 80));
    await mouse.moveTo(const Offset(320, 180));
    await mouse.up();
    await tester.pump();
    expect(selected, {'a'});
    await mouse.down(const Offset(20, 20));
    await mouse.up();
    await tester.pump();
    expect(selected, {'a'});

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await mouse.down(const Offset(220, 20));
    await mouse.moveTo(const Offset(370, 180));
    await mouse.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(selected, {'a', 'b'});

    final touch = await tester.createGesture(kind: PointerDeviceKind.touch);
    await touch.down(const Offset(20, 20));
    await touch.moveTo(const Offset(180, 180));
    await touch.up();
    expect(selected, {'a', 'b'});
  });

  testWidgets('holding near the edge scrolls and selects newly visible cards', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var selected = <String>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              height: 300,
              child: StatefulBuilder(
                builder: (context, update) => MarqueeSelection(
                  selectedIds: selected,
                  onSelected: (ids) => update(() => selected = ids),
                  child: ListView(
                    controller: controller,
                    children: [
                      MarqueeRegion.canvas(
                        scrollControllers: [controller],
                        child: SizedBox(
                          height: 800,
                          child: Stack(
                            children: [
                              Positioned(
                                left: 100,
                                top: 650,
                                width: 80,
                                height: 80,
                                child: MarqueeRegion.note(
                                  id: 'later',
                                  child: const ColoredBox(color: Colors.blue),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.down(const Offset(20, 20));
    await mouse.moveTo(const Offset(200, 280));
    for (var frame = 0; frame < 90; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(controller.offset, greaterThan(300));
    expect(selected, {'later'});
    await mouse.up();
    await tester.pumpAndSettle();
  });

  testWidgets('horizontal edge scrolling reaches another board column', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var selected = <String>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              height: 200,
              child: StatefulBuilder(
                builder: (context, update) => MarqueeSelection(
                  selectedIds: selected,
                  onSelected: (ids) => update(() => selected = ids),
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    controller: controller,
                    children: [
                      MarqueeRegion.canvas(
                        scrollControllers: [controller],
                        child: const SizedBox(width: 300),
                      ),
                      MarqueeRegion.canvas(
                        scrollControllers: [controller],
                        child: SizedBox(
                          width: 300,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: MarqueeRegion.note(
                              id: 'next',
                              child: const SizedBox(
                                width: 80,
                                height: 80,
                                child: ColoredBox(color: Colors.blue),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.down(const Offset(20, 20));
    await mouse.moveTo(const Offset(290, 150));
    for (var frame = 0; frame < 90; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(controller.offset, greaterThan(200));
    expect(selected, {'next'});
    await mouse.up();
    await tester.pumpAndSettle();
  });

  for (final layout in ['masonry', 'list', 'board']) {
    testWidgets('home $layout selects a note from background', (tester) async {
      tester.view.physicalSize = Size(layout == 'masonry' ? 1800 : 1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = FakeApi();
      api.workspaces['w-default'] = api.workspaces['w-default']!.copyWith(
        collections: [NoteCollection.general('w-default', layout: layout)],
      );
      if (layout == 'board') {
        api.stages['todo'] = const Stage(
          id: 'todo',
          name: 'Todo',
          workspaceId: 'w-default',
          position: 1024,
        );
      }
      api.notes['a'] = serverNote('a', title: 'First note');
      api.notes['b'] = serverNote('b', title: 'Second note');
      final store = NotesStore(api: api, currentUserId: 'u-me');
      addTearDown(store.dispose);
      await store.load();
      if (layout == 'list') store.setSortMode(SortMode.edited);
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();

      final note = find
          .ancestor(
            of: find.text('First note'),
            matching: find.byWidgetPredicate(
              (widget) => widget is MarqueeRegion && widget.noteId == 'a',
            ),
          )
          .first;
      final card = tester.getRect(note);
      final start = layout == 'masonry'
          ? Offset(card.left - 20, card.top + 8)
          : Offset(card.left - 4, card.top + 8);
      final end = Offset(card.right - 8, card.bottom - 8);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.down(start);
      await mouse.moveTo(end);
      await tester.pump();
      await mouse.up();
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      await flushTimers(tester);
    });
  }
}
