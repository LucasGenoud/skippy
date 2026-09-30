import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/models/saved_location.dart';
import 'package:skippy/screens/editor_screen.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/state/settings_store.dart';
import 'package:skippy/util/motion.dart';
import 'package:skippy/util/snack.dart';
import 'package:skippy/widgets/reminders/reminder_tiles.dart';
import 'package:skippy/widgets/reminders/reminders_view.dart';

import 'board_widget_test.dart' show flushTimers, setViewport;
import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote;

void main() {
  late FakeApi api;
  late NotesStore store;
  late SettingsStore settings;
  final now = DateTime.now();

  /// [days] from today at [hour], never "today" itself so no test depends on
  /// what time of day it runs.
  DateTime inDays(int days, int hour) =>
      DateTime(now.year, now.month, now.day + days, hour);

  setUp(() async {
    api = FakeApi();
    store = NotesStore(api: api, currentUserId: 'u-me');
    settings = SettingsStore(api: api);
    api.notes['rent'] = serverNote(
      'rent',
      title: 'Pay rent',
      reminderAt: inDays(1, 9),
    );
    api.notes['list'] = serverNote(
      'list',
      title: 'Groceries',
      kind: NoteKind.checklist,
      items: const [ChecklistItem(id: 'milk', text: 'Milk')],
      itemReminders: {
        'milk': ItemReminder(
          itemId: 'milk',
          at: inDays(2, 18),
          repeat: ReminderRepeat.weekly,
        ),
      },
    );
    api.notes['plants'] = serverNote('plants', title: 'Water the plants');
    await store.load();
    final home = settings.addSavedLocation(
      name: 'Home',
      latitude: 46.2,
      longitude: 6.1,
      radiusMeters: 150,
    );
    settings.setLocationReminder(
      'plants',
      home.id,
      LocationReminderTrigger.arrive,
    );
  });

  tearDown(() => store.dispose());

  Widget app({String query = ''}) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: store),
      ChangeNotifierProvider.value(value: settings),
    ],
    child: MaterialApp(
      scaffoldMessengerKey: scaffoldMessengerKey,
      home: Scaffold(body: RemindersView(query: query)),
    ),
  );

  testWidgets('lists timed reminders by day and place reminders apart', (
    tester,
  ) async {
    await setViewport(tester, const Size(420, 1000));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Tomorrow'), findsOneWidget);
    expect(find.text('Pay rent'), findsOneWidget);
    // A checklist row's reminder reads as the row, filed under its note.
    expect(find.text('Milk'), findsOneWidget);
    expect(find.text('Groceries'), findsOneWidget);
    // A note reminded only at a place still belongs here.
    expect(find.text('At a place'), findsOneWidget);
    expect(find.text('Water the plants'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    await flushTimers(tester);
  });

  testWidgets('ticking a row off checks the item and drops its reminder', (
    tester,
  ) async {
    await setViewport(tester, const Size(420, 1000));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Mark done'));
    await tester.pumpAndSettle();

    final list = store.noteById('list')!;
    expect(list.items.single.done, isTrue);
    expect(list.itemReminders, isEmpty);
    expect(find.text('Milk'), findsNothing);
    await flushTimers(tester);
  });

  testWidgets('the calendar lists a picked day, repeats included', (
    tester,
  ) async {
    await setViewport(tester, const Size(420, 1000));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Calendar'));
    await tester.pumpAndSettle();

    // A week after the stored turn, the weekly row comes round again. Late
    // in a month that day is on the next month's page.
    final repeat = find.bySemanticsLabel(
      RegExp('^${RegExp.escape(settings.formatDate(inDays(9, 0)))},'),
    );
    if (repeat.evaluate().isEmpty) {
      await tester.tap(find.byTooltip('Next month'));
      await tester.pumpAndSettle();
    }
    await tester.tap(repeat);
    await tester.pumpAndSettle();

    expect(find.text('Milk'), findsOneWidget);
    expect(find.text('Pay rent'), findsNothing);
    await flushTimers(tester);
  });

  testWidgets(
    'a reminder dropped on a calendar day moves there',
    (tester) async {
      await setViewport(tester, const Size(1300, 900));
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      final target = inDays(3, 0);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Pay rent')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(
          find.bySemanticsLabel(
            RegExp('^${RegExp.escape(settings.formatDate(target))},'),
          ),
        ),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // Same time of day, new day.
      expect(store.noteById('rent')!.reminderAt, inDays(3, 9));
      await flushTimers(tester);
    },
    // Carrying a row onto the calendar is a pointer affordance.
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('a wide row grows into the editor and shrinks back into it', (
    tester,
  ) async {
    await setViewport(tester, const Size(1024, 768));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final row = tester.getRect(
      find.ancestor(
        of: find.text('Pay rent'),
        matching: find.byType(ReminderTile),
      ),
    );

    // A row is wider than the dialog and far shorter, so the dialog has to
    // start as the row itself rather than a full-height copy centred on it.
    await tester.tap(find.text('Pay rent'));
    await tester.pump();
    final opening = tester.getRect(find.byType(EditorScreen));
    expect(opening.topLeft, offsetMoreOrLessEquals(row.topLeft, epsilon: 1));
    expect(opening.width, moreOrLessEquals(row.width, epsilon: 1));

    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(EditorScreen))).pop();
    await tester.pump();
    await tester.pump(Motion.slow - const Duration(milliseconds: 10));
    final closing = tester.getRect(find.byType(EditorScreen));
    expect(closing.topLeft, offsetMoreOrLessEquals(row.topLeft, epsilon: 1));
    expect(closing.width, moreOrLessEquals(row.width, epsilon: 1));

    await tester.pumpAndSettle();
    await flushTimers(tester);
  });

  testWidgets('the search box narrows reminders like it does the grid', (
    tester,
  ) async {
    await setViewport(tester, const Size(420, 1000));
    await tester.pumpWidget(app(query: 'rent'));
    await tester.pumpAndSettle();

    expect(find.text('Pay rent'), findsOneWidget);
    expect(find.text('Milk'), findsNothing);
    expect(find.text('Water the plants'), findsNothing);
    await flushTimers(tester);
  });

  testWidgets('a group keeps its side border under its rows', (tester) async {
    await setViewport(tester, const Size(420, 1000));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    // A row's opaque fill must not paint over the group's hairline.
    final group = find.byType(ReminderGroup).first;
    final box = tester.renderObject<RenderBox>(group);
    final boundary =
        tester.renderObject<RenderObject>(
              find
                  .ancestor(of: group, matching: find.byType(RepaintBoundary))
                  .first,
            )
            as RenderRepaintBoundary;
    final surface = Theme.of(tester.element(group)).colorScheme.surface;
    final origin = box.localToGlobal(Offset.zero, ancestor: boundary);
    final edge = await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = (await image.toByteData())!;
      final x = origin.dx.round();
      final y = (origin.dy + box.size.height / 2).round();
      final i = (y * image.width + x) * 4;
      return Color.fromARGB(
        bytes.getUint8(i + 3),
        bytes.getUint8(i),
        bytes.getUint8(i + 1),
        bytes.getUint8(i + 2),
      );
    });
    expect(edge, isNot(surface));
    await flushTimers(tester);
  });
}
