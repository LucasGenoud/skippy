import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/screens/editor_screen.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/state/tracker.dart';
import 'package:skippy/util/note_export.dart';

import 'fake_api.dart';
import 'finders.dart';
import 'notes_store_test.dart' show serverNote;
import 'widget_test.dart' show harness, homeApp, flushTimers;

void main() {
  late FakeApi api;
  late NotesStore store;

  setUp(() async {
    api = FakeApi();
    store = NotesStore(api: api, currentUserId: 'u-me');
    await store.load();
  });

  tearDown(() => store.dispose());

  Future<void> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Note? trackerNote() {
    for (final note in store.notesForWidgets) {
      if (note.isTracker) {
        return note;
      }
    }
    return null;
  }

  Tracker tracker() => Tracker.parse(trackerNote()!.content);

  testWidgets('counting on a new tracker saves it, and minus takes one off', (
    tester,
  ) async {
    await phone(tester);
    await tester.pumpWidget(
      harness(store, const EditorScreen(kind: NoteKind.tracker)),
    );
    await tester.pumpAndSettle();
    expect(trackerNote(), isNull);

    await tester.tap(findAction('Add one'));
    await tester.pumpAndSettle();
    await tester.tap(findAction('Add one'));
    await tester.pumpAndSettle();
    expect(tracker().total, 2);
    expect(tracker().on(DateTime.now()), 2);
    expect(find.text('2 today'), findsOneWidget);

    await tester.tap(findAction('Take one off today'));
    await tester.pumpAndSettle();
    expect(tracker().total, 1);

    await tester.tap(findAction('Undo').last);
    await tester.pumpAndSettle();
    expect(tracker().total, 2);
    await flushTimers(tester);
  });

  testWidgets('a habit ticks today off and counts the streak', (tester) async {
    await phone(tester);
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    api.notes['h1'] = serverNote(
      'h1',
      title: 'Run',
      kind: NoteKind.tracker,
      content: Tracker.empty
          .toggle(yesterday)
          .withStyle(TrackerStyle.habit)
          .encode(),
    );
    await store.load();
    await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'h1')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mark today done'));
    await tester.pumpAndSettle();

    expect(tracker().on(DateTime.now()), 1);
    expect(tracker().streak(DateTime.now()), 2);
    expect(find.text('Done today'), findsOneWidget);
    await flushTimers(tester);
  });

  testWidgets('the card counts without opening the note', (tester) async {
    await phone(tester);
    api.notes['c1'] = serverNote(
      'c1',
      title: 'Water',
      kind: NoteKind.tracker,
      content: Tracker.empty.add(DateTime.now(), 4).encode(),
    );
    await store.load();
    await tester.pumpWidget(homeApp(store));
    await tester.pumpAndSettle();

    await tester.tap(findAction('Add one'));
    await tester.pumpAndSettle();

    expect(find.byType(EditorScreen), findsNothing);
    expect(Tracker.parse(store.noteById('c1')!.content).total, 5);
    await flushTimers(tester);
    expect(Tracker.parse(api.notes['c1']!.content).total, 5);
  });

  test('a tracker exports as its summary, never as its log', () {
    final note = serverNote(
      't',
      title: 'Water',
      kind: NoteKind.tracker,
      content: Tracker.empty.add(DateTime.now(), 3).encode(),
    );
    final text = noteToPlainText(note);
    expect(text, contains('3 in all, 3 today'));
    expect(text, isNot(contains('"log"')));
  });
}
