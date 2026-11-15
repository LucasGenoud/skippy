import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/screens/editor_screen.dart';
import 'package:skippy/state/link_preview_cache.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/widgets/note_card.dart';

import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote;
import 'widget_test.dart' show homeApp, flushTimers;
import 'finders.dart';

/// What the first frame of opening a note has to build.
///
/// On an iPhone that frame took 22-30 ms, about two thirds of it the two
/// toolbars' icon buttons. The editor is still invisible then (it fades in
/// from 30% of the morph), so the toolbars wait a frame or two and the work is
/// spread over frames nobody sees. Measured at ~1,170 widgets before.
void main() {
  late FakeApi api;
  late NotesStore store;

  setUp(() {
    api = FakeApi();
    store = NotesStore(api: api, currentUserId: 'u-me');
  });
  tearDown(() => store.dispose());

  int elementsUnder(Element root) {
    var count = 1;
    root.visitChildren((child) => count += elementsUnder(child));
    return count;
  }

  Future<void> openFromGrid(WidgetTester tester, {bool reduced = false}) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    if (reduced) {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
    }
    api.notes['n0'] = serverNote(
      'n0',
      title: 'Note',
      content: 'Body text',
      workspaceId: 'w-default',
    );
    await store.load();
    await tester.pumpWidget(
      Provider(
        create: (_) => LinkPreviewCache(api: api),
        child: homeApp(store),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NoteTile));
    await tester.pump();
  }

  testWidgets('the first frame leaves the toolbars for later', (tester) async {
    await openFromGrid(tester);

    final editor = find.byType(EditorScreen).evaluate().single;
    expect(elementsUnder(editor), lessThan(700));
    expect(findAction('Note actions'), findsNothing);
    expect(findAction('Undo'), findsNothing);

    await tester.pumpAndSettle();
    expect(findAction('Note actions'), findsOneWidget);
    expect(findAction('Undo'), findsOneWidget);
    await flushTimers(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('with reduced motion the toolbars come at once', (tester) async {
    await openFromGrid(tester, reduced: true);

    expect(findAction('Note actions'), findsOneWidget);
    expect(findAction('Undo'), findsOneWidget);
    await tester.pumpAndSettle();
    await flushTimers(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('the opened editor stays light', (tester) async {
    await openFromGrid(tester);
    await tester.pumpAndSettle();

    // Was ~1,110: twelve Material icon buttons, each ~56 widgets.
    final editor = find.byType(EditorScreen).evaluate().single;
    expect(elementsUnder(editor), lessThan(700));

    // Find, copy and archive live in the note menu, not the bar.
    final bar = find.byType(AppBar);
    for (final icon in [
      Icons.search,
      Icons.content_copy_outlined,
      Icons.archive_outlined,
    ]) {
      expect(
        find.descendant(of: bar, matching: find.byIcon(icon)),
        findsNothing,
      );
    }
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Find in note'), findsOneWidget);
    expect(find.text('Copy to clipboard'), findsOneWidget);
    expect(find.text('Archive'), findsOneWidget);
    await flushTimers(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
