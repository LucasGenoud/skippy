import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/models/saved_location.dart';
import 'package:skippy/state/reminder_agenda.dart';

void main() {
  final created = DateTime(2026, 1, 1);
  final now = DateTime(2026, 10, 7, 12);

  Note note(
    String id, {
    String title = '',
    List<ChecklistItem> items = const [],
    Map<String, ItemReminder> itemReminders = const {},
    DateTime? reminderAt,
    ReminderRepeat? repeat,
    bool trashed = false,
  }) => Note(
    id: id,
    title: title,
    items: items,
    itemReminders: itemReminders,
    reminderAt: reminderAt,
    reminderRepeat: repeat,
    trashed: trashed,
    createdAt: created,
    updatedAt: created,
  );

  group('scheduled reminders', () {
    test('lists note and item reminders soonest first', () {
      final scheduled = scheduledReminders([
        note('a', title: 'Later', reminderAt: DateTime(2026, 10, 9, 9)),
        note(
          'b',
          title: 'Groceries',
          items: const [ChecklistItem(id: 'milk', text: 'Milk')],
          itemReminders: {
            'milk': ItemReminder(itemId: 'milk', at: DateTime(2026, 10, 8)),
          },
        ),
      ]);

      expect([for (final r in scheduled) r.key], ['b#milk', 'a']);
      expect(scheduled.first.title, 'Milk');
    });

    test('skips trashed notes and checked or missing items', () {
      final scheduled = scheduledReminders([
        note('gone', reminderAt: now, trashed: true),
        note(
          'list',
          items: const [ChecklistItem(id: 'done', text: 'Done', done: true)],
          itemReminders: {
            'done': ItemReminder(itemId: 'done', at: now),
            'missing': ItemReminder(itemId: 'missing', at: now),
          },
        ),
      ]);

      expect(scheduled, isEmpty);
    });
  });

  group('occurrences between', () {
    final october = (DateTime(2026, 10), DateTime(2026, 11));

    test('projects a weekly reminder onto every week of the month', () {
      final scheduled = scheduledReminders([
        note(
          'w',
          reminderAt: DateTime(2026, 10, 7, 9),
          repeat: ReminderRepeat.weekly,
        ),
      ]);

      final days = [
        for (final r in occurrencesBetween(scheduled, october.$1, october.$2))
          r.at.day,
      ];
      expect(days, [7, 14, 21, 28]);
    });

    test('only the stored turn is not projected', () {
      final scheduled = scheduledReminders([
        note(
          'd',
          reminderAt: DateTime(2026, 10, 30, 9),
          repeat: ReminderRepeat.daily,
        ),
      ]);

      final found = occurrencesBetween(scheduled, october.$1, october.$2);
      expect([for (final r in found) r.projected], [false, true]);
      expect(found.map((r) => r.key).toSet(), hasLength(2));
    });

    test('a monthly reminder clamps to the end of a short month', () {
      final scheduled = scheduledReminders([
        note(
          'm',
          reminderAt: DateTime(2026, 1, 31, 9),
          repeat: ReminderRepeat.monthly,
        ),
      ]);

      final february = occurrencesBetween(
        scheduled,
        DateTime(2027, 2),
        DateTime(2027, 3),
      );
      expect(february.single.at, DateTime(2027, 2, 28, 9));
    });

    test('a one-shot reminder shows only on its own day', () {
      final scheduled = scheduledReminders([
        note('o', reminderAt: DateTime(2026, 9, 30, 23)),
      ]);

      expect(occurrencesBetween(scheduled, october.$1, october.$2), isEmpty);
    });
  });

  test('the agenda groups by day and sets earlier days apart', () {
    final scheduled = scheduledReminders([
      note('past', reminderAt: DateTime(2026, 10, 5, 9)),
      note('morning', reminderAt: DateTime(2026, 10, 7, 8)),
      note('evening', reminderAt: DateTime(2026, 10, 7, 20)),
      note('friday', reminderAt: DateTime(2026, 10, 9, 9)),
    ]);

    final agenda = agendaFor(scheduled, now);

    expect([for (final r in agenda.earlier) r.note.id], ['past']);
    expect(
      [for (final d in agenda.days) d.day],
      [DateTime(2026, 10, 7), DateTime(2026, 10, 9)],
    );
    // Today keeps what already went off this morning.
    expect(
      [for (final r in agenda.days.first.reminders) r.note.id],
      ['morning', 'evening'],
    );
  });

  test('place reminders join their note and place, grouped by place', () {
    const home = SavedLocation(
      id: 'home',
      name: 'Home',
      latitude: 0,
      longitude: 0,
    );
    const work = SavedLocation(
      id: 'work',
      name: 'Work',
      latitude: 1,
      longitude: 1,
    );
    final found = placeReminders(
      notes: [
        note('plants', title: 'Water plants'),
        note('badge', title: 'Badge'),
        note('bin', title: 'Bins', trashed: true),
      ],
      reminders: const [
        LocationReminder(
          noteId: 'badge',
          locationId: 'work',
          trigger: LocationReminderTrigger.arrive,
        ),
        LocationReminder(
          noteId: 'plants',
          locationId: 'home',
          trigger: LocationReminderTrigger.arrive,
        ),
        LocationReminder(
          noteId: 'bin',
          locationId: 'home',
          trigger: LocationReminderTrigger.leave,
        ),
        LocationReminder(
          noteId: 'elsewhere',
          locationId: 'home',
          trigger: LocationReminderTrigger.leave,
        ),
      ],
      places: const [home, work],
    );

    expect(
      [for (final r in found) (r.placeName, r.title)],
      [('Home', 'Water plants'), ('Work', 'Badge')],
    );
  });
}
