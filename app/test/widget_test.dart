import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sticky_notes/models/note.dart';
import 'package:sticky_notes/screens/editor_screen.dart';
import 'package:sticky_notes/state/notes_store.dart';
import 'package:sticky_notes/state/settings_store.dart';
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

    testWidgets('tapping a checkbox row toggles the item without opening', (
      tester,
    ) async {
      api.notes['n1'] = serverNote(
        'n1',
        kind: NoteKind.checklist,
        items: [const ChecklistItem(id: 'i1', text: 'Milk')],
      );
      await store.load();
      await tester.pumpWidget(
        harness(
          store,
          SizedBox(width: 240, child: NoteTile(note: store.noteById('n1')!)),
        ),
      );

      await tester.tap(find.text('Milk'));
      await tester.pump();
      expect(store.noteById('n1')!.items.single.done, isTrue);
      // Editor did not open.
      expect(find.byType(EditorScreen), findsNothing);
      await flushTimers(tester);
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
}
