import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/screens/editor_screen.dart';
import 'package:skippy/state/link_preview_cache.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/state/settings_store.dart';
import 'package:skippy/widgets/checklist/animated_checklist.dart';
import 'package:skippy/widgets/screen_width.dart';

import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote;

/// Editing a checklist through the real editor, one platform text-input
/// report at a time: the interesting failures live between the keyboard and
/// the row, not in the store.
Widget harness(NotesStore store, Widget child) => MultiProvider(
  providers: [
    ChangeNotifierProvider.value(value: store),
    ChangeNotifierProvider(create: (_) => SettingsStore(api: store.api)),
    Provider(create: (_) => LinkPreviewCache(api: store.api)),
  ],
  child: MaterialApp(
    builder: (context, child) => ScreenWidth(child: child ?? const SizedBox()),
    home: Scaffold(body: child),
  ),
);

/// Flush the store's debounce (400ms) so no timers leak out of the test.
Future<void> flushTimers(WidgetTester tester) async =>
    tester.pump(const Duration(milliseconds: 700));

void main() {
  late FakeApi api;
  late NotesStore store;

  setUp(() {
    api = FakeApi();
    store = NotesStore(api: api, currentUserId: 'u-me');
  });
  tearDown(() => store.dispose());

  EditableText focusedField(WidgetTester tester) => tester
      .widgetList<EditableText>(
        find.descendant(
          of: find.byType(AnimatedChecklist),
          matching: find.byType(EditableText),
        ),
      )
      .singleWhere((field) => field.focusNode.hasFocus);

  /// What a field shows: its text minus the zero-width marker an empty row
  /// parks so that backspace in it is something the platform reports.
  String written(EditableText field) =>
      field.controller.text.replaceAll('\u200b', '');

  /// What the platform reports for one backspace: the field's text minus its
  /// last character, caret at the end.
  void backspace(WidgetTester tester) {
    final text = focusedField(tester).controller.text;
    final next = text.isEmpty ? '' : text.substring(0, text.length - 1);
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      ),
    );
  }

  List<String> itemsOf(String noteId) => [
    for (final item in store.noteById(noteId)!.items) item.text,
  ];

  Future<void> openChecklist(
    WidgetTester tester, {
    List<ChecklistItem> items = const [],
  }) async {
    api.notes['n1'] = serverNote('n1', kind: NoteKind.checklist, items: items);
    await store.load();
    await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
    await tester.pumpAndSettle();
  }

  group('deleting text', () {
    testWidgets('backspacing the last character empties the row, keeps it', (
      tester,
    ) async {
      // iOS reported the whole line disappearing on the keypress that merely
      // deleted its last character.
      await openChecklist(
        tester,
        items: const [ChecklistItem(id: 'i1', text: 'Milk')],
      );
      await tester.tap(find.widgetWithText(TextField, 'Milk'));
      await tester.pumpAndSettle();

      for (var left = 3; left >= 0; left--) {
        backspace(tester);
        await tester.pumpAndSettle();
        expect(itemsOf('n1'), hasLength(1), reason: '$left characters left');
        expect(
          store.noteById('n1')!.items.single.text,
          'Milk'.substring(0, left),
        );
      }

      // Only the next backspace, on a row that is already empty, takes it.
      backspace(tester);
      await tester.pumpAndSettle();
      expect(itemsOf('n1'), isEmpty);
      await flushTimers(tester);
    });

    testWidgets(
      'an input client that re-reports an empty value keeps the row',
      (tester) async {
        // The emptying keystroke and the client's own echo of it arrive in the
        // same frame; a row may only be removed by a backspace of its own.
        await openChecklist(
          tester,
          items: const [ChecklistItem(id: 'i1', text: 'A')],
        );
        await tester.tap(find.widgetWithText(TextField, 'A'));
        await tester.pumpAndSettle();

        backspace(tester);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '',
            selection: TextSelection.collapsed(offset: 0),
          ),
        );
        await tester.pumpAndSettle();

        expect(itemsOf('n1'), ['']);
        await flushTimers(tester);
      },
    );

    testWidgets('an empty row still goes away when the client echoes it back', (
      tester,
    ) async {
      // The browser's input client reports the field's value back after every
      // edit, marker and all. Those echoes must not consume the backspace
      // that the empty row is waiting for.
      await openChecklist(
        tester,
        items: const [ChecklistItem(id: 'i1', text: 'A')],
      );
      await tester.tap(find.widgetWithText(TextField, 'A'));
      await tester.pumpAndSettle();

      backspace(tester);
      await tester.pumpAndSettle();
      expect(itemsOf('n1'), ['']);

      // The parked marker, handed straight back.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200b',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.pumpAndSettle();
      expect(itemsOf('n1'), ['']);

      backspace(tester);
      await tester.pumpAndSettle();
      expect(itemsOf('n1'), isEmpty);
      await flushTimers(tester);
    });

    testWidgets('a word cannot vanish under a resting caret', (tester) async {
      // A text input client that resets the field (a fresh attachment, a
      // keyboard swap) reports an empty value out of nowhere. The user did
      // not delete seven characters with one keypress, so the row keeps them.
      await openChecklist(
        tester,
        items: const [ChecklistItem(id: 'i1', text: 'Pancake')],
      );
      await tester.tap(find.widgetWithText(TextField, 'Pancake'));
      await tester.pumpAndSettle();

      tester.testTextInput.updateEditingValue(TextEditingValue.empty);
      await tester.pumpAndSettle();

      expect(itemsOf('n1'), ['Pancake']);
      expect(focusedField(tester).controller.text, 'Pancake');
      await flushTimers(tester);
    });

    testWidgets('selecting the whole row and deleting empties it', (
      tester,
    ) async {
      await openChecklist(
        tester,
        items: const [ChecklistItem(id: 'i1', text: 'Pancake')],
      );
      await tester.tap(find.widgetWithText(TextField, 'Pancake'));
      await tester.pumpAndSettle();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'Pancake',
          selection: TextSelection(baseOffset: 0, extentOffset: 7),
        ),
      );
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        ),
      );
      await tester.pumpAndSettle();

      expect(itemsOf('n1'), ['']);
      await flushTimers(tester);
    });
  });

  group('the composer', () {
    testWidgets('writes into one item without ever moving the caret', (
      tester,
    ) async {
      await openChecklist(tester);
      await tester.tap(find.widgetWithText(TextField, 'List item'));
      await tester.pump();
      final composer = focusedField(tester).controller;

      tester.testTextInput.enterText('Mi');
      await tester.pump();
      expect(itemsOf('n1'), ['Mi']);
      expect(focusedField(tester).controller, same(composer));

      tester.testTextInput.enterText('Milk');
      await tester.pump();
      expect(itemsOf('n1'), ['Milk']);
      expect(focusedField(tester).controller, same(composer));
      await flushTimers(tester);
    });

    testWidgets('new items request sentence capitalization', (tester) async {
      await openChecklist(tester);

      final composer = tester.widget<TextField>(
        find.widgetWithText(TextField, 'List item'),
      );
      expect(composer.textCapitalization, TextCapitalization.sentences);
    });

    testWidgets('deleting everything takes the half-written row with it', (
      tester,
    ) async {
      await openChecklist(tester);
      await tester.tap(find.widgetWithText(TextField, 'List item'));
      await tester.pump();

      tester.testTextInput.enterText('Mi');
      await tester.pump();
      expect(itemsOf('n1'), ['Mi']);

      backspace(tester);
      await tester.pumpAndSettle();
      expect(itemsOf('n1'), ['M']);

      // Nothing written, nothing left behind: no blank row in the note, and
      // the composer keeps the caret for another go. It holds nothing but the
      // marker that keeps the *next* backspace reportable.
      backspace(tester);
      await tester.pumpAndSettle();
      expect(itemsOf('n1'), isEmpty);
      expect(find.widgetWithText(TextField, 'List item'), findsOneWidget);
      expect(written(focusedField(tester)), isEmpty);
      await flushTimers(tester);
    });

    // An empty line is where backspace means "go back up", and the composer is
    // a line like any other to whoever is typing in it. It keeps its place:
    // there is no item under it to remove.
    testWidgets('backspace in an empty composer walks back up the list', (
      tester,
    ) async {
      await openChecklist(
        tester,
        items: const [
          ChecklistItem(id: 'i1', text: 'Milk'),
          ChecklistItem(id: 'i2', text: 'Eggs'),
        ],
      );
      await tester.tap(find.widgetWithText(TextField, 'List item'));
      await tester.pumpAndSettle();

      backspace(tester);
      await tester.pumpAndSettle();

      final caret = focusedField(tester);
      expect(written(caret), 'Eggs');
      expect(caret.controller.selection.isCollapsed, isTrue);
      expect(caret.controller.selection.baseOffset, 4);
      expect(itemsOf('n1'), ['Milk', 'Eggs']);
      expect(find.widgetWithText(TextField, 'List item'), findsOneWidget);
      await flushTimers(tester);
    });

    testWidgets('a hardware backspace in the empty composer does the same', (
      tester,
    ) async {
      await openChecklist(
        tester,
        items: const [ChecklistItem(id: 'i1', text: 'Milk')],
      );
      await tester.tap(find.widgetWithText(TextField, 'List item'));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();

      final caret = focusedField(tester);
      expect(written(caret), 'Milk');
      expect(caret.controller.selection.baseOffset, 4);
      expect(itemsOf('n1'), ['Milk']);
      await flushTimers(tester);
    });

    testWidgets('backspace with nothing above it leaves the composer alone', (
      tester,
    ) async {
      await openChecklist(tester);
      await tester.tap(find.widgetWithText(TextField, 'List item'));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      backspace(tester);
      await tester.pumpAndSettle();

      expect(written(focusedField(tester)), isEmpty);
      expect(find.widgetWithText(TextField, 'List item'), findsOneWidget);
      expect(itemsOf('n1'), isEmpty);
      await flushTimers(tester);
    });

    testWidgets('the checkbox takes the "+" slot without shifting the row', (
      tester,
    ) async {
      // The first keystroke swaps the composer's "+" for a real checkbox, and
      // that swap is animated: it must land exactly where the "+" was, and
      // must never nudge the field the caret is already in, at any point in
      // the transition.
      await openChecklist(tester);
      await tester.tap(find.widgetWithText(TextField, 'List item'));
      await tester.pumpAndSettle();

      Rect leading() =>
          tester.getRect(find.byKey(const Key('checklist-composer-leading')));
      Rect field() => tester.getRect(
        find.descendant(
          of: find.byType(AnimatedChecklist),
          matching: find.byType(EditableText),
        ),
      );
      final plusSlot = leading();
      final fieldBefore = field();

      tester.testTextInput.enterText('Milk');
      await tester.pump();

      // Neither mark travels: they trade the same slot in place, so they can
      // never be seen sliding past each other. Sampled across the whole
      // transition rather than at one convenient midpoint.
      var handedOver = false;
      for (var elapsed = 0; elapsed <= 240; elapsed += 20) {
        if (elapsed > 0) await tester.pump(const Duration(milliseconds: 20));
        final plus = find.byIcon(Icons.add);
        final box = find.byType(Checkbox);
        expect(leading(), plusSlot, reason: 'slot moved at ${elapsed}ms');
        expect(field(), fieldBefore, reason: 'field moved at ${elapsed}ms');
        for (final mark in [plus, box]) {
          if (mark.evaluate().isEmpty) continue;
          expect(
            tester.getCenter(mark),
            within(distance: 0.5, from: plusSlot.center),
            reason: 'mark drifted off centre at ${elapsed}ms',
          );
        }
        // The slot is never left empty: the "+" is still fading out while the
        // checkbox is already fading in.
        expect(
          plus.evaluate().isNotEmpty || box.evaluate().isNotEmpty,
          isTrue,
          reason: 'the slot was empty at ${elapsed}ms',
        );
        handedOver |= plus.evaluate().isNotEmpty && box.evaluate().isNotEmpty;
      }
      expect(handedOver, isTrue, reason: 'the two never overlapped');

      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.add), findsNothing);
      expect(leading(), plusSlot);
      expect(field(), fieldBefore);
      // The checkbox is centred on the slot the "+" occupied.
      expect(
        tester.getCenter(find.byType(Checkbox)),
        within(distance: 0.5, from: plusSlot.center),
      );
      await flushTimers(tester);
    });

    testWidgets('Enter hands the row over and starts the next one', (
      tester,
    ) async {
      await openChecklist(tester);
      await tester.tap(find.widgetWithText(TextField, 'List item'));
      await tester.pump();
      final composer = focusedField(tester).controller;

      tester.testTextInput.enterText('Milk');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();

      // The caret stays in the composer, which is now empty and one line
      // lower, above a committed 'Milk' row.
      expect(itemsOf('n1'), ['Milk']);
      expect(focusedField(tester).controller, same(composer));
      expect(composer.text, isEmpty);
      expect(find.widgetWithText(TextField, 'Milk'), findsOneWidget);

      tester.testTextInput.enterText('Eggs');
      await tester.pump();
      expect(itemsOf('n1'), ['Milk', 'Eggs']);
      await flushTimers(tester);
    });

    testWidgets('leaving the composer commits what it was writing', (
      tester,
    ) async {
      await openChecklist(
        tester,
        items: const [ChecklistItem(id: 'i1', text: 'Milk')],
      );
      await tester.tap(find.widgetWithText(TextField, 'List item'));
      await tester.pump();
      tester.testTextInput.enterText('Eggs');
      await tester.pump();

      await tester.tap(find.widgetWithText(TextField, 'Milk'));
      await tester.pumpAndSettle();

      expect(itemsOf('n1'), ['Milk', 'Eggs']);
      expect(find.widgetWithText(TextField, 'List item'), findsOneWidget);
      await flushTimers(tester);
    });

    testWidgets('writing a new item does not rebuild the list per keystroke', (
      tester,
    ) async {
      // Materializing the item used to hand the caret to a row of its own,
      // and every keystroke that landed before it did rebuilt the whole
      // checklist to re-route itself. On a 30-item list that was ~180 widget
      // rebuilds per character (measured), the lag in writing a new item.
      // Only the field being typed in should rebuild now (~48).
      await openChecklist(
        tester,
        items: [
          for (var i = 0; i < 30; i++)
            ChecklistItem(id: 'i$i', text: 'item $i'),
        ],
      );
      await tester.ensureVisible(find.widgetWithText(TextField, 'List item'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextField, 'List item'));
      await tester.pumpAndSettle();

      var count = 0;
      final printer = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => count++;
      debugPrintRebuildDirtyWidgets = true;
      // The first keystroke is the one that creates the item, and shows it on
      // the grid; the rest only edit it.
      tester.testTextInput.enterText('M');
      await tester.pump();
      count = 0;
      for (final value in ['Mi', 'Mil', 'Milk']) {
        tester.testTextInput.enterText(value);
        await tester.pump();
      }
      debugPrintRebuildDirtyWidgets = false;
      debugPrint = printer;

      expect(itemsOf('n1').last, 'Milk');
      // Measured at ~146 for the three keystrokes, against ~410 when each of
      // them rebuilt the list.
      expect(count, lessThan(300));
      await tester.pumpAndSettle();
      await flushTimers(tester);
    });

    testWidgets('ticking what is being written finishes it off the list', (
      tester,
    ) async {
      await openChecklist(tester);
      await tester.tap(find.widgetWithText(TextField, 'List item'));
      await tester.pump();
      tester.testTextInput.enterText('Milk');
      await tester.pump();

      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();

      final item = store.noteById('n1')!.items.single;
      expect(item.text, 'Milk');
      expect(item.done, isTrue);
      expect(find.text('1 checked item'), findsOneWidget);
      await flushTimers(tester);
    });

    // The composer reserves a fixed-width slot for the "+" that gives way to
    // a checkbox, so the swap can't nudge the field beside it. A Checkbox's
    // tap target shrink-wraps 8px narrower on desktop than on mobile, and a
    // slot that assumed the mobile size sat every item written into the
    // composer 4px right of the rows above it.
    testWidgets(
      'a new item lines up with the rows above it',
      (tester) async {
        await openChecklist(
          tester,
          items: [ChecklistItem(id: 'i1', text: 'Milk')],
        );
        await tester.tap(find.widgetWithText(TextField, 'List item'));
        await tester.pump();
        tester.testTextInput.enterText('Eggs');
        await tester.pumpAndSettle();

        // Tree order: the existing row, then the composer writing the new one.
        final boxes = find.byType(Checkbox);
        expect(boxes, findsNWidgets(2));
        final above = tester.getRect(boxes.first);
        final written = tester.getRect(boxes.at(1));
        expect(written.left, moreOrLessEquals(above.left));
        expect(written.width, moreOrLessEquals(above.width));
        expect(written.top - above.top, moreOrLessEquals(_rowHeight));
        await flushTimers(tester);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.macOS,
      }),
    );
  });
}

/// A one-line checklist row, as [AnimatedChecklist] lays it out.
const double _rowHeight = 48;
