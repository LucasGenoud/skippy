import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
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
import 'package:skippy/state/link_preview_cache.dart';
import 'package:skippy/theme.dart';
import 'package:skippy/util/motion.dart';
import 'package:skippy/util/snack.dart';
import 'package:skippy/widgets/all_done_burst.dart';
import 'package:skippy/widgets/checklist/animated_checklist.dart';
import 'package:skippy/widgets/app_drawer.dart';
import 'package:skippy/widgets/home_top_bar.dart';
import 'package:skippy/widgets/linked_text.dart';
import 'package:skippy/widgets/link_preview.dart';
import 'package:skippy/widgets/markdown_toolbar.dart';
import 'package:skippy/widgets/masonry.dart';
import 'package:skippy/widgets/note_card.dart';
import 'package:skippy/widgets/quick_add_bar.dart';
import 'package:skippy/widgets/screen_width.dart';
import 'package:skippy/widgets/skeleton.dart';

import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote;

Widget harness(NotesStore store, Widget child) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: store),
      ChangeNotifierProvider(create: (_) => SettingsStore(api: store.api)),
      Provider(create: (_) => LinkPreviewCache(api: store.api)),
    ],
    child: MaterialApp(
      // Mirrors main.dart: the app publishes the screen width above every
      // route so screens can branch on it without depending on the height.
      builder: (context, child) =>
          ScreenWidth(child: child ?? const SizedBox()),
      home: Scaffold(body: child),
    ),
  );
}

