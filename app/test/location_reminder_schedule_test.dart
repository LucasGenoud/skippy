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
    expect(planned.single.title, 'Buy milk');
    expect(planned.single.body, 'Remember oat milk');
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
