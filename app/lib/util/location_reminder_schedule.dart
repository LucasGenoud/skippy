import '../models/note.dart';
import '../models/saved_location.dart';
import 'reminder_schedule.dart';

const String kLocationGeofencePrefix = 'skippy-location-';
const int kMaxLocationReminders = 20;

/// How long a repeating reminder stays quiet after it fires.
///
/// A one-shot reminder cannot fire twice because delivering it retires it. A
/// repeating one has no such flag, and a wobbling fix crosses the edge of a
/// radius several times over what the user experienced as a single arrival, so
/// it goes quiet for a while instead.
const Duration kLocationRepeatCooldown = Duration(minutes: 5);

/// Whether [noteId] fired recently enough that this crossing is that same
/// arrival seen again. [recentFires] maps note id to epoch milliseconds.
bool locationReminderMuted(
  Map<String, dynamic> recentFires,
  String noteId,
  DateTime now,
) {
  final last = recentFires[noteId];
  if (last is! int) return false;
  final since = now.difference(DateTime.fromMillisecondsSinceEpoch(last));
  // A negative gap means the clock moved backwards (travel, NTP correction);
  // that should not mute the reminder until the clock catches up.
  return !since.isNegative && since < kLocationRepeatCooldown;
}

/// Drops the entries that can no longer mute anything, so the record cannot
/// grow for as long as the app stays installed.
Map<String, dynamic> prunedRepeatFires(
  Map<String, dynamic> recentFires,
  DateTime now,
) => {
  for (final entry in recentFires.entries)
    if (locationReminderMuted(recentFires, entry.key, now))
      entry.key: entry.value,
};

class PlannedLocationReminder {
  final String geofenceId;
  final String noteId;
  final SavedLocation location;
  final LocationReminderTrigger trigger;

  /// Whether the geofence survives its own notification. See
  /// [LocationReminder.repeats].
  final bool repeats;
  final String title;
  final String body;

  const PlannedLocationReminder({
    required this.geofenceId,
    required this.noteId,
    required this.location,
    required this.trigger,
    required this.repeats,
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
        repeats: reminder.repeats,
        title: text.title,
        body: text.body,
      ),
    );
    if (planned.length == kMaxLocationReminders) break;
  }
  return planned;
}
