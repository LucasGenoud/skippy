import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/screens/editor_screen.dart';
import 'package:skippy/state/notes_store.dart';

import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote;
import 'widget_test.dart' show harness, flushTimers;

/// How the app behaves around the soft keyboard: what it moves out of the
/// way, and the gestures that put it away again.
void main() {
  late FakeApi api;
  late NotesStore store;

  setUp(() {
    api = FakeApi();
    store = NotesStore(api: api, currentUserId: 'u-me');
  });
  tearDown(() => store.dispose());

  void tablet(WidgetTester tester) {
    tester.view.physicalSize = const Size(2048, 1536);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
  }

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  Finder editable(int index) => find.byType(EditableText).at(index);

  group('the note dialog on a wide screen', () {
    testWidgets('rises above the keyboard', (tester) async {
      tablet(tester);
      api.notes['n1'] = serverNote(
        'n1',
        title: 'Long',
        content: List.filled(60, 'line').join('\n'),
      );
      await store.load();
      await tester.pumpWidget(
        harness(
          store,
          Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  openNoteEditor(context, noteId: 'n1', openFullscreen: () {}),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      const keyboard = 400.0;
      tester.view.viewInsets = const FakeViewPadding(bottom: keyboard * 2);
      await tester.pumpAndSettle();

      final dialog = tester.getRect(find.byType(EditorScreen));
      final screen = tester.view.physicalSize.height / 2;
      expect(dialog.bottom, lessThanOrEqualTo(screen - keyboard));
      expect(dialog.top, greaterThanOrEqualTo(0));
      await flushTimers(tester);
    });
  });

  group('the fullscreen editor', () {
    testWidgets('a tap below a short note puts the caret at its end', (
      tester,
    ) async {
      phone(tester);
      api.notes['n1'] = serverNote('n1', title: 'T', content: 'Short body');
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      await tester.pumpAndSettle();

      final body = tester.getRect(editable(1));
      await tester.tapAt(Offset(body.center.dx, body.bottom + 150));
      await tester.pumpAndSettle();

      final field = tester.widget<EditableText>(editable(1));
      expect(field.focusNode.hasFocus, isTrue);
      expect(
        field.controller.selection,
        const TextSelection.collapsed(offset: 'Short body'.length),
      );
      await flushTimers(tester);
    });

    testWidgets('placing the caret in a note does not edit it', (tester) async {
      phone(tester);
      api.notes['n1'] = serverNote('n1', title: 'T', content: 'Short body');
      await store.load();
      final before = store.noteById('n1')!.updatedAt;
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      await tester.pumpAndSettle();

      await tester.tap(editable(0));
      await tester.pumpAndSettle();
      final body = tester.getRect(editable(1));
      await tester.tapAt(Offset(body.center.dx, body.bottom + 150));
      await flushTimers(tester);
      await tester.pumpAndSettle();

      expect(store.noteById('n1')!.updatedAt, before);
      expect(api.log.where((op) => op.startsWith('patchNote')), isEmpty);
    });

    testWidgets(
      'pulling the note down past its top hides the keyboard',
      (tester) async {
        phone(tester);
        api.notes['n1'] = serverNote('n1', title: 'T', content: 'Body');
        await store.load();
        await tester.pumpWidget(
          harness(store, const EditorScreen(noteId: 'n1')),
        );
        await tester.pumpAndSettle();

        await tester.tap(editable(1));
        await tester.pumpAndSettle();
        expect(
          tester.widget<EditableText>(editable(1)).focusNode.hasFocus,
          true,
        );

        await tester.drag(editable(0), const Offset(0, 200));
        await tester.pumpAndSettle();
        expect(
          tester.widget<EditableText>(editable(1)).focusNode.hasFocus,
          isFalse,
        );
        await flushTimers(tester);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.iOS,
        TargetPlatform.android,
      }),
    );

    testWidgets('scrolling the note back up while writing keeps the keyboard', (
      tester,
    ) async {
      phone(tester);
      api.notes['n1'] = serverNote(
        'n1',
        title: 'T',
        content: List.filled(80, 'line').join('\n'),
      );
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      await tester.pumpAndSettle();

      await tester.tapAt(tester.getTopLeft(editable(1)) + const Offset(20, 10));
      await tester.pumpAndSettle();
      await tester.drag(editable(1), const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.drag(editable(1), const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(editable(1)).focusNode.hasFocus, true);
      await flushTimers(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('a checklist takes a tap below it to its new-item row', (
      tester,
    ) async {
      phone(tester);
      api.notes['n1'] = serverNote(
        'n1',
        kind: NoteKind.checklist,
        items: [ChecklistItem(id: 'i1', text: 'milk')],
      );
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      await tester.pumpAndSettle();

      final last = tester.getRect(find.byType(EditableText).last);
      await tester.tapAt(Offset(last.center.dx, last.bottom + 200));
      await tester.pumpAndSettle();

      final focused = FocusManager.instance.primaryFocus;
      final composer = tester.widget<EditableText>(
        find.byType(EditableText).last,
      );
      expect(focused, composer.focusNode);
      await flushTimers(tester);
    });
  });
}
