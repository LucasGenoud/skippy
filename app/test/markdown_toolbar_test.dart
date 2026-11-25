import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/screens/editor_screen.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/widgets/editor/compose_bar_reveal.dart';
import 'package:skippy/widgets/markdown_toolbar.dart';

import 'fake_api.dart';
import 'finders.dart';
import 'notes_store_test.dart' show serverNote;
import 'widget_test.dart' show harness, flushTimers;

/// One frame at 60 Hz.
const _frame = Duration(milliseconds: 16);

/// The longest the bar may take to enter or leave.
const _settled = 20;

void main() {
  late FakeApi api;
  late NotesStore store;

  setUp(() async {
    api = FakeApi();
    api.notes['n1'] = serverNote(
      'n1',
      title: 'Plan',
      kind: NoteKind.markdown,
      content: '# Plan\n\n- milk',
    );
    store = NotesStore(api: api, currentUserId: 'u-me');
    await store.load();
  });

  tearDown(() => store.dispose());

  /// Where the Bold button sits, if the bar is on screen.
  Offset? boldAt(WidgetTester tester) {
    final bold = find.descendant(
      of: find.byType(MarkdownToolbar),
      matching: findAction('Bold'),
    );
    if (bold.evaluate().isEmpty) {
      return null;
    }
    return tester.getBottomLeft(bold.first);
  }

  /// Every position the Bold button takes over the next frames, until the
  /// bar has settled.
  Future<List<Offset?>> sample(WidgetTester tester) async {
    final seen = <Offset?>[];
    for (var i = 0; i < _settled; i++) {
      await tester.pump(_frame);
      seen.add(boldAt(tester));
    }
    return seen;
  }

  for (final (name, size) in [
    ('a phone', const Size(390, 800)),
    ('a wide window', const Size(1200, 800)),
  ]) {
    testWidgets('on $name the bar rises and sinks without sliding sideways', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      await tester.pumpAndSettle();

      await tester.tap(findAction('Edit markdown').last);
      await tester.pump();
      final entering = (await sample(tester)).nonNulls.toList();
      await tester.pumpAndSettle();
      final rest = boldAt(tester)!;

      // Shown over several frames rather than popping in, and every one of
      // them with the button where it ends up: the bar grows in height only,
      // anchored to the bottom bar, so nothing in it moves.
      expect(entering.length, greaterThan(2));
      for (final at in entering) {
        expect(at, rest);
      }

      await tester.tap(findAction('Preview').last);
      await tester.pump();
      final leaving = await sample(tester);

      expect(leaving.first, rest, reason: 'the bar must not vanish at once');
      for (final at in leaving.nonNulls) {
        expect(at, rest);
      }
      expect(find.byType(MarkdownToolbar), findsNothing);
      await flushTimers(tester);
    });
  }

  testWidgets('under reduced motion the bar comes and goes in one frame', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    Widget reveal(Widget? child) => MaterialApp(
      home: Scaffold(body: ComposeBarReveal(child: child)),
    );

    await tester.pumpWidget(reveal(null));
    await tester.pumpWidget(reveal(const Text('bar')));
    expect(
      tester.getSize(find.byType(ComposeBarReveal)).height,
      greaterThan(0),
    );
    expect(tester.hasRunningAnimations, isFalse);

    await tester.pumpWidget(reveal(null));
    expect(find.text('bar'), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
