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
    DateTime? reminderAt,
    bool trashed = false,
    bool archived = false,
  }) => Note(
    id: id,
    title: title,
    content: content,
    items: items,
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

      expect([for (final r in planned) r.noteId], [
        'sooner',
        'archived',
        'later',
      ]);
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
}
