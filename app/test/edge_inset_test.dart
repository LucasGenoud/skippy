import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/widgets/markdown_toolbar.dart';
import 'package:skippy/widgets/masonry.dart';

import 'fake_api.dart';
import 'finders.dart';
import 'notes_store_test.dart' show serverNote;
import 'widget_test.dart' show homeApp, flushTimers;

/// Closest a button's hover shape may come to the edge of the surface it is
/// drawn on: a pill, a bar, a card, a dialog.
const double _minInset = 2;

/// Whether [box] paints a surface of its own, one a button can sit flush in.
bool _isSurface(RenderObject box) {
  if (box is RenderPhysicalShape || box is RenderPhysicalModel) {
    return true;
  }
  if (box is! RenderDecoratedBox) {
    return false;
  }
  final decoration = box.decoration;
  return decoration is BoxDecoration &&
      (decoration.color != null || decoration.border != null) &&
      decoration.color != Colors.transparent;
}

/// Every icon button on screen whose hover shape touches an edge of the
/// nearest surface around it, described for the failure message.
List<String> _flushButtons(WidgetTester tester) {
  final found = <String>[];
  for (final element in find.byType(IconButton).evaluate()) {
    final button = element.renderObject;
    if (button is! RenderBox || !button.hasSize || !button.attached) {
      continue;
    }

    var parent = button.parent;
    while (parent != null && !_isSurface(parent)) {
      parent = parent.parent;
    }
    if (parent is! RenderBox) {
      continue;
    }

    final rect = button.localToGlobal(Offset.zero) & button.size;
    final surface = parent.localToGlobal(Offset.zero) & parent.size;
    // A surface no bigger than the button is the button's own shape.
    if (surface.width <= rect.width + 1 || surface.height <= rect.height + 1) {
      continue;
    }

    final gaps = {
      'left': rect.left - surface.left,
      'top': rect.top - surface.top,
      'right': surface.right - rect.right,
      'bottom': surface.bottom - rect.bottom,
    };
    final flush = gaps.entries.where(
      (gap) => gap.value > -1 && gap.value < _minInset,
    );
    if (flush.isEmpty) {
      continue;
    }

    final widget = element.widget as IconButton;
    found.add(
      '"${widget.tooltip}" ${flush.map((g) => '${g.key} ${g.value.toStringAsFixed(1)}px').join(', ')} '
      'inside ${parent.runtimeType} $surface',
    );
  }
  return found;
}

void main() {
  late FakeApi api;
  late NotesStore store;

  setUp(() async {
    api = FakeApi();
    for (var i = 0; i < 4; i++) {
      api.notes['n$i'] = serverNote(
        'n$i',
        title: 'Note $i',
        content: 'Body $i',
        pinned: i == 0,
      );
    }
    store = NotesStore(api: api, currentUserId: 'u-me');
    await store.load();
  });

  tearDown(() => store.dispose());

  // Desktop, where buttons show a hover shape.
  final desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

  for (final (name, size) in [
    ('a phone-width window', const Size(420, 900)),
    ('a desktop window', const Size(1400, 900)),
  ]) {
    group('in $name no button sits flush against its surface', () {
      Future<void> showHome(WidgetTester tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(homeApp(store));
        await tester.pumpAndSettle();
      }

      testWidgets('on the home screen', (tester) async {
        await showHome(tester);
        expect(_flushButtons(tester), isEmpty);
        await flushTimers(tester);
      }, variant: desktop);

      testWidgets('in the note editor', (tester) async {
        await showHome(tester);
        await tester.tap(
          find
              .descendant(
                of: find.byType(AnimatedMasonry),
                matching: find.text('Note 1'),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(_flushButtons(tester), isEmpty);
        await flushTimers(tester);
      }, variant: desktop);

      testWidgets('in the markdown toolbar', (tester) async {
        api.notes['md'] = serverNote(
          'md',
          title: 'Plan',
          kind: NoteKind.markdown,
        );
        await store.load();
        await showHome(tester);
        await tester.tap(
          find
              .descendant(
                of: find.byType(AnimatedMasonry),
                matching: find.text('Plan'),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(findAction('Edit markdown').last);
        await tester.pumpAndSettle();

        expect(find.byType(MarkdownToolbar), findsOneWidget);
        expect(_flushButtons(tester), isEmpty);
        await flushTimers(tester);
      }, variant: desktop);
    });
  }
}
