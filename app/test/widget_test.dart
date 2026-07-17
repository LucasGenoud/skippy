import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sticky_notes/api/api_client.dart';
import 'package:sticky_notes/models/note.dart';
import 'package:sticky_notes/screens/editor_screen.dart';
import 'package:sticky_notes/state/auth_store.dart';
import 'package:sticky_notes/screens/history_screen.dart';
import 'package:sticky_notes/screens/home_screen.dart';
import 'package:sticky_notes/state/notes_store.dart';
import 'package:sticky_notes/state/settings_store.dart';
import 'package:sticky_notes/theme.dart';
import 'package:sticky_notes/util/snack.dart';
import 'package:sticky_notes/widgets/animated_checklist.dart';
import 'package:sticky_notes/widgets/markdown_toolbar.dart';
import 'package:sticky_notes/widgets/masonry.dart';
import 'package:sticky_notes/widgets/note_card.dart';
import 'package:sticky_notes/widgets/quick_add_bar.dart';

import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote;

Widget harness(NotesStore store, Widget child) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: store),
      ChangeNotifierProvider(create: (_) => SettingsStore(api: store.api)),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

/// The full home screen, as the app builds it. The top bar's avatar menu
/// watches an [AuthStore], which only supports the concrete [ApiClient]; a
/// signed-out store over a dummy client renders fine and never talks to it.
Widget homeApp(NotesStore store) => MultiProvider(
  providers: [
    ChangeNotifierProvider.value(value: store),
    ChangeNotifierProvider(create: (_) => SettingsStore(api: store.api)),
    ChangeNotifierProvider(
      create: (_) => AuthStore(api: ApiClient(baseUrl: 'http://unused')),
    ),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.light),
    scaffoldMessengerKey: scaffoldMessengerKey,
    home: const HomeScreen(),
  ),
);

/// Flush the store's debounce (400ms) so no timers leak out of the test.
Future<void> flushTimers(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 700));
}

