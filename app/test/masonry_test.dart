import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/util/motion.dart';
import 'package:skippy/widgets/masonry.dart';

import 'notes_store_test.dart' show serverNote;

void main() {
  testWidgets('selection rebuilds only the changed card', (tester) async {
    final notes = [
      for (var i = 0; i < 3; i++) serverNote('n$i', title: 'Card $i'),
    ];
    var selected = <String>{};
    final builds = <String, int>{};
    Widget grid() => MaterialApp(
      home: Scaffold(
        body: AnimatedMasonry(
          notes: notes,
          columns: 1,
          itemBuildKey: (note) => selected.contains(note.id),
          itemBuilder: (_, note) {
            builds.update(note.id, (count) => count + 1, ifAbsent: () => 1);
            return SizedBox(height: 40, child: Text(note.title));
          },
        ),
      ),
    );

    await tester.pumpWidget(grid());
    await tester.pumpAndSettle();
    builds.clear();
    selected = {'n1'};
    await tester.pumpWidget(grid());
    await tester.pumpAndSettle();
    expect(builds, {'n1': 1});
  });

  testWidgets('large grids mount cards progressively', (tester) async {
    final notes = [
      for (var i = 0; i < 45; i++) serverNote('n$i', title: 'Card $i'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedMasonry(
            notes: notes,
            columns: 3,
            itemBuilder: (_, note) => Text(note.title),
          ),
        ),
      ),
    );

    expect(find.textContaining('Card ').evaluate().length, 20);
    await tester.pumpAndSettle();
    expect(find.textContaining('Card ').evaluate().length, notes.length);
  });

  testWidgets('cards are visible immediately on opening and switching views', (
    tester,
  ) async {
    for (final view in ['notes', 'archive']) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedMasonry(
              key: ValueKey(view),
              notes: [serverNote('n1', title: 'Visible card')],
              columns: 1,
              itemBuilder: (_, note) => Text(note.title),
            ),
          ),
        ),
      );

      expect(find.text('Visible card'), findsOneWidget);
      expect(
        tester
            .widgetList<Opacity>(
              find.ancestor(
                of: find.text('Visible card'),
                matching: find.byType(Opacity),
              ),
            )
            .every((opacity) => opacity.opacity == 1),
        isTrue,
        reason: 'cards must not wait for measurement or an entrance animation',
      );
    }
    await tester.pumpAndSettle();
  });

  group('cards arriving and leaving', () {
    late List<Note> notes;
    Widget grid() => MaterialApp(
      home: Scaffold(
        body: AnimatedMasonry(
          notes: notes,
          columns: 1,
          itemBuilder: (_, note) =>
              SizedBox(height: 40, child: Text(note.title)),
        ),
      ),
    );

    // Product of every fade between the card's text and the grid.
    double opacityOf(WidgetTester tester, String text) {
      var opacity = 1.0;
      for (final fade in tester.widgetList<FadeTransition>(
        find.ancestor(
          of: find.text(text),
          matching: find.byType(FadeTransition),
        ),
      )) {
        opacity *= fade.opacity.value;
      }
      return opacity;
    }

    testWidgets('a removed card fades out where it was, then goes', (
      tester,
    ) async {
      notes = [
        serverNote('n0', title: 'Gone'),
        serverNote('n1', title: 'Kept'),
      ];
      await tester.pumpWidget(grid());
      await tester.pumpAndSettle();
      final centre = tester.getCenter(find.text('Gone'));

      notes = [notes[1]];
      await tester.pumpWidget(grid());
      await tester.pump(Motion.fast ~/ 2);
      expect(find.text('Gone'), findsOneWidget);
      expect(tester.getCenter(find.text('Gone')), centre);
      expect(opacityOf(tester, 'Gone'), inExclusiveRange(0, 1));

      await tester.pumpAndSettle();
      expect(find.text('Gone'), findsNothing);
      expect(find.text('Kept'), findsOneWidget);
    });

    testWidgets('a card added to a shown grid fades in; the rest stay put', (
      tester,
    ) async {
      notes = [serverNote('n0', title: 'Old')];
      await tester.pumpWidget(grid());
      await tester.pumpAndSettle();

      notes = [serverNote('n1', title: 'New'), ...notes];
      await tester.pumpWidget(grid());
      await tester.pump(Motion.base ~/ 3);
      expect(opacityOf(tester, 'New'), inExclusiveRange(0, 1));
      expect(opacityOf(tester, 'Old'), 1);

      await tester.pumpAndSettle();
      expect(opacityOf(tester, 'New'), 1);
    });

    testWidgets('a card returning mid-exit comes back instead of leaving', (
      tester,
    ) async {
      final note = serverNote('n0', title: 'Undone');
      notes = [note];
      await tester.pumpWidget(grid());
      await tester.pumpAndSettle();

      notes = [];
      await tester.pumpWidget(grid());
      await tester.pump(Motion.fast ~/ 2);
      notes = [note];
      await tester.pumpWidget(grid());
      await tester.pumpAndSettle();
      expect(find.text('Undone'), findsOneWidget);
      expect(opacityOf(tester, 'Undone'), 1);
    });

    testWidgets('cards mounted later by progressive loading do not fade in', (
      tester,
    ) async {
      notes = [
        for (var i = 0; i < 45; i++) serverNote('n$i', title: 'Card $i'),
      ];
      await tester.pumpWidget(grid());
      expect(find.text('Card 30'), findsNothing);

      await tester.pump();
      await tester.pump();
      expect(find.text('Card 30'), findsOneWidget);
      expect(opacityOf(tester, 'Card 30'), 1);
      await tester.pumpAndSettle();
    });
  });
}
