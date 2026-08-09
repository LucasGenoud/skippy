import '../models/note.dart';
import '../models/saved_location.dart';
import 'reminder_schedule.dart';

const String kLocationGeofencePrefix = 'skippy-location-';
const int kMaxLocationReminders = 20;

class PlannedLocationReminder {
  final String geofenceId;
  final String noteId;
  final SavedLocation location;
  final LocationReminderTrigger trigger;
  final String title;
  final String body;

  const PlannedLocationReminder({
    required this.geofenceId,
    required this.noteId,
    required this.location,
    required this.trigger,
    required this.title,
    required this.body,
  });
}

/// Resolves personal reminder settings against the notes currently available
/// on this device. Unknown, trashed and deleted notes stay unregistered without
/// deleting the setting, because an offline cache can temporarily be partial.
List<PlannedLocationReminder> plannedLocationReminders({
  required Iterable<LocationReminder> reminders,
  required Iterable<SavedLocation> locations,
  required Iterable<Note> notes,
}) {
  final locationsById = {
    for (final location in locations) location.id: location,
  };
  final notesById = {for (final note in notes) note.id: note};
  final planned = <PlannedLocationReminder>[];
  for (final reminder in reminders) {
    final location = locationsById[reminder.locationId];
    final note = notesById[reminder.noteId];
    if (location == null || note == null || note.trashed) continue;
    final text = reminderText(note);
    planned.add(
      PlannedLocationReminder(
        geofenceId: '$kLocationGeofencePrefix${note.id}',
        noteId: note.id,
        location: location,
        trigger: reminder.trigger,
        title: text.title,
        body: text.body,
      ),
    );
    if (planned.length == kMaxLocationReminders) break;
  }
  return planned;
}