/// The full home screen, as the app builds it. The top bar's avatar menu
/// watches an [AuthStore], which only supports the concrete [ApiClient]; a
/// signed-out store over a dummy client renders fine and never talks to it.
Widget homeApp(NotesStore store, {SettingsStore? settings}) => MultiProvider(
  providers: [
    ChangeNotifierProvider.value(value: store),
    if (settings == null)
      ChangeNotifierProvider(create: (_) => SettingsStore(api: store.api))
    else
      ChangeNotifierProvider.value(value: settings),
    ChangeNotifierProvider(
      create: (_) => AuthStore(api: ApiClient(baseUrl: 'http://unused')),
    ),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.light),
    scaffoldMessengerKey: scaffoldMessengerKey,
    builder: (context, child) => ScreenWidth(child: child ?? const SizedBox()),
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
    testWidgets('shows up to three unique website preview cards', (
      tester,
    ) async {
      api.notes['n1'] = serverNote(
        'n1',
        title: 'Links https://one.example',
        content:
            'https://one.example repeated\n'
            'https://two.example\n'
            'https://three.example\n'
            'https://four.example',
      );
      await store.load();
      await tester.pumpWidget(
        harness(
          store,
          SizedBox(width: 280, child: NoteTile(note: store.noteById('n1')!)),
        ),
      );
      await tester.pumpAndSettle();

      final previews = tester
          .widgetList<LinkPreviewCard>(find.byType(LinkPreviewCard))
          .toList();
      expect(previews.map((preview) => preview.url), [
        'https://one.example',
        'https://two.example',
        'https://three.example',
      ]);
      expect(previews.every((preview) => preview.topDivider), isTrue);
      expect(previews[0].borderRadius, BorderRadius.zero);
      expect(previews[1].borderRadius, BorderRadius.zero);
      expect(
        previews[2].borderRadius,
        const BorderRadius.vertical(bottom: kRadiusCorner),
      );
    });

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

    testWidgets('optically aligns card checkboxes with the first text line', (
      tester,
    ) async {
      const shortItem = 'Single line';
      const wrappedItem =
          'A long checklist item that wraps while text is scaled up for '
          'accessibility';
      api.notes['n1'] = serverNote(
        'n1',
        kind: NoteKind.checklist,
        items: const [
          ChecklistItem(id: 'short', text: shortItem),
          ChecklistItem(id: 'wrapped', text: wrappedItem),
        ],
      );
      await store.load();
      await tester.pumpWidget(
        harness(
          store,
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.8)),
              child: SizedBox(
                width: 240,
                child: NoteTile(note: store.noteById('n1')!),
              ),
            ),
          ),
        ),
      );

      double expectFirstLineAlignment(String id, String item) {
        final row = find.byKey(ValueKey('checklist-card-row-$id'));
        final text = find.descendant(of: row, matching: find.text(item));
        final textContext = tester.element(text);
        final painter = TextPainter(
          text: TextSpan(
            text: 'x',
            style: DefaultTextStyle.of(textContext).style,
          ),
          textDirection: Directionality.of(textContext),
          textScaler: MediaQuery.textScalerOf(textContext),
        );
        final lineHeight = painter.preferredLineHeight;
        painter.dispose();
        final checkbox = find.descendant(
          of: row,
          matching: find.byIcon(Icons.check_box_outline_blank),
        );
        expect(
          tester.getCenter(checkbox).dy,
          closeTo(tester.getTopLeft(text).dy + lineHeight / 2, 1),
        );
        return lineHeight;
      }

      expectFirstLineAlignment('short', shortItem);
      final wrappedLineHeight = expectFirstLineAlignment(
        'wrapped',
        wrappedItem,
      );
      expect(
        tester.getSize(find.text(wrappedItem)).height,
        greaterThan(wrappedLineHeight),
      );
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

    testWidgets('content-heavy cards show twice as much preview content', (
      tester,
    ) async {
      api.notes['text'] = serverNote(
        'text',
        content: List.generate(30, (i) => 'line $i').join('\n'),
      );
      api.notes['checklist'] = serverNote(
        'checklist',
        kind: NoteKind.checklist,
        items: [
          for (var i = 0; i < 20; i++)
            ChecklistItem(id: 'i$i', text: 'item $i'),
        ],
      );
      await store.load();

      await tester.pumpWidget(
        harness(
          store,
          SingleChildScrollView(
            child: Column(
              children: [
                SizedBox(
                  width: 240,
                  child: NoteTile(note: store.noteById('text')!),
                ),
                SizedBox(
                  width: 240,
                  child: NoteTile(note: store.noteById('checklist')!),
                ),
              ],
            ),
          ),
        ),
      );

      final textPreview = tester.widget<LinkedText>(
        find.byType(LinkedText).first,
      );
      expect(textPreview.maxLines, 20);
      expect(find.text('item 15'), findsOneWidget);
      expect(find.text('item 16'), findsNothing);
      expect(find.text('+ 4 more'), findsOneWidget);
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
      'selection mode keeps the card size and puts the badge on the corner',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        api.notes['n1'] = serverNote(
          'n1',
          title: 'Steady card',
          content: 'Body',
        );
        await store.load();

        Widget tile({required bool selectionMode, required bool selected}) =>
            harness(
              store,
              SizedBox(
                width: 240,
                child: NoteTile(
                  note: store.noteById('n1')!,
                  selectionMode: selectionMode,
                  selected: selected,
                ),
              ),
            );

        await tester.pumpWidget(tile(selectionMode: false, selected: false));
        final atRest = tester.getRect(find.byType(NoteTile));

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(() => mouse.removePointer());
        await mouse.addPointer(
          location: tester.getCenter(find.byType(NoteTile)),
        );
        await tester.pumpAndSettle();
        // Hover alone must not move or resize the card either.
        expect(tester.getRect(find.byType(NoteTile)), atRest);

        final badge = find.byTooltip('Select note');
        // The whole tap target is the badge: no invisible padding around it.
        expect(tester.getSize(badge), const Size(20, 20));
        // ...and it straddles the card's top-left corner rather than sitting
        // inside it.
        final badgeRect = tester.getRect(badge);
        expect(badgeRect.left, lessThan(atRest.left));
        expect(badgeRect.top, lessThan(atRest.top));
        expect(badgeRect.center.dx, greaterThan(atRest.left));
        expect(badgeRect.center.dy, greaterThan(atRest.top));

        // Entering selection mode swaps the action icons for the labels, but
        // the reserved footer stays, so the card doesn't jump or resize.
        await tester.pumpWidget(tile(selectionMode: true, selected: false));
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byType(NoteTile)), atRest);

        await tester.pumpWidget(tile(selectionMode: true, selected: true));
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byType(NoteTile)), atRest);
        expect(find.byTooltip('Deselect note'), findsOneWidget);
      },
    );

    testWidgets(
      'the pin sits in the card top-right corner',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        api.notes['n1'] = serverNote('n1', title: 'Pinned', pinned: true);
        await store.load();
        await tester.pumpWidget(
          harness(
            store,
            SizedBox(width: 240, child: NoteTile(note: store.noteById('n1')!)),
          ),
        );

        final card = tester.getRect(find.byType(NoteTile));
        final pin = tester.getRect(find.byTooltip('Unpin note'));
        expect(pin.size, const Size(32, 32));
        expect(card.right - pin.right, 4);
        expect(pin.top - card.top, 4);

        // Revealing the selection control must not shove the pin sideways.
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(() => mouse.removePointer());
        await mouse.addPointer(
          location: tester.getCenter(find.byType(NoteTile)),
        );
        await tester.pumpAndSettle();
        expect(find.byTooltip('Select note'), findsOneWidget);
        expect(tester.getRect(find.byTooltip('Unpin note')), pin);
      },
    );

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
      'the card menu duplicates a note and copies it to the clipboard',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        api.notes['n1'] = serverNote(
          'n1',
          title: 'Groceries',
          kind: NoteKind.checklist,
          items: [
            const ChecklistItem(id: 'i1', text: 'Milk', done: true),
            const ChecklistItem(id: 'i2', text: 'Eggs'),
          ],
        );
        await store.load();
        await tester.pumpWidget(
          harness(
            store,
            SizedBox(width: 240, child: NoteTile(note: store.noteById('n1')!)),
          ),
        );

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(() => mouse.removePointer());
        await mouse.addPointer(
          location: tester.getCenter(find.byType(NoteTile)),
        );
        await tester.pumpAndSettle();

        // Clipboard: the note's text, checked state and all.
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = call.arguments['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.tap(find.byTooltip('More note options'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Copy to clipboard'));
        await tester.pumpAndSettle();
        expect(copied, 'Groceries\n\n[x] Milk\n[ ] Eggs');

        // Duplicate: a second note, same content. What exactly duplicate()
        // clones is NotesStore's business (covered there); what matters here
        // is that the menu reaches it, and that it isn't the clipboard entry.
        await tester.tap(find.byTooltip('More note options'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Duplicate'));
        await tester.pumpAndSettle();
        final all = store.notesFor(ViewSelection.notes, '').others;
        expect(all.length, 2);
        expect(all.firstWhere((n) => n.id != 'n1').title, 'Groceries');
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
        MasonryReorder? reported;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: AnimatedMasonry(
                  notes: notes,
                  columns: 2,
                  onReorder: (reorder) {
                    reported = reorder;
                    return MasonryReorderDecision.keep;
                  },
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
        expect(reported!.draggedId, 'a');
        expect(reported!.fromIndex, 0);
        expect(reported!.toIndex, isNot(0));
        expect(reported!.orderedIds, isNot(['a', 'b', 'c', 'd']));
        expect(reported!.orderedIds.toSet(), {'a', 'b', 'c', 'd'});
        expect(reported!.acceptedByTarget, isFalse);
      },
    );

    testWidgets(
      'reordering moves tiles without rebuilding any of them',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        // Twelve notes, the size at which the grid started dropping frames on
        // slower devices, because every reorder step rebuilt every card (twice:
        // once for the tile, once for its unused drag feedback).
        final notes = [
          for (var i = 0; i < 12; i++)
            serverNote('n$i', title: 'Note $i', position: i.toDouble()),
        ];
        final builds = <String, int>{};
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: AnimatedMasonry(
                  notes: notes,
                  columns: 2,
                  onReorder: (_) => MasonryReorderDecision.keep,
                  itemBuilder: (context, note) {
                    builds[note.id] = (builds[note.id] ?? 0) + 1;
                    return SizedBox(
                      height: 80,
                      child: Card(child: Center(child: Text(note.title))),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final gesture = await tester.startGesture(
          tester.getCenter(find.text('Note 0')),
        );
        await tester.pump(const Duration(milliseconds: 300));
        // The lifted card builds one more time, that copy is the feedback
        // following the pointer, and it is the only extra build a drag costs.
        final afterLift = Map<String, int>.from(builds);

        var elapsed = 400;
        for (final target in ['Note 3', 'Note 7', 'Note 11', 'Note 5']) {
          await gesture.moveTo(
            tester.getCenter(find.text(target)),
            timeStamp: Duration(milliseconds: elapsed += 100),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await gesture.up();
        await tester.pumpAndSettle();

        // Four reorder steps over twelve cards: not one of them was rebuilt.
        expect(builds, afterLift);
      },
    );

    testWidgets(
      'a consumer can reject a reorder owned by an accepting target',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        final notes = [
          serverNote('a', title: 'AAA', position: 1),
          serverNote('b', title: 'BBB', position: 2),
          serverNote('c', title: 'CCC', position: 3),
        ];
        MasonryReorder? reported;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DragTarget<String>(
                onWillAcceptWithDetails: (_) => true,
                builder: (context, candidate, rejected) =>
                    SingleChildScrollView(
                      child: AnimatedMasonry(
                        notes: notes,
                        columns: 1,
                        onReorder: (reorder) {
                          reported = reorder;
                          return MasonryReorderDecision.restore;
                        },
                        itemBuilder: (context, note) => SizedBox(
                          height: 80,
                          child: Card(child: Center(child: Text(note.title))),
                        ),
                      ),
                    ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final gesture = await tester.startGesture(
          tester.getCenter(find.text('AAA')),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await gesture.moveTo(
          tester.getCenter(find.text('CCC')),
          timeStamp: const Duration(milliseconds: 400),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await gesture.up();
        await tester.pumpAndSettle();

        expect(reported, isNotNull);
        expect(reported!.acceptedByTarget, isTrue);
        expect(
          tester.getTopLeft(find.text('AAA')).dy,
          lessThan(tester.getTopLeft(find.text('BBB')).dy),
        );
        expect(
          tester.getTopLeft(find.text('BBB')).dy,
          lessThan(tester.getTopLeft(find.text('CCC')).dy),
        );
      },
    );

    testWidgets('touch long-press selects in place but movement reorders', (
      tester,
    ) async {
      final notes = [
        serverNote('a', title: 'AAA', position: 1),
        serverNote('b', title: 'BBB', position: 2),
        serverNote('c', title: 'CCC', position: 3),
        serverNote('d', title: 'DDD', position: 4),
      ];
      MasonryReorder? reported;
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AnimatedMasonry(
                notes: notes,
                columns: 2,
                onReorder: (reorder) {
                  reported = reorder;
                  return MasonryReorderDecision.keep;
                },
                onStationaryLongPress: (id) => selected = id,
                itemBuilder: (context, note) => SizedBox(
                  height: 80,
                  child: Card(child: Center(child: Text(note.title))),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final stationary = await tester.startGesture(
        tester.getCenter(find.text('AAA')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await stationary.up();
      await tester.pumpAndSettle();
      expect(selected, 'a');
      expect(reported, isNull);

      final drag = await tester.startGesture(
        tester.getCenter(find.text('BBB')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await drag.moveTo(
        tester.getCenter(find.text('DDD')),
        timeStamp: const Duration(milliseconds: 400),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await drag.up();
      await tester.pumpAndSettle();
      expect(reported, isNotNull);
      // The resulting list alone is ambiguous about which adjacent card was
      // moved. Masonry must preserve the actual gesture identity.
      expect(reported!.draggedId, 'b');
      expect(reported!.orderedIds.toSet(), {'a', 'b', 'c', 'd'});
    });
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

      // Editing happens in the bar itself, no editor route is pushed.
      expect(find.byType(AnimatedChecklist), findsOneWidget);
      expect(find.byType(EditorScreen), findsNothing);

      // Typing in the composer materializes a real item on the first
      // keystroke; Enter hands it to the list and starts the next one, all
      // without the caret ever leaving the composer.
      await tester.enterText(
        find.widgetWithText(TextField, 'List item'),
        'Milk',
      );
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();
      tester.testTextInput.enterText('Eggs');
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

    testWidgets('a color picked while composing lands on the created note', (
      tester,
    ) async {
      await store.load();
      await tester.pumpWidget(harness(store, const QuickAddBar()));
      await tester.tap(find.text('Take a note…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Take a note…'),
        'tinted',
      );

      await tester.tap(find.byTooltip('Note color'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Green'));
      await tester.pumpAndSettle();
      // Picking happens in a sheet of its own: the tap that lands on it must
      // not read as a tap outside the composer and collapse it.
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      expect(find.text('Close'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      final note = store.notesFor(ViewSelection.notes, '').others.single;
      expect(note.content, 'tinted');
      expect(note.color, 'green');
      await flushTimers(tester);
      // The colour rides along on the create request rather than trailing it.
      expect(api.notes[note.id]!.color, 'green');
      expect(api.log.where((l) => l.startsWith('patchNote')), isEmpty);
    });

    testWidgets('a label picked while composing files the created note', (
      tester,
    ) async {
      await store.load();
      final label = store.createLabel('Recipes');
      await tester.pumpWidget(harness(store, const QuickAddBar()));
      await tester.tap(find.text('Take a note…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Take a note…'),
        'pancakes',
      );

      await tester.tap(find.byTooltip('Labels'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recipes'));
      await tester.pumpAndSettle();
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      // The pick shows as a chip on the composer before the note exists.
      expect(find.widgetWithText(InputChip, 'Recipes'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      final note = store.notesFor(ViewSelection.notes, '').others.single;
      expect(note.labelIds, {label.id});
      await flushTimers(tester);
    });

    testWidgets('Discard note throws the composed note away', (tester) async {
      await store.load();
      await tester.pumpWidget(harness(store, const QuickAddBar()));
      await tester.tap(find.text('Take a note…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Take a note…'),
        'never mind',
      );

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard note'));
      await tester.pumpAndSettle();

      expect(find.text('Close'), findsNothing);
      expect(store.notesFor(ViewSelection.notes, '').others, isEmpty);
      await flushTimers(tester);
      expect(api.notes, isEmpty);
    });
  });

  group('EditorScreen', () {
    testWidgets(
      'full-screen editor separates the content from both mobile action bars',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        api.notes['n1'] = serverNote('n1', title: 'Separated');
        await store.load();
        await tester.pumpWidget(
          harness(store, const EditorScreen(noteId: 'n1')),
        );
        await tester.pump();

        final scheme = Theme.of(
          tester.element(find.byType(EditorScreen)),
        ).colorScheme;
        final top = tester.widget<Container>(
          find.byKey(const Key('editor-top-separator')),
        );
        expect(top.color, hairlineColor(scheme));

        final bottom = tester.widget<DecoratedBox>(
          find.byKey(const Key('editor-bottom-separator')),
        );
        final border = (bottom.decoration as BoxDecoration).border! as Border;
        expect(border.top.color, hairlineColor(scheme));
      },
    );

    testWidgets('markdown opens in preview and tapping edits source', (
      tester,
    ) async {
      api.notes['n1'] = serverNote(
        'n1',
        kind: NoteKind.markdown,
        content: '**Selectable** preview',
      );
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));

      final preview = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
      expect(preview.selectable, isTrue);
      expect(find.byType(SelectionArea), findsNothing);
      expect(find.byType(SelectableText), findsWidgets);
      expect(find.byTooltip('Edit markdown'), findsOneWidget);

      await tester.tap(find.byType(SelectableText).first);
      await tester.pump();
      expect(find.byTooltip('Preview'), findsOneWidget);
      final source = tester
          .widgetList<EditableText>(find.byType(EditableText))
          .last;
      expect(source.focusNode.hasFocus, isTrue);
      await tester.enterText(find.byType(TextField).last, '**Edited** preview');
      expect(store.noteById('n1')!.content, '**Edited** preview');
      await flushTimers(tester);
    });

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

    testWidgets('labels can be set on a note before it has any content', (
      tester,
    ) async {
      await store.load();
      store.createLabel('Work');
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: null)));
      await tester.pump();

      // Filing a note is often the first thing you do, so the button is live
      // on an empty note, no typing required first.
      final labels = find.widgetWithIcon(IconButton, Icons.label_outline);
      expect(
        tester.widget<IconButton>(labels).onPressed,
        isNotNull,
        reason: 'the Labels button must never be greyed out on a new note',
      );

      await tester.tap(labels);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work'));
      await tester.pump();

      final draft = store.notesFor(ViewSelection.notes, '').others.single;
      expect(draft.labelIds, hasLength(1));
      await flushTimers(tester);
    });

    testWidgets('a note started in a label view is filed under it', (
      tester,
    ) async {
      await store.load();
      final label = store.createLabel('Recipes');
      await tester.pumpWidget(
        harness(store, EditorScreen(noteId: null, labelIds: {label.id})),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Note'),
        'Pancakes',
      );
      await tester.pump();

      final note = store.notesFor(ViewSelection.notes, '').others.single;
      expect(note.labelIds, {label.id});
      await flushTimers(tester);
      // ...and the label survives the trip to the server, which for a draft
      // happens on the create request, not a later patch.
      expect(api.notes[note.id]!.labelIds, {label.id});
    });

    testWidgets('untouched new editor leaves no note behind', (tester) async {
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: null)));
      await tester.pumpWidget(harness(store, const SizedBox())); // close
      await flushTimers(tester);
      expect(store.notesFor(ViewSelection.notes, '').others, isEmpty);
      expect(api.notes, isEmpty);
    });

    testWidgets('empty retained notes keep Archive and Delete enabled', (
      tester,
    ) async {
      api.notes['n1'] = serverNote(
        'n1',
        reminderAt: DateTime(2030),
        collaborators: const [UserRef(id: 'u2', name: 'Ada')],
      );
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      await tester.pump();

      final archive = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.archive_outlined),
      );
      expect(archive.onPressed, isNotNull);

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      final delete = tester.widget<PopupMenuItem<String>>(
        find.ancestor(
          of: find.text('Delete'),
          matching: find.byType(PopupMenuItem<String>),
        ),
      );
      expect(delete.enabled, isTrue);
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

        // One char per single frame, outrunning the focus handoff.
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
      'machine-speed typing into the add row lands on a single item',
      (tester) async {
        // Injected input (simctl-style, and a fast enough human on iOS) puts
        // every keystroke in before a single frame is built: the row spawned
        // by the first character does not exist in `items` yet, and each
        // report carries the whole accumulated value rather than the one
        // character that leaked back into the cleared add field.
        api.notes['n1'] = serverNote('n1', kind: NoteKind.checklist);
        await store.load();
        await tester.pumpWidget(
          harness(store, const EditorScreen(noteId: 'n1')),
        );
        await tester.pump();

        await tester.tap(find.widgetWithText(TextField, 'List item'));
        await tester.pump();

        const word = 'Pancake flour';
        for (var i = 1; i <= word.length; i++) {
          tester.testTextInput.updateEditingValue(
            TextEditingValue(
              text: word.substring(0, i),
              selection: TextSelection.collapsed(offset: i),
            ),
          );
        }
        // Not a single frame in between: the whole word arrives first.
        await tester.pumpAndSettle();

        expect(store.noteById('n1')!.items.map((i) => i.text), [word]);
        await flushTimers(tester);
      },
    );

    testWidgets('an IME batch of several characters adds one item', (
      tester,
    ) async {
      // Soft keyboards commit a whole composed word in one edit. The first
      // one materializes the row; the next one arrives accumulated, before
      // focus has moved off the add field.
      api.notes['n1'] = serverNote('n1', kind: NoteKind.checklist);
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      await tester.pump();

      await tester.tap(find.widgetWithText(TextField, 'List item'));
      await tester.pump();

      tester.testTextInput.enterText('Pancake');
      await tester.idle();
      tester.testTextInput.enterText('Pancake flour');
      await tester.pumpAndSettle();

      expect(store.noteById('n1')!.items.map((i) => i.text), ['Pancake flour']);
      await flushTimers(tester);
    });

    testWidgets('materializing an item never moves the field being typed in', (
      tester,
    ) async {
      api.notes['n1'] = serverNote('n1', kind: NoteKind.checklist);
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      await tester.pump();

      final composer = find.byKey(const ValueKey('__new__'));
      await tester.tap(find.widgetWithText(TextField, 'List item'));
      await tester.pumpAndSettle();
      final restingTop = tester.getRect(composer).top;

      tester.testTextInput.enterText('M');
      await tester.pump();

      // The item exists, but it is drawn by the composer, not by a row of its
      // own that would have to animate in and take the caret over.
      final itemId = store.noteById('n1')!.items.single.id;
      expect(find.byKey(ValueKey('checklist-entrance-$itemId')), findsNothing);
      expect(tester.getRect(composer).top, restingTop);
      expect(
        find.descendant(
          of: find.byType(AnimatedChecklist),
          matching: find.byType(TextField),
        ),
        findsOneWidget,
      );

      // Nor does the delayed store notification start one afterwards.
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(ValueKey('checklist-entrance-$itemId')), findsNothing);
      expect(tester.getRect(composer).top, restingTop);
      expect(store.noteById('n1')!.items.single.text, 'M');
      await flushTimers(tester);
    });

    testWidgets('typing and hovering rebuild only what changed', (
      tester,
    ) async {
      // A keystroke used to setState both the checklist and the editor, and a
      // hover setState the checklist, so every row (each a TextField with its
      // own gesture, focus and ink machinery) was rebuilt. On a 30-item list
      // that was ~2700 widgets per character, which is what made writing one
      // feel laggy. Only the field being typed in, the suggestion popup, and
      // the hover wrappers should rebuild now.
      api.notes['n1'] = serverNote(
        'n1',
        kind: NoteKind.checklist,
        items: [
          for (var i = 0; i < 30; i++)
            ChecklistItem(id: 'i$i', text: 'item $i'),
        ],
      );
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      await tester.pumpAndSettle();

      Future<int> rebuildsDuring(Future<void> Function() action) async {
        var count = 0;
        final printer = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) => count++;
        debugPrintRebuildDirtyWidgets = true;
        await action();
        debugPrintRebuildDirtyWidgets = false;
        debugPrint = printer;
        return count;
      }

      final row = find.widgetWithText(TextField, 'item 0');
      await tester.tap(row);
      await tester.pumpAndSettle();

      final typing = await rebuildsDuring(() async {
        await tester.enterText(row, 'item 0!');
        await tester.pump();
      });
      expect(store.noteById('n1')!.items.first.text, 'item 0!');

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      final hovering = await rebuildsDuring(() async {
        for (var i = 1; i < 6; i++) {
          await mouse.moveTo(tester.getCenter(find.byType(TextField).at(i)));
          await tester.pump();
        }
      });

      // Measured at ~40 and ~660; the bounds are loose enough to absorb
      // Flutter's own internals shifting, tight enough that reintroducing a
      // list-wide setState (thousands) fails.
      expect(typing, lessThan(300));
      expect(hovering, lessThan(2000));
      await flushTimers(tester);
    });

    testWidgets('only the checklist row being edited gets a subtle tint', (
      tester,
    ) async {
      api.notes['n1'] = serverNote(
        'n1',
        kind: NoteKind.checklist,
        items: const [
          ChecklistItem(id: 'first', text: 'Milk'),
          ChecklistItem(id: 'second', text: 'Eggs'),
        ],
      );
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      await tester.pumpAndSettle();

      // The tint the row is heading for: it fades in over a few frames, and
      // what matters here is which row is being tinted at all.
      Color? rowColor(String id) {
        final box = tester.widget<AnimatedContainer>(
          find.byKey(ValueKey('checklist-row-background-$id')),
        );
        return (box.decoration as BoxDecoration?)?.color;
      }

      expect(rowColor('first'), isNull);
      expect(rowColor('second'), isNull);

      await tester.tap(find.widgetWithText(TextField, 'Eggs'));
      await tester.pump();

      final scheme = Theme.of(
        tester.element(find.widgetWithText(TextField, 'Eggs')),
      ).colorScheme;
      expect(rowColor('first'), isNull);
      expect(rowColor('second'), scheme.primary.withValues(alpha: 0.035));

      await tester.tap(find.widgetWithText(TextField, 'Milk'));
      await tester.pump();

      expect(rowColor('first'), scheme.primary.withValues(alpha: 0.035));
      expect(rowColor('second'), isNull);
      await flushTimers(tester);
    });

    testWidgets('a word is written into one field from start to finish', (
      tester,
    ) async {
      // Materializing an item used to hand the caret from the add field to
      // the row it had just spawned, mid-word. That tore down the platform's
      // text input connection between two keystrokes, and every client raced
      // it differently: some reported the next character as a replacement,
      // some attached the new field with an empty value, and characters (or
      // whole words) went missing on iOS. Nothing is handed over any more.
      api.notes['n1'] = serverNote('n1', kind: NoteKind.checklist);
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      await tester.pump();

      final field = find.descendant(
        of: find.byType(AnimatedChecklist),
        matching: find.byType(EditableText),
      );
      await tester.tap(find.widgetWithText(TextField, 'List item'));
      await tester.pump();
      final editor = tester.state<EditableTextState>(field);

      for (final value in ['I', "I'", "I'd"]) {
        tester.testTextInput.enterText(value);
        await tester.pump();
        // Same field, same controller, same focus: there is no window for a
        // client to race.
        expect(field, findsOneWidget);
        expect(tester.state<EditableTextState>(field), same(editor));
        expect(editor.widget.controller.text, value);
        expect(editor.widget.focusNode.hasFocus, isTrue);
        expect(store.noteById('n1')!.items.single.text, value);
      }
      await flushTimers(tester);
    });

    testWidgets(
      'empty new checklist row can dismiss its keyboard with the close button',
      (tester) async {
        api.notes['n1'] = serverNote('n1', kind: NoteKind.checklist);
        await store.load();
        await tester.pumpWidget(
          harness(store, const EditorScreen(noteId: 'n1')),
        );
        await tester.pump();

        final addField = find.widgetWithText(TextField, 'List item');
        await tester.tap(addField);
        await tester.pump();

        final addEditable = tester.widget<EditableText>(
          find.descendant(of: addField, matching: find.byType(EditableText)),
        );
        expect(addEditable.focusNode.hasFocus, isTrue);

        await tester.tap(find.byKey(const Key('checklist-new-row-close')));
        await tester.pump();

        expect(addEditable.focusNode.hasFocus, isFalse);
        await flushTimers(tester);
      },
    );

    testWidgets(
      'desktop checklist checkbox stays with the first line when text wraps',
      (tester) async {
        const longItem =
            'This is a very long checklist item that wraps onto several '
            'visible lines even inside the wider desktop editor, and keeps '
            'going long enough that wrapping is guaranteed at its modal width';
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        api.notes['n1'] = serverNote(
          'n1',
          kind: NoteKind.checklist,
          items: const [
            ChecklistItem(id: 'short', text: 'Single line'),
            ChecklistItem(id: 'long', text: longItem),
          ],
        );
        await store.load();
        // Desktop resolves to a compact density, and InputDecorator spends half
        // of that adjustment off its top padding: it used to lift the text ~4px
        // clear of the controls while every row measurement still looked right,
        // so the controls have to be checked against the text, not the row.
        await tester.pumpWidget(
          harness(
            store,
            Theme(
              data: ThemeData(visualDensity: VisualDensity.compact),
              child: const EditorScreen(noteId: 'n1', modal: true),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        Finder rowOf(String id) =>
            find.byKey(ValueKey('checklist-row-background-$id'));
        Rect textOf(String id) => tester.getRect(
          find.descendant(of: rowOf(id), matching: find.byType(EditableText)),
        );
        double controlOf(String id, Finder control) => tester
            .getCenter(find.descendant(of: rowOf(id), matching: control))
            .dy;

        expect(tester.getSize(rowOf('short')).height, closeTo(48, 1));
        expect(tester.getSize(rowOf('long')).height, greaterThan(48));
        for (final control in {
          'checkbox': find.byType(Checkbox),
          'drag handle': find.byIcon(Icons.drag_indicator),
          'remove button': find.byIcon(Icons.close),
        }.entries) {
          // One line, so the text box's own centre is that line's centre.
          expect(
            controlOf('short', control.value),
            closeTo(textOf('short').center.dy, 1),
            reason: control.key,
          );
          // The wrapped row holds that same offset into its first line; the
          // extra lines only grow below it.
          expect(
            controlOf('long', control.value) - textOf('long').top,
            closeTo(controlOf('short', control.value) - textOf('short').top, 1),
            reason: '${control.key}, wrapped',
          );
        }
        await flushTimers(tester);
      },
    );

    testWidgets(
      'an empty IME reset cannot erase the first word during focus handoff',
      (tester) async {
        api.notes['n1'] = serverNote('n1', kind: NoteKind.checklist);
        await store.load();
        await tester.pumpWidget(
          harness(store, const EditorScreen(noteId: 'n1')),
        );
        await tester.pump();

        await tester.tap(find.widgetWithText(TextField, 'List item'));
        tester.testTextInput.enterText('Pancake');
        await tester.pump();
        await tester.pump();

        tester.testTextInput.updateEditingValue(TextEditingValue.empty);
        await tester.pump();

        expect(store.noteById('n1')!.items.single.text, 'Pancake');
        final focused = tester
            .widgetList<EditableText>(find.byType(EditableText))
            .singleWhere((field) => field.focusNode.hasFocus);
        expect(focused.controller.text, 'Pancake');
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
      'an empty row goes away on backspace even when the keypress never '
      'arrives as a key event',
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

        // Soft keyboards (and the browser's text input) report nothing at all
        // when backspace lands in a field that is already empty, so a focused
        // empty row holds a zero-width space for the keypress to delete,
        // which reaches us as an ordinary edit down to the empty string.
        final focused = tester
            .widgetList<EditableText>(find.byType(EditableText))
            .singleWhere((field) => field.focusNode.hasFocus);
        expect(focused.controller.text, '\u200b');
        tester.testTextInput.updateEditingValue(TextEditingValue.empty);
        await tester.pumpAndSettle();

        expect(store.noteById('n1')!.items.map((i) => i.text), ['Milk']);
        final milk = tester.widget<EditableText>(
          find.descendant(
            of: find.widgetWithText(TextField, 'Milk'),
            matching: find.byType(EditableText),
          ),
        );
        expect(milk.focusNode.hasFocus, isTrue);
        expect(milk.controller.selection.baseOffset, 4);
        await flushTimers(tester);
      },
    );

    testWidgets(
      'the row above takes the caret within the keypress, before any rebuild',
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

        EditableText milk() => tester.widget<EditableText>(
          find.descendant(
            of: find.widgetWithText(TextField, 'Milk'),
            matching: find.byType(EditableText),
          ),
        );
        expect(milk().focusNode.hasFocus, isFalse);

        tester.testTextInput.updateEditingValue(TextEditingValue.empty);
        // No frame is pumped here on purpose. A browser only keeps the
        // on-screen keyboard up for a focus move made inside the keypress that
        // asked for it, so waiting for the rebuild would land the caret in a
        // field the keyboard has already abandoned.
        await tester.idle();
        expect(milk().focusNode.hasFocus, isTrue);

        await tester.pumpAndSettle();
        expect(store.noteById('n1')!.items.map((i) => i.text), ['Milk']);
        await flushTimers(tester);
      },
    );

    testWidgets(
      'an empty checked row hands the caret to the checked row above it',
      (tester) async {
        api.notes['n1'] = serverNote(
          'n1',
          kind: NoteKind.checklist,
          items: [
            const ChecklistItem(id: 'a', text: 'Milk'),
            const ChecklistItem(id: 'b', text: 'Eggs', done: true),
            const ChecklistItem(id: 'c', text: '', done: true),
          ],
        );
        await store.load();
        await tester.pumpWidget(
          harness(store, const EditorScreen(noteId: 'n1')),
        );
        await tester.pump(const Duration(milliseconds: 100));

        // Checked rows sit in their own section, folded away on open.
        await tester.tap(find.text('2 checked items'));
        await tester.pumpAndSettle();

        // Once unfolded, the last field on screen is the empty checked one.
        final rows = find.descendant(
          of: find.byType(AnimatedChecklist),
          matching: find.byType(TextField),
        );
        await tester.tap(rows.last);
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await tester.pumpAndSettle();

        expect(store.noteById('n1')!.items.map((i) => i.text), [
          'Milk',
          'Eggs',
        ]);
        final eggs = tester.widget<EditableText>(
          find.descendant(
            of: find.widgetWithText(TextField, 'Eggs'),
            matching: find.byType(EditableText),
          ),
        );
        expect(eggs.focusNode.hasFocus, isTrue);
        expect(eggs.controller.selection.baseOffset, 4);
        await flushTimers(tester);
      },
    );

    testWidgets(
      'the marker never reaches the note: typing in an empty row stores '
      'exactly what was typed',
      (tester) async {
        api.notes['n1'] = serverNote(
          'n1',
          kind: NoteKind.checklist,
          items: [const ChecklistItem(id: 'a', text: '')],
        );
        await store.load();
        await tester.pumpWidget(
          harness(store, const EditorScreen(noteId: 'n1')),
        );
        await tester.pump(const Duration(milliseconds: 100));

        final row = find
            .descendant(
              of: find.byType(AnimatedChecklist),
              matching: find.byType(TextField),
            )
            .first;
        await tester.tap(row);
        await tester.pump();

        // A real keyboard appends to what the field already holds, marker
        // included. It has to come back off before the text goes anywhere.
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200bEggs',
            selection: TextSelection.collapsed(offset: 5),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(store.noteById('n1')!.items.single.text, 'Eggs');
        await flushTimers(tester);
      },
    );

    testWidgets(
      'checking an item moves it into the checked section, folded until asked '
      'for',
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

        // Item is done and has moved into the checked section, which is
        // folded: the header counts it, the row itself is gone from the list.
        expect(
          store.noteById('n1')!.items.firstWhere((i) => i.id == 'a').done,
          isTrue,
        );
        expect(find.text('1 checked item'), findsOneWidget);
        expect(find.text('Apples'), findsNothing);

        // Unfolding the section brings it back, struck through.
        await tester.tap(find.text('1 checked item'));
        await tester.pumpAndSettle();
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

      // Drag the first row's handle well past the next two rows, pumping
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

      // Check it off, it stays on the list, struck through, and remembered.
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byIcon(Icons.history), findsNothing);

      // Focusing the new-item row now suggests the checked item back, so it
      // can be re-added, this is what was broken (checked items stayed on
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

    testWidgets(
      'the widget Add item row opens the note ready to type a new item',
      (tester) async {
        api.notes['n1'] = serverNote(
          'n1',
          kind: NoteKind.checklist,
          items: [const ChecklistItem(id: 'a', text: 'Milk')],
        );
        await store.load();
        await tester.pumpWidget(
          harness(
            store,
            const EditorScreen(noteId: 'n1', addChecklistItem: true),
          ),
        );
        await tester.pump();

        final addField = tester.widget<EditableText>(
          find.descendant(
            of: find.widgetWithText(TextField, 'List item'),
            matching: find.byType(EditableText),
          ),
        );
        expect(addField.focusNode.hasFocus, isTrue);
        await flushTimers(tester);
      },
    );

    testWidgets('ticking the last item celebrates the finished list', (
      tester,
    ) async {
      api.notes['n1'] = serverNote(
        'n1',
        kind: NoteKind.checklist,
        items: [
          const ChecklistItem(id: 'a', text: 'Milk', done: true),
          const ChecklistItem(id: 'b', text: 'Eggs'),
        ],
      );
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      await tester.pump();

      // A finished list that merely arrives finished never celebrates: only
      // the tick that finishes it does.
      expect(find.byType(AllDoneBurst), findsNothing);

      await tester.tap(find.byType(Checkbox).first); // the pending 'Eggs'
      await tester.pump();
      expect(find.byType(AllDoneBurst), findsOneWidget);

      // And it clears itself up afterwards.
      await tester.pump(Motion.celebration);
      await tester.pumpAndSettle();
      expect(find.byType(AllDoneBurst), findsNothing);
      await flushTimers(tester);
    });

    testWidgets('ticking an item with others still pending does not', (
      tester,
    ) async {
      api.notes['n1'] = serverNote(
        'n1',
        kind: NoteKind.checklist,
        items: [
          const ChecklistItem(id: 'a', text: 'Milk'),
          const ChecklistItem(id: 'b', text: 'Eggs'),
        ],
      );
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      await tester.pump();

      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      expect(find.byType(AllDoneBurst), findsNothing);
      await flushTimers(tester);
    });

    testWidgets('unticking never celebrates, ticking it back again does', (
      tester,
    ) async {
      api.notes['n1'] = serverNote(
        'n1',
        kind: NoteKind.checklist,
        items: [const ChecklistItem(id: 'a', text: 'Milk', done: true)],
      );
      await store.load();
      await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
      await tester.pump();

      // Checked items are folded away behind their header on open.
      await tester.tap(find.text('1 checked item'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(find.byType(AllDoneBurst), findsNothing);

      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(find.byType(AllDoneBurst), findsOneWidget);
      await tester.pump(Motion.celebration);
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
    testWidgets('desktop grid stays still when its notes fit in the viewport', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      api.notes['n1'] = serverNote('n1', title: 'Short note');
      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();

      final scrollView = tester.widget<CustomScrollView>(
        find.byType(CustomScrollView),
      );
      expect(scrollView.physics, isNull);

      final scrollable = Scrollable.of(tester.element(find.text('Short note')));
      expect(scrollable.position.maxScrollExtent, 0);
      await flushTimers(tester);
    });

    testWidgets('selects multiple masonry notes and applies a label', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      api.notes['n1'] = serverNote('n1', title: 'First note');
      api.notes['n2'] = serverNote('n2', title: 'Second note');
      api.labels['l1'] = const Label(id: 'l1', name: 'work');
      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Select notes'), findsNothing);
      await tester.longPress(find.text('First note'));
      // Settle: the selection bar's actions drop in from above, so they only
      // sit under the taps below once that entrance has landed.
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      expect(find.byTooltip('Archive selected notes'), findsOneWidget);

      await tester.tap(find.text('Second note'));
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(find.byTooltip('Pin selected notes'));
      await tester.pump();
      expect(store.noteById('n1')!.pinned, isTrue);
      expect(store.noteById('n2')!.pinned, isTrue);

      await tester.tap(find.byTooltip('Change selected note colors'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Red'));
      await tester.pump();
      expect(store.noteById('n1')!.color, 'red');
      expect(store.noteById('n2')!.color, 'red');
      await tester.tapAt(const Offset(8, 80));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Share selected notes'));
      await tester.pumpAndSettle();
      expect(find.text('Share 2 notes'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'sam@example.test');
      await tester.tap(find.widgetWithText(FilledButton, 'Share'));
      await tester.pumpAndSettle();
      expect(store.noteById('n1')!.collaborators.single.name, 'sam');
      expect(store.noteById('n2')!.collaborators.single.name, 'sam');

      await tester.tap(find.byTooltip('Add label to selected notes'));
      await tester.pumpAndSettle();
      expect(find.text('Add label to 2 notes'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, 'work'));
      await tester.pump();
      expect(store.noteById('n1')!.labelIds, contains('l1'));
      expect(store.noteById('n2')!.labelIds, contains('l1'));

      await tester.tapAt(const Offset(8, 80));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Archive selected notes'));
      await tester.pump();
      expect(store.noteById('n1')!.archived, isTrue);
      expect(store.noteById('n2')!.archived, isTrue);
      expect(find.byTooltip('Cancel selection'), findsNothing);
      await flushTimers(tester);
    });

    testWidgets('deselecting the last note leaves selection mode', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      api.notes['n1'] = serverNote('n1', title: 'First note');
      api.notes['n2'] = serverNote('n2', title: 'Second note');
      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('First note'));
      await tester.pump();
      await tester.tap(find.text('Second note'));
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);

      // Tapping the selected notes again empties the selection, which is what
      // takes the screen back out of the mode, no Cancel needed.
      await tester.tap(find.text('Second note'));
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.text('First note'));
      await tester.pump();
      expect(find.byTooltip('Cancel selection'), findsNothing);
      expect(find.textContaining('selected'), findsNothing);
      await flushTimers(tester);
    });

    testWidgets('Escape leaves selection mode', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      api.notes['n1'] = serverNote('n1', title: 'First note');
      api.notes['n2'] = serverNote('n2', title: 'Second note');
      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('First note'));
      await tester.pump();
      await tester.tap(find.text('Second note'));
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byTooltip('Cancel selection'), findsNothing);
      expect(find.textContaining('selected'), findsNothing);

      // With nothing selected, Escape goes back to being the search's.
      await tester.enterText(find.byType(TextField).first, 'First');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('First'), findsNothing);
      await flushTimers(tester);
    });

    testWidgets('sort control uses the themed top-bar icon color', (
      tester,
    ) async {
      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pump();

      final sortButton = find.byWidgetPredicate(
        (widget) =>
            widget is PopupMenuButton<SortMode> && widget.tooltip == 'Sort by',
      );
      final popup = tester.widget<PopupMenuButton<SortMode>>(sortButton);
      final theme = Theme.of(tester.element(sortButton));
      final scheme = theme.colorScheme;

      expect(popup.iconColor, scheme.onSurfaceVariant);
      expect(popup.popUpAnimationStyle, Motion.menu);
      expect(
        theme.popupMenuTheme.menuPadding,
        const EdgeInsets.symmetric(vertical: 4),
      );
      final shape = theme.popupMenuTheme.shape! as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(kMenuRadius));
    });

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
      expect(topBar.top, 6);
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

      expect(find.byTooltip('Theme: Auto, tap to change'), findsOneWidget);
      await tester.tap(find.byTooltip('Theme: Auto, tap to change'));
      await tester.pump();
      expect(find.byTooltip('Theme: Light, tap to change'), findsOneWidget);

      await tester.tap(find.byTooltip('Theme: Light, tap to change'));
      await tester.pump();
      expect(find.byTooltip('Theme: Dark, tap to change'), findsOneWidget);

      await tester.tap(find.byTooltip('Theme: Dark, tap to change'));
      await tester.pump();
      expect(find.byTooltip('Theme: Auto, tap to change'), findsOneWidget);
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
      // into search mode, even before anything is typed. Settle first: the
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

      // The pill's menu button opens the drawer (via the scaffold key, the
      // old Scaffold.of(context) lookup threw above the Scaffold).
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationDrawer), findsOneWidget);
    });

    testWidgets('the search field is centred on the bar, not on the gap', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();

      final bar = tester.getRect(find.byType(HomeTopBar));
      // The pill is the nearest animated box around the search glyph.
      final pill = tester.getRect(
        find
            .ancestor(
              of: find.byIcon(Icons.search),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      // Centred on the window. A plain Row can only centre it in what the two
      // clusters leave behind, and the action icons outweigh the branding, so
      // this used to sit tens of pixels right of centre.
      expect((pill.center.dx - bar.center.dx).abs(), lessThan(1));
      // …without running into either cluster.
      expect(pill.left, greaterThan(tester.getRect(find.text('Skippy')).right));
      expect(
        pill.right,
        lessThan(tester.getRect(find.byIcon(Icons.settings_outlined)).left),
      );
    });

    testWidgets('selection actions drop in from above the bar', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      api.notes['n1'] = serverNote('n1', title: 'First note');
      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('First note'));
      await tester.pump();
      final bar = tester.getRect(find.byType(HomeTopBar));
      final entering = tester.getRect(find.byTooltip('Pin selected notes'));
      expect(
        entering.center.dy,
        lessThan(bar.top),
        reason: 'the actions start above the bar and fall into it',
      );

      await tester.pumpAndSettle();
      final landed = tester.getRect(find.byTooltip('Pin selected notes'));
      expect(bar.contains(landed.center), isTrue);
    });
  });

  group('theme switching', () {
    testWidgets('the sidebar changes colour in step with the app', (
      tester,
    ) async {
      var mode = ThemeMode.light;
      late StateSetter setMode;
      // The rail reads saved smart views out of settings, so it needs one.
      final settings = SettingsStore(api: store.api);
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: store),
            ChangeNotifierProvider.value(value: settings),
          ],
          child: StatefulBuilder(
            builder: (context, setState) {
              setMode = setState;
              return MaterialApp(
                theme: buildTheme(Brightness.light),
                darkTheme: buildTheme(Brightness.dark),
                themeMode: mode,
                home: Scaffold(
                  body: AppSidebar(
                    isOpen: true,
                    selection: ViewSelection.notes,
                    onSelect: (_) {},
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      setMode(() => mode = ThemeMode.dark);
      await tester.pump();
      // Mid cross-fade: MaterialApp lerps the theme itself, so anything that
      // *also* animates its own colour is chasing a moving target and lands
      // late. The rail must paint exactly what the theme says, right now.
      await tester.pump(const Duration(milliseconds: 100));

      final scheme = Theme.of(
        tester.element(find.byType(AppSidebar)),
      ).colorScheme;
      final decoration =
          tester
                  .widget<DecoratedBox>(
                    find
                        .descendant(
                          of: find.byType(AppSidebar),
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      expect(decoration.color, scheme.surface);
      // The trailing seam is painted from the same live scheme.
      expect((decoration.border! as Border).right.color, hairlineColor(scheme));
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
      // bar, before the debounce/fetch even runs.
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

  group('smart views', () {
    testWidgets(
      'a saved view filters the grid and narrows further as you type',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        api.notes['n1'] = serverNote(
          'n1',
          title: 'Pinned report',
          pinned: true,
        );
        api.notes['n2'] = serverNote(
          'n2',
          title: 'Pinned recipe',
          pinned: true,
        );
        api.notes['n3'] = serverNote('n3', title: 'Loose thought');
        await store.load();

        final settings = SettingsStore(api: api);
        addTearDown(settings.dispose);
        await settings.load();
        settings.addSavedView(name: 'Pinned', query: 'is:pinned');

        await tester.pumpWidget(homeApp(store, settings: settings));
        await tester.pumpAndSettle();
        expect(find.text('Loose thought'), findsOneWidget);

        // The sidebar carries the view; opening it runs the saved query.
        await tester.tap(find.text('Pinned'));
        await tester.pumpAndSettle();
        expect(find.text('Pinned report'), findsOneWidget);
        expect(find.text('Pinned recipe'), findsOneWidget);
        expect(find.text('Loose thought'), findsNothing);

        // Typing narrows the smart view instead of replacing it: 'recipe' is
        // ANDed with the saved is:pinned rather than searching everything.
        await tester.enterText(find.byType(TextField).first, 'recipe');
        await tester.pumpAndSettle();
        expect(find.text('Pinned recipe'), findsOneWidget);
        expect(find.text('Pinned report'), findsNothing);
        await flushTimers(tester);
      },
    );

    testWidgets('the filter sheet stays open and toggles filters on and off', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      api.notes['n1'] = serverNote('n1', title: 'Pinned report', pinned: true);
      api.notes['n2'] = serverNote(
        'n2',
        title: 'Pinned list',
        pinned: true,
        kind: NoteKind.checklist,
        items: const [ChecklistItem(id: 'i1', text: 'Milk')],
      );
      api.notes['n3'] = serverNote('n3', title: 'Loose thought');
      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Search filters'));
      await tester.pumpAndSettle();

      Finder chip(String token) => find.widgetWithText(FilterChip, token);
      bool selected(String token) =>
          tester.widget<FilterChip>(chip(token)).selected;

      await tester.tap(chip('is:pinned'));
      await tester.pumpAndSettle();
      // The sheet is still up, so a second filter takes one tap, not a
      // reopen, and the chip shows what is already applied.
      expect(chip('is:open'), findsOneWidget);
      expect(selected('is:pinned'), isTrue);

      await tester.tap(chip('is:open'));
      await tester.pumpAndSettle();
      expect(selected('is:open'), isTrue);

      final field = find.byType(TextField).first;
      expect(
        tester.widget<TextField>(field).controller!.text,
        'is:pinned is:open',
      );

      // Tapping an applied filter takes it back out.
      await tester.tap(chip('is:pinned'));
      await tester.pumpAndSettle();
      expect(selected('is:pinned'), isFalse);
      expect(tester.widget<TextField>(field).controller!.text, 'is:open');

      // Close the sheet and the grid reflects what was built.
      await tester.tapAt(const Offset(600, 20));
      await tester.pumpAndSettle();
      expect(find.text('Pinned list'), findsOneWidget);
      expect(find.text('Pinned report'), findsNothing);
      expect(find.text('Loose thought'), findsNothing);
      await flushTimers(tester);
    });
  });

  group('semantic ranking with filters', () {
    /// A home harness whose settings report semantic search available and
    /// meaning-ranking on, the configuration that used to drop the filters.
    Widget semanticHomeApp(NotesStore store, SettingsStore settings) =>
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: store),
            ChangeNotifierProvider.value(value: settings),
            ChangeNotifierProvider(
              create: (_) =>
                  AuthStore(api: ApiClient(baseUrl: 'http://unused')),
            ),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            scaffoldMessengerKey: scaffoldMessengerKey,
            home: const HomeScreen(),
          ),
        );

    testWidgets('a ranked result set is still narrowed by the filters', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      api.notes['n1'] = serverNote('n1', title: 'Wifi password', pinned: true);
      api.notes['n2'] = serverNote('n2', title: 'Router manual');
      // The server ranks both as relevant to the words; only one is pinned.
      api.semanticIds = ['n1', 'n2'];
      await store.load();

      final settings = SettingsStore(api: api)..semanticSearchCapable = true;
      addTearDown(settings.dispose);
      await settings.load();
      settings.setSemanticRanking(true);

      await tester.pumpWidget(semanticHomeApp(store, settings));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'internet access');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      // Ranking alone: both come back, including the one whose title shares no
      // word with the query. That is the point of meaning-ranking.
      expect(find.text('Wifi password'), findsOneWidget);
      expect(find.text('Router manual'), findsOneWidget);

      await tester.enterText(
        find.byType(TextField).first,
        'internet access is:pinned',
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      // The filter applies on top of the ranking rather than being dropped,
      // and the words are NOT re-applied as a substring test (which would have
      // thrown out 'Wifi password' too).
      expect(find.text('Wifi password'), findsOneWidget);
      expect(find.text('Router manual'), findsNothing);
      // Only the words reach the embedder; the operator is not a search phrase.
      expect(api.semanticQueries.last, 'internet access');
      await flushTimers(tester);
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
