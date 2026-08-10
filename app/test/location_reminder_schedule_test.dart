import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/models/saved_location.dart';
import 'package:skippy/util/location_reminder_schedule.dart';

void main() {
  const home = SavedLocation(
    id: 'home',
    name: 'Home',
    latitude: 46.948,
    longitude: 7.4474,
    radiusMeters: 150,
  );

  test('resolves personal settings into an OS geofence', () {
    final now = DateTime.utc(2026);
    final planned = plannedLocationReminders(
      reminders: const [
        LocationReminder(
          noteId: 'note-1',
          locationId: 'home',
          trigger: LocationReminderTrigger.leave,
        ),
      ],
      locations: const [home],
      notes: [
        Note(
          id: 'note-1',
          title: 'Buy milk',
          content: 'Remember oat milk',
          createdAt: now,
          updatedAt: now,
        ),
      ],
    );

    expect(planned.single.geofenceId, 'skippy-location-note-1');
    expect(planned.single.trigger, LocationReminderTrigger.leave);
    expect(planned.single.location, same(home));
    expect(planned.single.repeats, isFalse);
    expect(planned.single.title, 'Buy milk');
    expect(planned.single.body, 'Remember oat milk');
  });

  test('a repeating reminder is planned as one', () {
    final now = DateTime.utc(2026);
    final planned = plannedLocationReminders(
      reminders: const [
        LocationReminder(
          noteId: 'note-1',
          locationId: 'home',
          trigger: LocationReminderTrigger.arrive,
          repeats: true,
        ),
      ],
      locations: const [home],
      notes: [
        Note(
          id: 'note-1',
          title: 'Water plants',
          createdAt: now,
          updatedAt: now,
        ),
      ],
    );

    expect(planned.single.repeats, isTrue);
  });

  group('repeat cooldown', () {
    final now = DateTime(2026, 8, 10, 18);

    test('mutes a second crossing of the same arrival', () {
      final recent = {
        'note-1': now
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
      };

      expect(locationReminderMuted(recent, 'note-1', now), isTrue);
      expect(locationReminderMuted(recent, 'note-2', now), isFalse);
    });

    test('lets a genuine later visit through', () {
      final recent = {
        'note-1': now
            .subtract(kLocationRepeatCooldown + const Duration(seconds: 1))
            .millisecondsSinceEpoch,
      };

      expect(locationReminderMuted(recent, 'note-1', now), isFalse);
    });

    test('a clock that moved backwards does not mute the reminder', () {
      final recent = {
        'note-1': now.add(const Duration(hours: 2)).millisecondsSinceEpoch,
      };

      expect(locationReminderMuted(recent, 'note-1', now), isFalse);
    });

    test('pruning keeps only the entries that can still mute something', () {
      final recent = {
        'fresh': now
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
        'stale': now.subtract(const Duration(days: 3)).millisecondsSinceEpoch,
        'junk': 'not a timestamp',
      };

      expect(prunedRepeatFires(recent, now).keys, ['fresh']);
    });
  });

  test('skips missing and trashed notes without deleting settings', () {
    final now = DateTime.utc(2026);
    final planned = plannedLocationReminders(
      reminders: const [
        LocationReminder(
          noteId: 'missing',
          locationId: 'home',
          trigger: LocationReminderTrigger.arrive,
        ),
        LocationReminder(
          noteId: 'trashed',
          locationId: 'home',
          trigger: LocationReminderTrigger.arrive,
        ),
      ],
      locations: const [home],
      notes: [
        Note(id: 'trashed', trashed: true, createdAt: now, updatedAt: now),
      ],
    );

    expect(planned, isEmpty);
  });
}
