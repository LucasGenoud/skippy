import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/util/reminder_schedule.dart';

void main() {
  final created = DateTime.utc(2026, 1, 1);
  final now = DateTime.utc(2026, 7, 1, 12);

  Note note(
    String id, {
    String title = '',
    String content = '',
    List<ChecklistItem> items = const [],
    Map<String, ItemReminder> itemReminders = const {},
    DateTime? reminderAt,
    bool trashed = false,
    bool archived = false,
  }) => Note(
    id: id,
    title: title,
    content: content,
    items: items,
    itemReminders: itemReminders,
    reminderAt: reminderAt,
    trashed: trashed,
    archived: archived,
    createdAt: created,
    updatedAt: created,
  );

  PendingReminder armed(ScheduledReminder r) =>
      (id: r.id, title: r.title, body: r.body, payload: r.payload);

  group('reminder text', () {
    test('mirrors the backend: title fallback, content, and the char cap', () {
      expect(reminderText(note('a', content: 'body')).title, 'Reminder');
      expect(reminderText(note('a', title: '  Milk  ')).title, 'Milk');
      expect(reminderText(note('a', content: '  buy  ')).body, 'buy');

      final long = 'x' * (kNotificationBodyChars + 50);
      final capped = reminderText(note('a', content: long)).body;
      expect(capped.runes.length, kNotificationBodyChars + 1);
      expect(capped.endsWith('…'), isTrue);

      // Exactly at the cap is not truncated.
      final exact = reminderText(
        note('a', content: 'y' * kNotificationBodyChars),
      ).body;
      expect(exact.endsWith('…'), isFalse);
    });

    test('a checklist lists only its still-pending items', () {
      final body = reminderText(
        note(
          'a',
          content: 'ignored when there are items',
          items: const [
            ChecklistItem(id: '1', text: 'Milk', done: true),
            ChecklistItem(id: '2', text: 'Eggs'),
            ChecklistItem(id: '3', text: 'Bread'),
          ],
        ),
      ).body;
      expect(body, 'Eggs\nBread');
    });
  });

  group('notification ids', () {
    test('are stable, positive, and per-note', () {
      final id = reminderNotificationId('note-abc');
      expect(id, reminderNotificationId('note-abc'));
      expect(id, greaterThanOrEqualTo(0));
      // Fits a Java int, which is what Android takes.
      expect(id, lessThanOrEqualTo(0x7FFFFFFF));
      expect(id, isNot(reminderNotificationId('note-abd')));
    });
  });

  group('payloads', () {
    test('round-trip the note id and due time, and reject foreign ones', () {
      final due = DateTime.utc(2026, 7, 2, 9);
      final reminder = ScheduledReminder(
        id: 1,
        noteId: 'note-1',
        dueUtc: due,
        title: 't',
        body: 'b',
      );
      expect(ScheduledReminder.noteIdFromPayload(reminder.payload), 'note-1');
      expect(ScheduledReminder.dueFromPayload(reminder.payload), due);

      // Anything not ours is unrecognized, so a reconcile leaves it alone.
      expect(ScheduledReminder.noteIdFromPayload(null), isNull);
      expect(ScheduledReminder.noteIdFromPayload('someone-else'), isNull);
      expect(ScheduledReminder.dueFromPayload('someone-else|123'), isNull);
    });
  });

  group('planned reminders', () {
    test('takes future reminders only, archived included, soonest first', () {
      final planned = plannedReminders([
        note('none'),
        note('past', reminderAt: now.subtract(const Duration(hours: 1))),
        note('due-now', reminderAt: now),
        note(
          'trashed',
          reminderAt: now.add(const Duration(hours: 1)),
          trashed: true,
        ),
        note('later', reminderAt: now.add(const Duration(days: 2))),
        note('sooner', reminderAt: now.add(const Duration(minutes: 30))),
        note(
          'archived',
          reminderAt: now.add(const Duration(days: 1)),
          archived: true,
        ),
      ], now: now);

      expect(
        [for (final r in planned) r.noteId],
        ['sooner', 'archived', 'later'],
      );
    });

    test('keeps the soonest when over the platform cap', () {
      final notes = [
        for (var i = 0; i < kMaxScheduledReminders + 10; i++)
          note('n$i', reminderAt: now.add(Duration(days: i + 1))),
      ].reversed.toList(); // Arrive in the least helpful order.

      final planned = plannedReminders(notes, now: now);
      expect(planned.length, kMaxScheduledReminders);
      // The furthest-out reminders are the ones dropped, never a near one.
      expect(planned.first.noteId, 'n0');
      expect(planned.last.noteId, 'n${kMaxScheduledReminders - 1}');
    });

    test('converts local reminder times to UTC instants', () {
      final local = DateTime.now().add(const Duration(days: 1));
      final planned = plannedReminders([
        note('a', reminderAt: local),
      ], now: DateTime.now());
      expect(planned.single.dueUtc.isUtc, isTrue);
      expect(
        planned.single.dueUtc.millisecondsSinceEpoch,
        local.millisecondsSinceEpoch,
      );
    });
  });

  group('diff', () {
    test('arms what is missing and leaves untouched alarms alone', () {
      final desired = plannedReminders([
        note('a', title: 'A', reminderAt: now.add(const Duration(hours: 1))),
        note('b', title: 'B', reminderAt: now.add(const Duration(hours: 2))),
      ], now: now);

      // Nothing armed yet: both get scheduled.
      var diff = diffReminders(desired: desired, pending: const [], now: now);
      expect(diff.schedule.length, 2);
      expect(diff.cancel, isEmpty);

      // Everything already armed exactly as desired: a no-op pass.
      diff = diffReminders(
        desired: desired,
        pending: [for (final r in desired) armed(r)],
        now: now,
      );
      expect(diff.isEmpty, isTrue);
    });

    test('re-arms when the time or the text changed', () {
      final before = plannedReminders([
        note('a', title: 'A', reminderAt: now.add(const Duration(hours: 1))),
      ], now: now).single;

      // Reminder moved: same id, new payload.
      final moved = plannedReminders([
        note('a', title: 'A', reminderAt: now.add(const Duration(hours: 5))),
      ], now: now);
      var diff = diffReminders(
        desired: moved,
        pending: [armed(before)],
        now: now,
      );
      expect(diff.schedule.single.noteId, 'a');
      // Rescheduling the same id replaces it, so no cancel is needed.
      expect(diff.cancel, isEmpty);

      // Note retitled: same time, new text.
      final retitled = plannedReminders([
        note('a', title: 'A2', reminderAt: now.add(const Duration(hours: 1))),
      ], now: now);
      diff = diffReminders(
        desired: retitled,
        pending: [armed(before)],
        now: now,
      );
      expect(diff.schedule.single.title, 'A2');
    });

    test('cancels reminders that were cleared, trashed, or capped out', () {
      final gone = plannedReminders([
        note('a', reminderAt: now.add(const Duration(hours: 1))),
      ], now: now).single;

      final diff = diffReminders(
        desired: const [],
        pending: [armed(gone)],
        now: now,
      );
      expect(diff.cancel, [gone.id]);
      expect(diff.schedule, isEmpty);
    });

    test('never cancels a notification it did not schedule', () {
      final diff = diffReminders(
        desired: const [],
        pending: const [
          (id: 7, title: 'Other app', body: null, payload: 'not-ours'),
          (id: 8, title: 'No payload', body: null, payload: null),
        ],
        now: now,
      );
      expect(diff.isEmpty, isTrue);
    });

    test('leaves a just-due reminder armed instead of racing delivery', () {
      // Armed for a moment ago: dropped from `desired` because it is past, but
      // the OS may not have delivered it yet.
      final justDue = ScheduledReminder(
        id: reminderNotificationId('a'),
        noteId: 'a',
        dueUtc: now.subtract(const Duration(minutes: 2)),
        title: 'A',
        body: '',
      );
      var diff = diffReminders(
        desired: const [],
        pending: [armed(justDue)],
        now: now,
      );
      expect(diff.isEmpty, isTrue);

      // Long past the grace window it is spent, and freeing the slot matters.
      diff = diffReminders(
        desired: const [],
        pending: [armed(justDue)],
        now: now.add(kFiredReminderGrace + const Duration(minutes: 1)),
      );
      expect(diff.cancel, [justDue.id]);
    });
  });

  group('checklist item reminders', () {
    final soon = DateTime.utc(2026, 7, 1, 18);
    Note groceries({
      Map<String, ItemReminder> reminders = const {},
      List<ChecklistItem>? items,
      DateTime? reminderAt,
    }) => Note(
      id: 'list',
      title: 'Groceries',
      kind: NoteKind.checklist,
      items:
          items ??
          const [
            ChecklistItem(id: 'milk', text: 'Milk'),
            ChecklistItem(id: 'bread', text: 'Bread'),
          ],
      itemReminders: reminders,
      reminderAt: reminderAt,
      createdAt: created,
      updatedAt: created,
    );

    test('read as the item over the note, mirroring the backend', () {
      final note = groceries();
      expect(itemReminderText(note, 'milk').title, 'Milk');
      expect(itemReminderText(note, 'milk').body, 'Groceries');
      // An item that went away, or has no text, still says something.
      expect(itemReminderText(note, 'gone').title, 'Reminder');
      expect(
        itemReminderText(
          groceries(
            items: const [ChecklistItem(id: 'milk', text: '  ')],
          ),
          'milk',
        ).title,
        'Reminder',
      );

      final long = 'x' * (kNotificationBodyChars + 50);
      final capped = itemReminderText(
        groceries(
          items: [ChecklistItem(id: 'milk', text: long)],
        ),
        'milk',
      ).title;
      expect(capped.runes.length, kNotificationBodyChars + 1);
    });

    test("are armed alongside the note's own, soonest first", () {
      final planned = plannedReminders([
        groceries(
          reminderAt: now.add(const Duration(days: 2)),
          reminders: {
            'milk': ItemReminder(itemId: 'milk', at: soon),
            'bread': ItemReminder(
              itemId: 'bread',
              at: now.add(const Duration(days: 3)),
            ),
          },
        ),
      ], now: now);

      expect([for (final r in planned) r.itemId], ['milk', null, 'bread']);
      expect(planned.first.title, 'Milk');
      expect(planned.first.body, 'Groceries');
      expect(planned[1].title, 'Groceries');
    });

    test('skip checked, missing, and past-due rows', () {
      final planned = plannedReminders([
        groceries(
          items: const [
            ChecklistItem(id: 'milk', text: 'Milk', done: true),
            ChecklistItem(id: 'bread', text: 'Bread'),
            ChecklistItem(id: 'jam', text: 'Jam'),
          ],
          reminders: {
            // Ticked off: cancelled everywhere else, so never armed here.
            'milk': ItemReminder(itemId: 'milk', at: soon),
            // Already due: the server's sweep owns it.
            'bread': ItemReminder(
              itemId: 'bread',
              at: now.subtract(const Duration(hours: 1)),
            ),
            // No such row any more.
            'gone': ItemReminder(itemId: 'gone', at: soon),
            'jam': ItemReminder(itemId: 'jam', at: soon),
          },
        ),
      ], now: now);

      expect([for (final r in planned) r.itemId], ['jam']);
    });

    test(
      'carry the item in their payload and id, leaving note alarms alone',
      () {
        final planned = plannedReminders([
          groceries(
            reminderAt: soon,
            reminders: {'milk': ItemReminder(itemId: 'milk', at: soon)},
          ),
        ], now: now);
        final noteAlarm = planned.firstWhere((r) => r.itemId == null);
        final itemAlarm = planned.firstWhere((r) => r.itemId == 'milk');

        // A note reminder's id is what it always was, so upgrading re-arms
        // nothing that was already armed by an older build.
        expect(noteAlarm.id, reminderNotificationId('list'));
        expect(itemAlarm.id, isNot(noteAlarm.id));
        expect(itemAlarm.id, reminderNotificationId('list', itemId: 'milk'));

        // Both point at the note: tapping either opens the list.
        expect(ScheduledReminder.noteIdFromPayload(itemAlarm.payload), 'list');
        expect(ScheduledReminder.dueFromPayload(itemAlarm.payload), soon);
        expect(itemAlarm.payload, contains('list#milk'));
        // The old two-part payload still parses, so alarms armed before item
        // reminders existed are recognized rather than cancelled as strangers.
        expect(
          ScheduledReminder.noteIdFromPayload('skippy-reminder:list|123'),
          'list',
        );
      },
    );

    test('a moved item reminder re-arms without disturbing its neighbours', () {
      final before = plannedReminders([
        groceries(
          reminders: {
            'milk': ItemReminder(itemId: 'milk', at: soon),
            'bread': ItemReminder(
              itemId: 'bread',
              at: now.add(const Duration(days: 3)),
            ),
          },
        ),
      ], now: now);

      final after = plannedReminders([
        groceries(
          reminders: {
            'milk': ItemReminder(
              itemId: 'milk',
              at: soon.add(const Duration(hours: 2)),
            ),
            'bread': ItemReminder(
              itemId: 'bread',
              at: now.add(const Duration(days: 3)),
            ),
          },
        ),
      ], now: now);

      final diff = diffReminders(
        desired: after,
        pending: [for (final r in before) armed(r)],
        now: now,
      );
      expect(diff.schedule.single.itemId, 'milk');
      expect(diff.cancel, isEmpty);
    });

    test('clearing one cancels exactly that alarm', () {
      final before = plannedReminders([
        groceries(
          reminders: {
            'milk': ItemReminder(itemId: 'milk', at: soon),
            'bread': ItemReminder(
              itemId: 'bread',
              at: now.add(const Duration(days: 3)),
            ),
          },
        ),
      ], now: now);

      final after = plannedReminders([
        groceries(
          reminders: {
            'bread': ItemReminder(
              itemId: 'bread',
              at: now.add(const Duration(days: 3)),
            ),
          },
        ),
      ], now: now);

      final diff = diffReminders(
        desired: after,
        pending: [for (final r in before) armed(r)],
        now: now,
      );
      expect(diff.schedule, isEmpty);
      expect(diff.cancel, [reminderNotificationId('list', itemId: 'milk')]);
    });
  });
}
