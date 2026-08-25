import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/theme.dart';
import 'package:skippy/widgets/search_filters_sheet.dart';
import 'package:skippy/widgets/search_query_controller.dart';

import 'fake_api.dart';

void main() {
  late FakeApi api;
  late NotesStore store;
  late SearchQueryController controller;

  setUp(() {
    api = FakeApi();
    store = NotesStore(api: api, currentUserId: 'u-me');
    controller = SearchQueryController();
  });

  tearDown(() {
    controller.dispose();
    store.dispose();
  });

  /// The sheet, with the query it reports back recorded in [seen].
  Widget sheetApp(List<String> seen) => ChangeNotifierProvider.value(
    value: store,
    child: MaterialApp(
      home: Scaffold(
        body: SearchFiltersSheet(controller: controller, onChanged: seen.add),
      ),
    ),
  );

  /// The chip spelled [label]. Scoped to the chips, because the sheet also
  /// echoes the whole query along its bottom edge.
  Finder chip(String label) =>
      find.descendant(of: find.byType(FilterChip), matching: find.text(label));

  /// Settles the chip's label and colour animations.
  Future<void> tapChip(WidgetTester tester, String label) async {
    await tester.tap(chip(label));
    await tester.pumpAndSettle();
  }

  testWidgets('a chip cycles through matching, excluding, and off', (
    tester,
  ) async {
    final seen = <String>[];
    await tester.pumpWidget(sheetApp(seen));

    await tapChip(tester, 'has:link');
    expect(controller.text, 'has:link');

    // The chip now spells the operator that excludes, which is the only place
    // the user is told that spelling exists.
    await tapChip(tester, 'has:link');
    expect(controller.text, 'hasnot:link');
    expect(chip('hasnot:link'), findsOneWidget);
    expect(chip('has:link'), findsNothing);

    await tapChip(tester, 'hasnot:link');
    expect(controller.text, '');
    expect(chip('has:link'), findsOneWidget);

    // The screen was told about every step, or the grid would not refilter.
    expect(seen, ['has:link', 'hasnot:link', '']);
  });

  testWidgets('an excluded chip is tinted apart from a matching one', (
    tester,
  ) async {
    await tester.pumpWidget(sheetApp([]));
    final scheme = Theme.of(
      tester.element(find.byType(SearchFiltersSheet)),
    ).colorScheme;

    Color? fillOf(String label) => tester
        .widget<FilterChip>(
          find.ancestor(of: chip(label), matching: find.byType(FilterChip)),
        )
        .selectedColor;

    await tapChip(tester, 'is:pinned');
    expect(fillOf('is:pinned'), scheme.secondaryContainer);

    await tapChip(tester, 'is:pinned');
    expect(fillOf('isnot:pinned'), excludedFilterColor(scheme));
  });

  testWidgets('chips reflect a filter typed into the box by hand', (
    tester,
  ) async {
    await tester.pumpWidget(sheetApp([]));

    // The dash spelling means the same thing, so the chip has to recognize it
    // rather than offer to add a second copy of the filter.
    controller.setQuery('-kind:audio');
    await tester.pumpAndSettle();
    expect(chip('notkind:audio'), findsOneWidget);

    await tapChip(tester, 'notkind:audio');
    expect(controller.text, '');
  });
}