void main() {
  late FakeApi api;
  late NotesStore store;

  setUp(() {
    api = FakeApi();
    store = NotesStore(api: api, currentUserId: 'u-me');
  });

  tearDown(() => store.dispose());

  group('NoteTile', () {
    testWidgets('renders checklist preview with checked summary', (
      tester,
    ) async {
      api.notes['n1'] = serverNote(
        'n1',
        title: 'Groceries',
        kind: NoteKind.checklist,
        items: [
          const ChecklistItem(id: 'i1', text: 'Milk'),
          const ChecklistItem(id: 'i2', text: 'Eggs', done: true),
          const ChecklistItem(id: 'i3', text: 'Bread', done: true),
        ],
      );
      await store.load();
      await tester.pumpWidget(
        harness(
          store,
          SizedBox(width: 240, child: NoteTile(note: store.noteById('n1')!)),
        ),
      );

      expect(find.text('Groceries'), findsOneWidget);
      expect(find.text('Milk'), findsOneWidget);
      expect(find.text('2 checked items'), findsOneWidget);
      // Done items are summarized, not listed.
      expect(find.text('Eggs'), findsNothing);
    });

    testWidgets('markdown card renders formatted and clips long content', (
      tester,
    ) async {
      api.notes['n1'] = serverNote(
        'n1',
        title: 'Trip',
        kind: NoteKind.markdown,
        content:
            '# Plan\n**bold** move\n${List.generate(40, (i) => '- item $i').join('\n')}',
      );
      await store.load();
      await tester.pumpWidget(
        harness(
          store,
          SizedBox(width: 240, child: NoteTile(note: store.noteById('n1')!)),
        ),
      );
      // Rendered, not raw: the heading text appears without its marker.
      expect(find.textContaining('# Plan', findRichText: true), findsNothing);
      expect(find.textContaining('Plan', findRichText: true), findsWidgets);
      // Long content is height-clipped; no layout overflow errors were thrown
      // (the test would fail on any).
    });

    testWidgets('shows reminder chip and shared indicator', (tester) async {
      api.notes['n1'] = serverNote(
        'n1',
        title: 'x',
      ).copyWith(reminderAt: DateTime(2030, 5, 1, 9));
      api.notes['n1'] = api.notes['n1']!.copyWith(
        collaborators: [const UserRef(id: 'u2', username: 'bob')],
      );
      await store.load();
      await tester.pumpWidget(
        harness(
          store,
          SizedBox(width: 240, child: NoteTile(note: store.noteById('n1')!)),
        ),
      );
      expect(find.byIcon(Icons.alarm), findsOneWidget);
      expect(find.byIcon(Icons.people_alt_outlined), findsOneWidget);
      expect(find.textContaining('2030'), findsOneWidget);
    });
  });

  group('AnimatedMasonry drag reorder', () {
    testWidgets(
      'long-press drag to another tile reports the new order',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        final notes = [
          serverNote('a', title: 'AAA', position: 1),
          serverNote('b', title: 'BBB', position: 2),
          serverNote('c', title: 'CCC', position: 3),
          serverNote('d', title: 'DDD', position: 4),
        ];
        List<String>? reported;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: AnimatedMasonry(
                  notes: notes,
                  columns: 2,
                  onReorder: (ids) => reported = ids,
                  itemBuilder: (context, note) => SizedBox(
                    height: 80,
                    child: Card(child: Center(child: Text(note.title))),
                  ),
                ),
              ),
            ),
          ),
        );
        // Let tiles measure and settle.
        await tester.pumpAndSettle();

        final from = tester.getCenter(find.text('AAA'));
        final to = tester.getCenter(find.text('DDD'));
        final gesture = await tester.startGesture(from);
        // Desktop drag delay is 150ms; hold longer before moving.
        await tester.pump(const Duration(milliseconds: 300));
        await gesture.moveTo(to, timeStamp: const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 100));
        await gesture.up();
        await tester.pumpAndSettle();

        expect(reported, isNotNull);
        expect(reported, isNot(['a', 'b', 'c', 'd']));
        expect(reported!.toSet(), {'a', 'b', 'c', 'd'});
      },
    );
  });

  group('QuickAddBar', () {
    testWidgets('type and Close creates the note', (tester) async {
      await store.load();
      await tester.pumpWidget(harness(store, const QuickAddBar()));

      await tester.tap(find.text('Take a note…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Quick');
      await tester.enterText(
        find.widgetWithText(TextField, 'Take a note…'),
        'body text',
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      final note = store.notesFor(ViewSelection.notes, '').others.single;
      expect(note.title, 'Quick');
      expect(note.content, 'body text');
      // Composer collapsed back to the bar.
      expect(find.text('Close'), findsNothing);
      await flushTimers(tester);
      expect(api.notes[note.id]!.title, 'Quick');
    });

    testWidgets('closing an empty composer creates nothing', (tester) async {
      await store.load();
      await tester.pumpWidget(harness(store, const QuickAddBar()));
      await tester.tap(find.text('Take a note…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(store.notesFor(ViewSelection.notes, '').others, isEmpty);
      await flushTimers(tester);
      expect(api.notes, isEmpty);
    });

    testWidgets('tapping outside the composer saves', (tester) async {
      await store.load();
      await tester.pumpWidget(
        harness(
          store,
          const Column(children: [QuickAddBar(), SizedBox(height: 400)]),
        ),
      );
      await tester.tap(find.text('Take a note…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Take a note…'),
        'drive-by note',
      );
      await tester.tapAt(const Offset(400, 550)); // well below the bar
      await tester.pumpAndSettle();
      final note = store.notesFor(ViewSelection.notes, '').others.single;
      expect(note.content, 'drive-by note');
      expect(find.text('Close'), findsNothing);
      await flushTimers(tester);
    });

    testWidgets('Escape saves and collapses', (tester) async {
      await store.load();
      await tester.pumpWidget(harness(store, const QuickAddBar()));
      await tester.tap(find.text('Take a note…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Take a note…'),
        'esc note',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        store.notesFor(ViewSelection.notes, '').others.single.content,
        'esc note',
      );
      expect(find.text('Close'), findsNothing);
      await flushTimers(tester);
    });

    testWidgets('checklist icon composes a checklist inline, not in a popup', (
      tester,
    ) async {
      await store.load();
      await tester.pumpWidget(harness(store, const QuickAddBar()));

      await tester.tap(find.byTooltip('New checklist'));
      await tester.pumpAndSettle();

      // Editing happens in the bar itself — no editor route is pushed.
      expect(find.byType(AnimatedChecklist), findsOneWidget);
      expect(find.byType(EditorScreen), findsNothing);

      await tester.enterText(
        find.widgetWithText(TextField, 'List item'),
        'Milk',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'List item'),
        'Eggs',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      final note = store.notesFor(ViewSelection.notes, '').others.single;
      expect(note.kind, NoteKind.checklist);
      expect(note.items.map((i) => i.text), ['Milk', 'Eggs']);
      await flushTimers(tester);
    });

    testWidgets('markdown icon composes markdown inline with a toolbar', (
      tester,
    ) async {
      await store.load();
      await tester.pumpWidget(harness(store, const QuickAddBar()));

      await tester.tap(find.byTooltip('New markdown note'));
      await tester.pumpAndSettle();

      expect(find.byType(MarkdownToolbar), findsOneWidget);
      expect(find.byType(EditorScreen), findsNothing);

      await tester.enterText(
        find.widgetWithText(TextField, 'Markdown…'),
        'hello',
      );
      // Bold with no selection drops the markers in at the caret.
      await tester.tap(find.byTooltip('Bold'));
      await tester.pump();

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      final note = store.notesFor(ViewSelection.notes, '').others.single;
      expect(note.kind, NoteKind.markdown);
      expect(note.content, 'hello****');
      await flushTimers(tester);
    });
  });

  group('EditorScreen', () {
    testWidgets('typing in a fresh editor creates the note; closing keeps it', (
      tester,
    ) async {
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: null)));
      await tester.enterText(
        find.widgetWithText(TextField, 'Note'),
        'hello world',
      );
      await tester.pump();

      final visible = store.notesFor(ViewSelection.notes, '').others;
      expect(visible, hasLength(1));
      expect(visible.single.content, 'hello world');
      await flushTimers(tester);
      expect(api.notes[visible.single.id]!.content, 'hello world');
    });

    testWidgets('untouched new editor leaves no note behind', (tester) async {
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: null)));
      await tester.pumpWidget(harness(store, const SizedBox())); // close
      await flushTimers(tester);
      expect(store.notesFor(ViewSelection.notes, '').others, isEmpty);
      expect(api.notes, isEmpty);
    });

    testWidgets('checklist editor: typing suggestions from history add items', (
      tester,
    ) async {
      api.notes['n1'] = serverNote('n1', kind: NoteKind.checklist);
      api.history = {
        'n1': ['Milk', 'Almond milk', 'Eggs'],
      };
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      await tester.pump();

      // Focusing the new-item field surfaces this note's history right away.
      await tester.tap(find.widgetWithText(TextField, 'List item'));
      await tester.pump();
      expect(find.text('Milk'), findsOneWidget);
      expect(find.text('Eggs'), findsOneWidget);

      // Typing narrows the suggestions.
      await tester.enterText(
        find.widgetWithText(TextField, 'List item'),
        'alm',
      );
      await tester.pump();
      expect(find.text('Almond milk'), findsOneWidget);
      expect(find.text('Eggs'), findsNothing);

      // Tapping a suggestion adds the item.
      await tester.tap(find.text('Almond milk'));
      await tester.pump();
      final note = store.noteById('n1')!;
      expect(note.items.single.text, 'Almond milk');
      expect(note.isChecklist, isTrue);
      await flushTimers(tester);
    });

    testWidgets('a new checklist never suggests from other notes', (
      tester,
    ) async {
      // Another note has rich history; a brand-new checklist must not see it.
      api.notes['other'] = serverNote('other', kind: NoteKind.checklist);
      api.history = {
        'other': ['Milk', 'Eggs'],
      };
      await store.load();
      await tester.pumpWidget(
        harness(
          store,
          const EditorScreen(noteId: null, kind: NoteKind.checklist),
        ),
      );
      await tester.pump();

      // New-item field is focused; no foreign suggestions appear.
      expect(find.text('Milk'), findsNothing);
      await tester.enterText(find.widgetWithText(TextField, 'List item'), 'mi');
      await tester.pump();
      expect(find.text('Milk'), findsNothing);
      await flushTimers(tester);
    });

    testWidgets(
      'checking an item moves it to the checked section, still visible',
      (tester) async {
        api.notes['n1'] = serverNote(
          'n1',
          kind: NoteKind.checklist,
          items: [
            const ChecklistItem(id: 'a', text: 'Apples'),
            const ChecklistItem(id: 'b', text: 'Bananas'),
          ],
        );
        await store.load();
        await tester.pumpWidget(
          harness(store, const EditorScreen(noteId: 'n1')),
        );
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('checked item'), findsNothing);
        await tester.tap(find.byType(Checkbox).first);
        await tester.pump(const Duration(milliseconds: 300)); // glide animation
        await tester.pump(const Duration(milliseconds: 300));

        // Item is done, has moved below the header, and is still visible.
        expect(
          store.noteById('n1')!.items.firstWhere((i) => i.id == 'a').done,
          isTrue,
        );
        expect(find.text('1 checked item'), findsOneWidget);
        expect(find.text('Apples'), findsOneWidget);
        await flushTimers(tester);
      },
    );

    testWidgets('drag handle reorders checklist items', (tester) async {
      api.notes['n1'] = serverNote(
        'n1',
        kind: NoteKind.checklist,
        items: [
          const ChecklistItem(id: 'a', text: 'Apples'),
          const ChecklistItem(id: 'b', text: 'Bananas'),
          const ChecklistItem(id: 'c', text: 'Carrots'),
        ],
      );
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      // Let rows measure their real heights first.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      // Drag the first row's handle well past the next two rows — pumping
      // between moves like a real browser does, so mid-gesture rebuilds
      // (which once canceled the drag) are exercised.
      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.drag_indicator).first),
      );
      for (var step = 0; step < 8; step++) {
        await gesture.moveBy(const Offset(0, 20));
        await tester.pump(const Duration(milliseconds: 30));
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));

      final order = [for (final i in store.noteById('n1')!.items) i.id];
      expect(order.first, isNot('a'));
      expect(order.toSet(), {'a', 'b', 'c'});
      await flushTimers(tester);
    });

    testWidgets(
      'typing in an existing row pops suggestions; tap replaces text',
      (tester) async {
        api.history = {
          'n1': ['Chocolate', 'Chips'],
        };
        api.notes['n1'] = serverNote(
          'n1',
          kind: NoteKind.checklist,
          items: [const ChecklistItem(id: 'a', text: 'Apples')],
        );
        await store.load();
        await tester.pumpWidget(
          harness(store, const EditorScreen(noteId: 'n1')),
        );
        await tester.pump(const Duration(milliseconds: 50));

        // No popup on mere focus of an existing row...
        final row = find.widgetWithText(TextField, 'Apples');
        await tester.tap(row);
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.text('Chocolate'), findsNothing);

        // ...but typing opens it, with matches from history.
        await tester.enterText(row, 'ch');
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.text('Chocolate'), findsOneWidget);
        expect(find.text('Chips'), findsOneWidget);

        await tester.tap(find.text('Chips'));
        await tester.pump(const Duration(milliseconds: 50));
        expect(store.noteById('n1')!.items.single.text, 'Chips');
        await flushTimers(tester);
      },
    );

    testWidgets('a checked-off item is offered back as a suggestion', (
      tester,
    ) async {
      api.notes['n1'] = serverNote(
        'n1',
        kind: NoteKind.checklist,
        items: [const ChecklistItem(id: 'a', text: 'Milk')],
      );
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      await tester.pump(const Duration(milliseconds: 50));

      // Check it off — it stays on the list, struck through, and remembered.
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byIcon(Icons.history), findsNothing);

      // Focusing the new-item row now suggests the checked item back, so it
      // can be re-added — this is what was broken (checked items stayed on
      // the list and so were wrongly excluded from their own suggestions).
      await tester.tap(find.widgetWithText(TextField, 'List item'));
      await tester.pump();
      expect(find.byIcon(Icons.history), findsOneWidget);
      await flushTimers(tester);
    });

    testWidgets('undo and redo walk the editor history', (tester) async {
      api.notes['n1'] = serverNote('n1', title: 'T', content: 'hello');
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      await tester.pump(const Duration(milliseconds: 50));

      await tester.enterText(
        find.widgetWithText(TextField, 'hello'),
        'hello world',
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(store.noteById('n1')!.content, 'hello world');

      await tester.tap(find.byIcon(Icons.undo));
      await tester.pump(const Duration(milliseconds: 50));
      expect(store.noteById('n1')!.content, 'hello');

      await tester.tap(find.byIcon(Icons.redo));
      await tester.pump(const Duration(milliseconds: 50));
      expect(store.noteById('n1')!.content, 'hello world');
      await flushTimers(tester);
    });

    testWidgets('undo reverts a checkbox toggle as its own step', (
      tester,
    ) async {
      api.notes['n1'] = serverNote(
        'n1',
        kind: NoteKind.checklist,
        items: [const ChecklistItem(id: 'a', text: 'Apples')],
      );
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byType(Checkbox).first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(store.noteById('n1')!.items.single.done, isTrue);

      await tester.tap(find.byIcon(Icons.undo));
      await tester.pump(const Duration(milliseconds: 300));
      expect(store.noteById('n1')!.items.single.done, isFalse);
      await flushTimers(tester);
    });

    testWidgets('find-in-note reports match count', (tester) async {
      api.notes['n1'] = serverNote(
        'n1',
        title: 'q',
        content: 'cat dog cat CAT',
      );
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      await tester.tap(find.byIcon(Icons.search));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'Find in note'),
        'cat',
      );
      await tester.pump();
      expect(find.text('3 found'), findsOneWidget);
      await flushTimers(tester);
    });
  });

  group('MarkdownToolbar', () {
    Future<TextEditingController> pumpToolbar(
      WidgetTester tester,
      String text,
      TextSelection selection,
    ) async {
      final controller = TextEditingController(text: text)
        ..selection = selection;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MarkdownToolbar(controller: controller)),
        ),
      );
      return controller;
    }

    testWidgets('wraps the current selection in bold markers', (tester) async {
      final controller = await pumpToolbar(
        tester,
        'make me bold',
        const TextSelection(baseOffset: 8, extentOffset: 12),
      );
      await tester.tap(find.byTooltip('Bold'));
      await tester.pump();
      expect(controller.text, 'make me **bold**');
      // The wrapped word stays selected so it can be re-styled.
      expect(controller.selection.textInside(controller.text), 'bold');
      controller.dispose();
    });

    testWidgets('drops markers at the caret when nothing is selected', (
      tester,
    ) async {
      final controller = await pumpToolbar(
        tester,
        'x',
        const TextSelection.collapsed(offset: 1),
      );
      await tester.tap(find.byTooltip('Italic'));
      await tester.pump();
      expect(controller.text, 'x__');
      // Caret parked between the markers.
      expect(controller.selection.baseOffset, 2);
      controller.dispose();
    });

    testWidgets('sets and re-levels the heading on the caret line', (
      tester,
    ) async {
      final controller = await pumpToolbar(
        tester,
        'Groceries',
        const TextSelection.collapsed(offset: 3),
      );
      await tester.tap(find.byTooltip('Heading 2'));
      await tester.pump();
      expect(controller.text, '## Groceries');
      // Re-leveling replaces the marker instead of stacking it.
      await tester.tap(find.byTooltip('Heading 1'));
      await tester.pump();
      expect(controller.text, '# Groceries');
      controller.dispose();
    });

    testWidgets('inserts a link with the url placeholder selected', (
      tester,
    ) async {
      final controller = await pumpToolbar(
        tester,
        'see Flutter',
        const TextSelection(baseOffset: 4, extentOffset: 11),
      );
      await tester.tap(find.byTooltip('Link'));
      await tester.pump();
      expect(controller.text, 'see [Flutter](url)');
      expect(controller.selection.textInside(controller.text), 'url');
      controller.dispose();
    });
  });

  group('home screen layout', () {
    testWidgets(
      'note FABs stay out of the Scaffold slot so snackbars hug the bottom',
      (tester) async {
        await store.load();
        await tester.pumpWidget(homeApp(store));
        await tester.pump();

        // The tall note-creation FAB column must not sit in the Scaffold's
        // floatingActionButton slot: a floating SnackBar is laid out *above*
        // that slot, which used to shove notifications into the middle of the
        // screen. The FABs live in the body instead.
        final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
        expect(scaffold.floatingActionButton, isNull);
        expect(find.byIcon(Icons.add), findsWidgets); // FABs still rendered

        showAppSnack('saved');
        await tester.pump(); // build the snackbar
        await tester.pump(const Duration(milliseconds: 750)); // finish entrance

        final appHeight = tester.getSize(find.byType(MaterialApp)).height;
        final snackBottom = tester.getRect(find.byType(SnackBar)).bottom;
        expect(
          appHeight - snackBottom,
          lessThan(60),
          reason: 'snackbar should hug the bottom, not float above the FABs',
        );

        scaffoldMessengerKey.currentState!.clearSnackBars();
        await flushTimers(tester);
      },
    );

    testWidgets('top bar and FABs respect device safe-area insets', (
      tester,
    ) async {
      // iPhone-style insets: 50px status bar/notch, 34px home indicator
      // (physical px at the test binding's 3.0 device pixel ratio).
      tester.view.padding = const FakeViewPadding(top: 150, bottom: 102);
      tester.view.viewPadding = const FakeViewPadding(top: 150, bottom: 102);
      addTearDown(tester.view.reset);

      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pump();

      // The top bar's content starts below the notch…
      final menuTop = tester.getTopLeft(find.byIcon(Icons.menu)).dy;
      expect(
        menuTop,
        greaterThanOrEqualTo(50),
        reason: 'top bar must sit below the status-bar inset',
      );

      // …and the note FABs sit above the home indicator.
      final appHeight = tester.getSize(find.byType(MaterialApp)).height;
      final fabBottom = tester.getRect(find.byIcon(Icons.add).last).bottom;
      expect(
        appHeight - fabBottom,
        greaterThanOrEqualTo(34),
        reason: 'FABs must stay above the home-indicator inset',
      );
    });

    testWidgets('phone width collapses the top bar into one search pill', (
      tester,
    ) async {
      // iPhone-sized logical viewport (402x874).
      tester.view.physicalSize = const Size(1206, 2622);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pump();

      // Branding and the sort icon leave the bar (drawer / avatar menu
      // carry them); the essentials stay.
      expect(find.text('Sticky Notes'), findsNothing);
      expect(find.byIcon(Icons.swap_vert), findsNothing);
      expect(find.byIcon(Icons.menu), findsOneWidget);
      expect(find.byIcon(Icons.view_agenda_outlined), findsOneWidget);
      expect(find.byType(CircleAvatar), findsOneWidget);

      // Typing swaps the trailing icons for the clear button.
      await tester.enterText(find.byType(TextField).first, 'milk');
      await tester.pump();
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.byIcon(Icons.view_agenda_outlined), findsNothing);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      // Sort now lives in the avatar menu, opening a bottom sheet.
      await tester.tap(find.byType(CircleAvatar).first);
      await tester.pumpAndSettle();
      expect(find.text('Sort by'), findsOneWidget);
      await tester.tap(find.text('Sort by'));
      await tester.pumpAndSettle();
      expect(find.text('Recently edited'), findsOneWidget);
      await tester.tap(find.text('Recently edited'));
      await tester.pumpAndSettle();
      expect(store.sortMode, SortMode.edited);

      // The pill's menu button opens the drawer (via the scaffold key — the
      // old Scaffold.of(context) lookup threw above the Scaffold).
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationDrawer), findsOneWidget);
    });
  });

  group('keyboard shortcuts', () {
    // 1200px: comfortably in the wide layout (quick add + modal editor), and
    // clear of the known _TopBar overflow at the default 800px test surface.
    Future<void> pumpHome(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pump();
    }

    bool editingText() =>
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorStateOfType<EditableTextState>() !=
        null;

    testWidgets('n, l and m open the matching editor kind from idle', (
      tester,
    ) async {
      await pumpHome(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape); // dismiss modal
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsNothing);

      // Focus returns to the page after the modal closes, so the next
      // shortcut works without clicking anywhere first.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pumpAndSettle();
      expect(find.byType(AnimatedChecklist), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownToolbar), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await flushTimers(tester);
    });

    testWidgets('letters typed into the quick add stay in the field', (
      tester,
    ) async {
      await pumpHome(tester);

      await tester.tap(find.text('Take a note…'));
      await tester.pumpAndSettle();
      expect(editingText(), isTrue);

      // The reported bug: pressing "n" while composing opened a new-note
      // modal instead of typing an "n".
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pump();
      expect(find.byType(EditorScreen), findsNothing);
      expect(find.text('Close'), findsOneWidget); // composer still open

      // Escape stays the quick add's own shortcut: save and collapse.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Close'), findsNothing);
      expect(find.byType(EditorScreen), findsNothing);
      await flushTimers(tester);
    });

    testWidgets('/ focuses search; keys there type instead of firing', (
      tester,
    ) async {
      await pumpHome(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.slash, character: '/');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.slash);
      await tester.pump();
      expect(editingText(), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pump();
      expect(find.byType(EditorScreen), findsNothing);

      // Escape clears the query and hands focus back to the page.
      await tester.enterText(find.byType(TextField).first, 'zzz');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('zzz'), findsNothing);
      expect(editingText(), isFalse);
      await flushTimers(tester);
    });

    testWidgets('? opens the shortcut cheat sheet', (tester) async {
      await pumpHome(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.slash, character: '?');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.slash);
      await tester.pumpAndSettle();
      expect(find.text('Keyboard shortcuts'), findsOneWidget);
      expect(find.text('New checklist'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Keyboard shortcuts'), findsNothing);
    });

    testWidgets('Ctrl+G toggles the grid/list layout', (tester) async {
      await pumpHome(tester);

      expect(find.byTooltip('List view'), findsOneWidget); // grid active
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.byTooltip('Grid view'), findsOneWidget); // list active
    });
  });

  group('NoteHistoryScreen', () {
    Widget historyHarness(NotesStore store) {
      return MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: store),
          ChangeNotifierProvider(create: (_) => SettingsStore(api: store.api)),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => NoteHistoryScreen.open(context, 'n1'),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('lists versions, marks current, and restores', (tester) async {
      api.notes['n1'] = serverNote('n1', title: 'Plan', content: 'v3 body');
      api.versions['n1'] = [
        NoteVersion(
          id: 'v2',
          noteId: 'n1',
          title: 'Plan',
          content: 'v2 body',
          createdAt: DateTime(2026, 7, 15, 9),
        ),
        NoteVersion(
          id: 'v1',
          noteId: 'n1',
          title: 'Plan',
          content: 'v1 body',
          createdAt: DateTime(2026, 7, 14, 8),
        ),
      ];
      await store.load();
      await tester.pumpWidget(historyHarness(store));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Current state sits on top; both past versions are listed with a
      // Restore action each (the current card has none).
      expect(find.text('Current'), findsOneWidget);
      expect(find.text('v3 body'), findsOneWidget);
      expect(find.text('v2 body'), findsOneWidget);
      expect(find.text('v1 body'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Restore'), findsNWidgets(2));

      // Restoring the oldest asks for confirmation, then rolls content back.
      await tester.tap(find.widgetWithText(TextButton, 'Restore').last);
      await tester.pumpAndSettle();
      expect(find.text('Restore this version?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
      await tester.pumpAndSettle();

      expect(api.log, contains('restoreVersion:n1:v1'));
      expect(store.noteById('n1')!.content, 'v1 body');
    });

    testWidgets('shows an empty state when there is no history', (
      tester,
    ) async {
      api.notes['n1'] = serverNote('n1', title: 'Fresh');
      api.versions['n1'] = const [];
      await store.load();
      await tester.pumpWidget(historyHarness(store));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Current'), findsOneWidget);
      expect(find.textContaining('No earlier versions yet'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Restore'), findsNothing);
    });
  });
}
