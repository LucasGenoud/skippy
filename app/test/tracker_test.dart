import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/tracker.dart';

void main() {
  final today = DateTime(2026, 11, 26, 15, 30);
  DateTime daysAgo(int n) => DateTime(2026, 11, 26 - n);

  test('counting adds to the day and the total, never below zero', () {
    var t = Tracker.empty.add(today, 1).add(today, 1).add(daysAgo(3), 5);
    expect(t.on(today), 2);
    expect(t.total, 7);

    t = t.add(today, -5);
    expect(t.on(today), 0);
    expect(t.log.containsKey('2026-11-26'), isFalse);
    expect(t.total, 5);
  });

  test('a log survives encoding, keyed by local day', () {
    final t = Tracker.empty.add(today, 3).withStyle(TrackerStyle.habit);
    final back = Tracker.parse(t.encode());
    expect(back.style, TrackerStyle.habit);
    expect(back.log, {'2026-11-26': 3});
  });

  test('an untouched count is no content at all', () {
    expect(Tracker.empty.encode(), '');
    expect(Tracker.empty.withStyle(TrackerStyle.habit).encode(), isNotEmpty);
  });

  test('unreadable content reads as an empty tracker', () {
    expect(Tracker.parse('nope').log, isEmpty);
    expect(Tracker.parse('{"log":{"x":"y","2026-01-01":-2}}').log, isEmpty);
    expect(Tracker.parse('{"style":"weird"}').style, TrackerStyle.count);
  });

  test('toggling marks a day done and undone', () {
    final done = Tracker.empty.add(today, 4).toggle(today);
    expect(done.on(today), 0);
    expect(Tracker.empty.toggle(today).on(today), 1);
  });

  test('a streak runs back from today, or from yesterday until today ends', () {
    var t = Tracker.empty
        .toggle(daysAgo(1))
        .toggle(daysAgo(2))
        .toggle(daysAgo(4));
    expect(t.streak(today), 2);

    t = t.toggle(today);
    expect(t.streak(today), 3);

    expect(Tracker.empty.toggle(daysAgo(2)).streak(today), 0);
  });

  test('a streak crosses month boundaries', () {
    final t = Tracker.empty
        .toggle(DateTime(2026, 12, 1))
        .toggle(DateTime(2026, 11, 30))
        .toggle(DateTime(2026, 11, 29));
    expect(t.streak(DateTime(2026, 12, 1)), 3);
  });

  test('days in a month count only that month', () {
    final t = Tracker.empty
        .toggle(DateTime(2026, 11, 1))
        .toggle(DateTime(2026, 11, 30))
        .toggle(DateTime(2026, 12, 1));
    expect(t.daysInMonth(today), 2);
  });

  test('the summary reads where a tracker stands', () {
    final count = Tracker.empty.add(today, 2).add(daysAgo(5), 3);
    expect(count.summary(today), '5 in all, 2 today');
    final habit = Tracker.empty.toggle(today).withStyle(TrackerStyle.habit);
    expect(habit.summary(today), '1 day streak, 1 day this month');
  });

  test('a tracker has no prose for search, exports or previews', () {
    final note = Note(
      id: 'n',
      kind: NoteKind.fromWire('tracker'),
      content: Tracker.empty.add(today, 1).encode(),
      createdAt: today,
      updatedAt: today,
    );
    expect(note.kind, NoteKind.tracker);
    expect(note.kind.holdsData, isTrue);
    expect(note.prose, '');
  });
}
