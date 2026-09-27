import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/saved_location.dart';
import '../../state/notes_store.dart';
import '../../state/reminder_agenda.dart';
import '../../state/settings_store.dart';
import '../../util/location_geofences.dart';
import '../../util/location_reminder_grants.dart';
import '../../util/snack.dart';
import '../reminder_picker.dart';

/// Most location reminders one account may hold at once; the settings store
/// refuses the next one.
const int _maxLocationReminders = 20;

/// Opens the reminder picker for a note and applies the choice.
///
/// A note is reminded at a time or at a place, never both, so choosing one
/// clears the other. [ensureNote] gives an unsaved draft its id before
/// anything is written to it; without it [noteId] must already exist.
///
/// Answers whether the note's reminder changed.
Future<bool> editNoteReminder(
  BuildContext context, {
  required String? noteId,
  String Function()? ensureNote,
}) async {
  final store = context.read<NotesStore>();
  final settings = context.read<SettingsStore>();
  final note = noteId == null ? null : store.noteById(noteId);
  final selection = await ReminderPicker.show(
    context,
    current: note?.reminderAt,
    currentRepeat: note?.reminderRepeat,
    currentLocation: settings.locationReminderForNote(noteId),
    savedLocations: settings.savedLocations,
    locationMonitored: LocationGeofences.supported,
    use24hTime: settings.use24hTime,
  );
  if (!context.mounted || selection == null) {
    return false;
  }
  String? resolveId() => ensureNote?.call() ?? noteId;

  if (selection.locationId != null) {
    final granted = await ensureLocationReminderGrants();
    if (!context.mounted || !granted) {
      return false;
    }
    final id = resolveId();
    if (id == null) {
      return false;
    }
    final added = settings.setLocationReminder(
      id,
      selection.locationId!,
      selection.locationTrigger!,
      repeats: selection.locationRepeats,
    );
    if (!added) {
      showAppSnack(
        'You can have up to $_maxLocationReminders active location reminders.',
        icon: Icons.location_disabled_outlined,
        kind: SnackKind.warning,
      );
      return false;
    }
    store.setReminder(id, null);
    return true;
  }

  // Clearing never needs a draft materialized; setting a time does.
  final id = selection.at == null ? noteId : resolveId();
  if (id == null) {
    return false;
  }
  settings.removeLocationReminder(id);
  store.setReminder(id, selection.at, selection.repeat);
  return true;
}

/// Opens the reminder picker for one checklist row and applies the choice.
Future<bool> editItemReminder(
  BuildContext context, {
  required String noteId,
  required String itemId,
}) async {
  final store = context.read<NotesStore>();
  final current = store.noteById(noteId)?.reminderForItem(itemId);
  final selection = await ReminderPicker.show(
    context,
    current: current?.at,
    currentRepeat: current?.repeat,
    use24hTime: context.read<SettingsStore>().use24hTime,
  );
  if (!context.mounted || selection == null) {
    return false;
  }
  store.setItemReminder(noteId, itemId, selection.at, selection.repeat);
  return true;
}

/// Moves [reminder] to [at], keeping its cadence, or removes it when [at] is
/// null. Works the same for a note's reminder and a checklist row's.
void rescheduleReminder(
  NotesStore store,
  ReminderOccurrence reminder,
  DateTime? at,
) {
  final item = reminder.item;
  if (item == null) {
    store.setReminder(reminder.note.id, at, reminder.repeat);
    return;
  }
  store.setItemReminder(reminder.note.id, item.id, at, reminder.repeat);
}

/// Removes [reminder], offering to put it back.
void removeReminder(BuildContext context, ReminderOccurrence reminder) {
  final store = context.read<NotesStore>();
  rescheduleReminder(store, reminder, null);
  showAppSnack(
    'Reminder removed',
    icon: Icons.notifications_off_outlined,
    actionLabel: 'Undo',
    onAction: () => rescheduleReminder(store, reminder, reminder.at),
  );
}

/// Ticks off the checklist row [reminder] belongs to. The server drops a
/// checked row's reminder, so undoing restores both.
void completeReminderItem(BuildContext context, ReminderOccurrence reminder) {
  final item = reminder.item;
  if (item == null) {
    return;
  }
  final store = context.read<NotesStore>();
  store.setChecklistItemDone(reminder.note.id, item.id, true);
  showAppSnack(
    'Checked off “${reminder.title}”',
    icon: Icons.check_circle_outline,
    actionLabel: 'Undo',
    onAction: () {
      store.setChecklistItemDone(reminder.note.id, item.id, false);
      rescheduleReminder(store, reminder, reminder.at);
    },
  );
}

/// Removes a note's place reminder, offering to put it back.
void removePlaceReminder(BuildContext context, LocationReminder reminder) {
  final settings = context.read<SettingsStore>();
  settings.removeLocationReminder(reminder.noteId);
  showAppSnack(
    'Reminder removed',
    icon: Icons.location_off_outlined,
    actionLabel: 'Undo',
    onAction: () => settings.setLocationReminder(
      reminder.noteId,
      reminder.locationId,
      reminder.trigger,
      repeats: reminder.repeats,
    ),
  );
}
