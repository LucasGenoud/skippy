import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/api/api_client.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/screens/editor_screen.dart';
import 'package:skippy/state/auth_store.dart';
import 'package:skippy/screens/history_screen.dart';
import 'package:skippy/screens/home_screen.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/state/settings_store.dart';
import 'package:skippy/theme.dart';
import 'package:skippy/util/snack.dart';
import 'package:skippy/widgets/animated_checklist.dart';
import 'package:skippy/widgets/app_drawer.dart';
import 'package:skippy/widgets/home_top_bar.dart';
import 'package:skippy/widgets/markdown_toolbar.dart';
import 'package:skippy/widgets/masonry.dart';
import 'package:skippy/widgets/note_card.dart';
import 'package:skippy/widgets/quick_add_bar.dart';
import 'package:skippy/widgets/skeleton.dart';

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
        collaborators: [const UserRef(id: 'u2', name: 'bob')],
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

    testWidgets('shared notes show their external owner with an ellipsis', (
      tester,
    ) async {
      api.notes['n1'] =
          serverNote(
            'n1',
            title: 'Shared note',
            owner: const UserRef(id: 'u-owner', name: 'abcdefghijklmnopq'),
          ).copyWith(
            collaborators: [const UserRef(id: 'u-me', name: 'me')],
          );
      await store.load();
      await tester.pumpWidget(
        harness(
          store,
          SizedBox(width: 240, child: NoteTile(note: store.noteById('n1')!)),
        ),
      );

      expect(find.byIcon(Icons.people_alt_outlined), findsOneWidget);
      expect(find.text('abcdefghijklmno…'), findsOneWidget);
      expect(find.byTooltip('Shared by abcdefghijklmnopq'), findsOneWidget);
    });

    testWidgets(
      'desktop hover reveals the reserved note action footer',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        api.notes['n1'] = serverNote(
          'n1',
          title: 'Desktop actions',
          content: 'Body',
        );
        await store.load();
        await tester.pumpWidget(
          harness(
            store,
            SizedBox(width: 240, child: NoteTile(note: store.noteById('n1')!)),
          ),
        );

        final actions = find.byKey(const ValueKey('note-actions-n1'));
        expect(tester.widget<AnimatedOpacity>(actions).opacity, 0);
        final cardBottom = tester.getRect(find.byType(NoteTile)).bottom;
        final titleBottom = tester.getRect(find.text('Desktop actions')).bottom;
        expect(cardBottom - titleBottom, greaterThanOrEqualTo(48));

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(() => mouse.removePointer());
        await mouse.addPointer(
          location: tester.getCenter(find.byType(NoteTile)),
        );
        await tester.pumpAndSettle();

        expect(tester.widget<AnimatedOpacity>(actions).opacity, 1);
        expect(find.byTooltip('Note color'), findsOneWidget);
        expect(find.byTooltip('Add label'), findsOneWidget);
        expect(find.byTooltip('Add reminder'), findsOneWidget);
        expect(find.byTooltip('Add image'), findsOneWidget);
        expect(find.byTooltip('Archive note'), findsOneWidget);
        expect(find.byTooltip('More note options'), findsOneWidget);
        expect(find.byIcon(Icons.more_vert), findsOneWidget);

        await tester.tap(find.byTooltip('More note options'));
        await tester.pumpAndSettle();
        expect(find.text('Share'), findsOneWidget);
        expect(find.text('Move to Trash'), findsOneWidget);
        expect(find.text('Clean up and make concise'), findsNothing);
        expect(find.text('Fix grammar and syntax'), findsNothing);
        // Moving into the menu makes the card lose hover, but its action row
        // remains visible until the menu closes.
        await mouse.moveTo(Offset.zero);
        await tester.pump();
        expect(tester.widget<AnimatedOpacity>(actions).opacity, 1);
        await tester.tap(find.text('Move to Trash'));
        await tester.pump();
        expect(store.noteById('n1')!.trashed, isTrue);
        await flushTimers(tester);
      },
    );
    testWidgets(
      'desktop note menu exposes enabled AI editing actions',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        api.notes['n1'] = serverNote(
          'n1',
          title: 'AI actions',
          content: 'this sentence needs fixing',
        );
        await store.load();
        final settings = SettingsStore(api: api)
          ..llmBaseUrl = 'http://fake/v1'
          ..llmModel = 'test-model'
          ..llmWritingEnabled = true;
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: store),
              ChangeNotifierProvider.value(value: settings),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 240,
                  child: NoteTile(note: store.noteById('n1')!),
                ),
              ),
            ),
          ),
        );

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(() => mouse.removePointer());
        await mouse.addPointer(
          location: tester.getCenter(find.byType(NoteTile)),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('More note options'));
        await tester.pumpAndSettle();
        expect(find.text('Clean up and make concise'), findsOneWidget);
        expect(find.text('Fix grammar and syntax'), findsOneWidget);

        api.rewriteGate = Completer<void>();
        await tester.tap(find.text('Fix grammar and syntax'));
        await tester.pump();
        expect(find.byKey(const ValueKey('note-rewrite-progress')), findsOne);
        expect(api.log, isNot(contains('rewriteNote:n1:grammar')));

        api.rewriteGate!.complete();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('note-rewrite-progress')),
          findsNothing,
        );
        expect(api.log, contains('rewriteNote:n1:grammar'));
        expect(
          store.noteById('n1')!.content,
          'Corrected: this sentence needs fixing',
        );
      },
    );
    testWidgets(
      'desktop cards show labels in the reserved footer before hover actions',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        api.labels['l1'] = const Label(id: 'l1', name: 'Work');
        api.notes['n1'] = serverNote(
          'n1',
          title: 'Desktop labels',
          labelIds: const {'l1'},
        );
        await store.load();
        await tester.pumpWidget(
          harness(
            store,
            SizedBox(width: 240, child: NoteTile(note: store.noteById('n1')!)),
          ),
        );

        expect(find.text('Work'), findsOneWidget);
        expect(find.textContaining('Edited'), findsNothing);
        final footer = tester.widget<AnimatedOpacity>(
          find.byKey(const ValueKey('note-footer-labels-n1')),
        );
        expect(footer.opacity, 1);

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(() => mouse.removePointer());
        await mouse.addPointer(
          location: tester.getCenter(find.byType(NoteTile)),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<AnimatedOpacity>(
                find.byKey(const ValueKey('note-footer-labels-n1')),
              )
              .opacity,
          0,
        );
      },
    );

    testWidgets(
      'desktop card footer compacts overflowing labels to colored icons',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        api.labels['l1'] = const Label(
          id: 'l1',
          name: 'Very long work label',
          color: '#d44a3f',
          icon: 'work',
        );
        api.labels['l2'] = const Label(
          id: 'l2',
          name: 'Another lengthy travel label',
          color: '#2878d4',
          icon: 'travel',
        );
        api.labels['l3'] = const Label(
          id: 'l3',
          name: 'One more label that cannot fit',
          color: '#3c9b62',
          icon: 'home',
        );
        api.notes['n1'] = serverNote(
          'n1',
          title: 'Compact labels',
          labelIds: const {'l1', 'l2', 'l3'},
        );
        await store.load();
        await tester.pumpWidget(
          harness(
            store,
            SizedBox(width: 240, child: NoteTile(note: store.noteById('n1')!)),
          ),
        );

        expect(find.text('Very long work label'), findsNothing);
        expect(
          find.byKey(const ValueKey('note-footer-label-marker-n1-0')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('note-footer-label-marker-n1-1')),
          findsOneWidget,
        );
        expect(find.textContaining('Edited'), findsNothing);
        final cardRect = tester.getRect(find.byType(NoteTile));
        final markerRect = tester.getRect(
          find.byKey(const ValueKey('note-footer-label-marker-n1-0')),
        );
        expect(markerRect.left, closeTo(cardRect.left + 16, 0.1));
        expect(markerRect.bottom, closeTo(cardRect.bottom - 16, 0.1));
        final decoratedBox = tester.widget<DecoratedBox>(
          find.descendant(
            of: find.byKey(const ValueKey('note-footer-label-marker-n1-0')),
            matching: find.byType(DecoratedBox),
          ),
        );
        final decoration = decoratedBox.decoration as BoxDecoration;
        expect(decoration.color, isNotNull);
        expect(decoration.border, isNotNull);
      },
    );
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
      await tester.pump(const Duration(milliseconds: 1));
      // Losing focus should return the space to the grid in the same frame;
      // opening remains animated, but an outside click must not feel delayed.
      expect(find.text('Close'), findsNothing);
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

    testWidgets('Tab moves from the quick-note title to its content', (
      tester,
    ) async {
      await store.load();
      await tester.pumpWidget(harness(store, const QuickAddBar()));
      await tester.tap(find.text('Take a note…'));
      await tester.pumpAndSettle();

      final title = find.widgetWithText(TextField, 'Title');
      await tester.tap(title);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      final content = tester.widget<EditableText>(
        find.descendant(
          of: find.widgetWithText(TextField, 'Take a note…'),
          matching: find.byType(EditableText),
        ),
      );
      expect(content.focusNode.hasFocus, isTrue);
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

      // Typing in the add field materializes a real item on the first
      // keystroke, then the field clears itself for the next one.
      await tester.enterText(
        find.widgetWithText(TextField, 'List item'),
        'Milk',
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'List item'),
        'Eggs',
      );
      await tester.pumpAndSettle();

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

    testWidgets('archive lives in the editor bottom actions after sharing', (
      tester,
    ) async {
      api.notes['n1'] = serverNote('n1', title: 'Archive me');
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      await tester.pump();

      final share = find.byTooltip('Collaborators');
      final archive = find.byTooltip('Archive');
      expect(share, findsOneWidget);
      expect(archive, findsOneWidget);
      expect(
        tester.getCenter(archive).dx,
        greaterThan(tester.getCenter(share).dx),
      );
      expect(
        tester.getCenter(archive).dy,
        greaterThan(tester.getCenter(find.byType(AppBar)).dy),
      );
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
      final suggestions = tester.widget<ListView>(
        find.byKey(const Key('checklist-suggestions')),
      );
      expect(suggestions.primary, isFalse);
      expect(suggestions.controller, isNotNull);

      // Typing materializes a real row on the first keystroke and hands focus
      // to it; its popup keeps narrowing the suggestions.
      await tester.enterText(
        find.widgetWithText(TextField, 'List item'),
        'alm',
      );
      await tester.pumpAndSettle();
      expect(store.noteById('n1')!.items.map((i) => i.text), ['alm']);
      expect(find.text('Almond milk'), findsOneWidget);
      expect(find.text('Eggs'), findsNothing);

      // Tapping a suggestion fills the row it was typed on.
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
      'fast per-keystroke typing lands on a single item, not one per char',
      (tester) async {
        // The add field materializes a real row on the first keystroke and
        // hands focus to it a couple of frames later; a fast typist's next
        // keys can still hit the (cleared) add field before then. They must
        // append to that row, never spawn a new item per character.
        api.notes['n1'] = serverNote('n1', kind: NoteKind.checklist);
        await store.load();
        await tester.pumpWidget(
          harness(store, const EditorScreen(noteId: 'n1')),
        );
        await tester.pump();

        await tester.tap(find.widgetWithText(TextField, 'List item'));
        await tester.pump();

        // One char per single frame — outrunning the focus handoff.
        for (final ch in 'Milk'.split('')) {
          final focused = tester
              .widgetList<EditableText>(find.byType(EditableText))
              .firstWhere((e) => e.focusNode.hasFocus);
          tester.testTextInput.enterText(focused.controller.text + ch);
          await tester.pump();
        }
        await tester.pumpAndSettle();

        expect(store.noteById('n1')!.items.map((i) => i.text), ['Milk']);
        await flushTimers(tester);
      },
    );

    testWidgets(
      'checklist row keeps its first character across the focus handoff',
      (tester) async {
        api.notes['n1'] = serverNote('n1', kind: NoteKind.checklist);
        await store.load();
        await tester.pumpWidget(
          harness(store, const EditorScreen(noteId: 'n1')),
        );
        await tester.pump();

        final addField = find.widgetWithText(TextField, 'List item');
        await tester.tap(addField);
        tester.testTextInput.enterText('M');
        await tester.pump();
        await tester.pump();

        // Reproduce the desktop race: the input client reports only the next
        // character after focus moves, rather than the accumulated value.
        final focused = tester
            .widgetList<EditableText>(find.byType(EditableText))
            .singleWhere((field) => field.focusNode.hasFocus);
        expect(focused.controller.text, 'M');
        tester.testTextInput.enterText('i');
        await tester.pump();

        expect(store.noteById('n1')!.items.single.text, 'Mi');
        await flushTimers(tester);
      },
    );

    testWidgets(
      'a long checklist row returns to its start after focus leaves',
      (tester) async {
        final longItem = List.filled(
          12,
          'This is a very long checklist item that cannot fit on one row',
        ).join(' ');
        api.notes['n1'] = serverNote(
          'n1',
          kind: NoteKind.checklist,
          items: [ChecklistItem(id: 'i1', text: longItem)],
        );
        await store.load();
        await tester.pumpWidget(
          harness(store, const EditorScreen(noteId: 'n1')),
        );
        await tester.pump(const Duration(milliseconds: 100));

        final row = find.widgetWithText(TextField, longItem);
        final editable = tester.widget<EditableText>(
          find.descendant(of: row, matching: find.byType(EditableText)),
        );
        final horizontalScroll = editable.scrollController!;
        await tester.tap(row);
        expect(editable.focusNode.hasFocus, isTrue);
        tester.testTextInput.enterText('$longItem with more text');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(horizontalScroll.position.maxScrollExtent, greaterThan(0));
        horizontalScroll.jumpTo(horizontalScroll.position.maxScrollExtent);
        expect(horizontalScroll.offset, greaterThan(0));

        await tester.tap(find.widgetWithText(TextField, 'Title'));
        await tester.pump();
        await tester.pump();
        expect(horizontalScroll.offset, 0);
        await flushTimers(tester);
      },
    );

    testWidgets(
      'backspace on an empty row focuses the previous one with a collapsed '
      'caret at the end (no select-all)',
      (tester) async {
        api.notes['n1'] = serverNote(
          'n1',
          kind: NoteKind.checklist,
          items: [
            const ChecklistItem(id: 'a', text: 'Milk'),
            const ChecklistItem(id: 'b', text: ''),
          ],
        );
        await store.load();
        await tester.pumpWidget(
          harness(store, const EditorScreen(noteId: 'n1')),
        );
        await tester.pump(const Duration(milliseconds: 100));

        final rows = find.descendant(
          of: find.byType(AnimatedChecklist),
          matching: find.byType(TextField),
        );
        await tester.tap(rows.at(1)); // the empty row
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await tester.pumpAndSettle();

        expect(store.noteById('n1')!.items.map((i) => i.text), ['Milk']);
        final milk = tester.widget<EditableText>(
          find.descendant(
            of: find.widgetWithText(TextField, 'Milk'),
            matching: find.byType(EditableText),
          ),
        );
        expect(milk.controller.selection.isCollapsed, isTrue);
        expect(milk.controller.selection.baseOffset, 4);
        await flushTimers(tester);
      },
    );

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

    testWidgets('reminder time picker follows the 12/24-hour setting', (
      tester,
    ) async {
      api.notes['n1'] = serverNote('n1', title: 'q', content: 'body');
      await store.load();
      final settings = SettingsStore(api: api)..setUse24hTime(true);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: store),
            ChangeNotifierProvider.value(value: settings),
          ],
          child: const MaterialApp(
            home: Scaffold(body: EditorScreen(noteId: 'n1')),
          ),
        ),
      );

      // 24h setting: the dial shows no AM/PM period selector, regardless of
      // the ambient MediaQuery (which defaults to 12h in tests).
      await tester.tap(find.byIcon(Icons.notification_add_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK')); // date picker
      await tester.pumpAndSettle();
      expect(find.text('Remind me at'), findsOneWidget);
      expect(find.text('AM'), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Flipping to 12h brings the AM/PM selector back.
      settings.setUse24hTime(false);
      await tester.tap(find.byIcon(Icons.notification_add_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('AM'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
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
    testWidgets('wide layout adds space above the top bar and quick add', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pump();

      final topBar = tester.getRect(find.byType(HomeTopBar));
      final quickAdd = tester.getRect(find.byType(QuickAddBar));
      expect(topBar.top, 12);
      expect(quickAdd.top - topBar.bottom, greaterThanOrEqualTo(32));
    });

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

    testWidgets('notifications with actions still expire automatically', (
      tester,
    ) async {
      await store.load();
      await tester.pumpWidget(homeApp(store));

      showAppSnack('Note moved to Trash', actionLabel: 'Undo', onAction: () {});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final snack = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(snack.persist, isFalse);

      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('top-bar theme action cycles system, light, and dark', (
      tester,
    ) async {
      await store.load();
      await tester.pumpWidget(homeApp(store));

      expect(find.byTooltip('Theme: Auto — tap to change'), findsOneWidget);
      await tester.tap(find.byTooltip('Theme: Auto — tap to change'));
      await tester.pump();
      expect(find.byTooltip('Theme: Light — tap to change'), findsOneWidget);

      await tester.tap(find.byTooltip('Theme: Light — tap to change'));
      await tester.pump();
      expect(find.byTooltip('Theme: Dark — tap to change'), findsOneWidget);

      await tester.tap(find.byTooltip('Theme: Dark — tap to change'));
      await tester.pump();
      expect(find.byTooltip('Theme: Auto — tap to change'), findsOneWidget);
      await flushTimers(tester);
    });

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
      expect(find.text('Skippy'), findsNothing);
      expect(find.byIcon(Icons.swap_vert), findsNothing);
      expect(find.byIcon(Icons.menu), findsOneWidget);
      expect(find.byIcon(Icons.view_agenda_outlined), findsOneWidget);
      expect(find.byType(CircleAvatar), findsOneWidget);

      // Focusing the field collapses the trailing shortcuts (layout/avatar)
      // into search mode — even before anything is typed. Settle first: the
      // two control sets cross-fade, so the outgoing icons linger a few
      // frames.
      await tester.tap(find.byType(TextField).first);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.view_agenda_outlined), findsNothing);
      expect(find.byType(CircleAvatar), findsNothing);

      // Typing then shows the clear button.
      await tester.enterText(find.byType(TextField).first, 'milk');
      await tester.pump();
      expect(find.byIcon(Icons.close), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      // Dropping focus brings the shortcuts back.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.view_agenda_outlined), findsOneWidget);

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

  group('semantic search', () {
    // A home harness whose SettingsStore reports semantic search as available,
    // so the ✨ toggle appears and the meaning-ranked path is reachable.
    Widget semanticHome(NotesStore store) {
      final settings = SettingsStore(api: store.api)
        ..semanticSearchCapable = true;
      addTearDown(settings.dispose);
      return MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: store),
          ChangeNotifierProvider.value(value: settings),
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
    }

    testWidgets('shows a loading skeleton until ranked results arrive', (
      tester,
    ) async {
      // Wide surface: clear of the known _TopBar overflow at 800px.
      tester.view.physicalSize = const Size(2400, 1800);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      api.notes['a'] = serverNote('a', title: 'milk and bread');
      await store.load();
      await tester.pumpWidget(semanticHome(store));
      await tester.pump();
      expect(find.byType(NotesSkeleton), findsNothing); // idle: real notes

      // Turn semantic search on with a query in the box.
      await tester.enterText(find.byType(TextField).first, 'milk');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.auto_awesome));
      await tester.pump(); // busy is set synchronously on schedule

      // Loading is visible immediately: skeleton in the body, spinner in the
      // bar — before the debounce/fetch even runs.
      expect(find.byType(NotesSkeleton), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);

      // Debounce (350ms) + fetch resolve: results replace the skeleton.
      await tester.pumpAndSettle();
      expect(find.byType(NotesSkeleton), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('milk and bread'), findsOneWidget);
      expect(api.log, contains('semanticSearch:milk'));
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

  group('sidebar drag-and-drop', () {
    // A plain Draggable<String> stands in for a grid tile mid-drag; the
    // masonry carries the note id exactly this way.
    Widget dragHarness(NotesStore store) => harness(
      store,
      Row(
        children: [
          AppSidebar(
            isOpen: true,
            selection: ViewSelection.notes,
            onSelect: (_) {},
          ),
          const Expanded(
            child: Draggable<String>(
              data: 'n1',
              feedback: SizedBox(width: 80, height: 40),
              child: SizedBox(
                width: 120,
                height: 120,
                child: Center(child: Text('drag me')),
              ),
            ),
          ),
        ],
      ),
    );

    Future<void> dropOn(WidgetTester tester, Finder target) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('drag me')),
      );
      await tester.pump();
      await gesture.moveTo(tester.getCenter(target));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('dropping a note on a label adds the label', (tester) async {
      api.labels['l1'] = const Label(id: 'l1', name: 'work');
      api.notes['n1'] = serverNote('n1', title: 'a');
      await store.load();
      await tester.pumpWidget(dragHarness(store));
      await tester.pumpAndSettle();

      await dropOn(tester, find.text('work'));

      expect(store.noteById('n1')!.labelIds, contains('l1'));
      await flushTimers(tester);
    });

    testWidgets('dropping a note on Archive archives it', (tester) async {
      api.notes['n1'] = serverNote('n1', title: 'a');
      await store.load();
      await tester.pumpWidget(dragHarness(store));
      await tester.pumpAndSettle();

      await dropOn(tester, find.text('Archive'));

      expect(store.noteById('n1')!.archived, isTrue);
      await flushTimers(tester);
    });

    testWidgets(
      'trashing a note removes its tile from the grid and shows an undo snack',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        api.notes['n1'] = serverNote('n1', title: 'AlphaNote');
        api.notes['n2'] = serverNote('n2', title: 'BetaNote');
        await store.load();
        await tester.pumpWidget(homeApp(store));
        await tester.pumpAndSettle();
        expect(find.text('AlphaNote'), findsOneWidget);

        // The card's own control isn't the point here; drive the same store
        // action the editor/drag paths use and confirm the grid updates.
        store.moveToTrash('n1');
        await tester.pump();
        showAppSnack(
          'Note moved to Trash',
          icon: Icons.delete_outline,
          actionLabel: 'Undo',
          onAction: () => store.restoreFromTrash('n1'),
        );
        await tester.pumpAndSettle();

        expect(find.text('AlphaNote'), findsNothing);
        expect(find.widgetWithText(SnackBarAction, 'Undo'), findsOneWidget);
        expect(find.byIcon(Icons.delete_outline), findsWidgets);
        // Even with an Undo action, a close button is present so any
        // notification can be dismissed outright.
        expect(find.byIcon(Icons.close), findsOneWidget);

        // Undo restores the note to the grid.
        await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
        await tester.pumpAndSettle();
        expect(find.text('AlphaNote'), findsOneWidget);
        await flushTimers(tester);
      },
    );

    testWidgets('Trash refuses a note you do not own', (tester) async {
      api.notes['n1'] = serverNote(
        'n1',
        title: 'a',
        owner: const UserRef(id: 'someone-else', name: 'x'),
      );
      await store.load();
      await tester.pumpWidget(dragHarness(store));
      await tester.pumpAndSettle();

      await dropOn(tester, find.text('Trash'));

      expect(store.noteById('n1')!.trashed, isFalse);
      await flushTimers(tester);
    });
  });
}
