import '../models/note.dart';
import '../models/saved_location.dart';
import '../util/widget_payload.dart';

/// Pure rules behind the Reminders view: which reminders exist, when they
/// fall, and how they group into days. The widgets only lay these out.
///
/// Two kinds of reminder share the view:
///
/// ```text
///   timed   note.reminderAt, note.itemReminders   -> placed on days
///   place   settings.locationReminders            -> no day, grouped by place
/// ```

/// Calendar day of [t], as local midnight. Days are the unit everything here
/// groups by, so this is the one place a time is truncated to one.
DateTime dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

/// One time a reminder goes off: a note's own, or one checklist row's.
class ReminderOccurrence {
  final Note note;

  /// The checklist row this reminder belongs to, or null for the note's own.
  final ChecklistItem? item;
  final DateTime at;
  final ReminderRepeat? repeat;

  /// A later turn of a repeating reminder, drawn by the calendar. Only the
  /// stored occurrence can be moved or snoozed; a projected one is a forecast.
  final bool projected;

  const ReminderOccurrence({
    required this.note,
    required this.at,
    this.item,
    this.repeat,
    this.projected = false,
  });

  /// Unique per occurrence, for keyed lists: `noteId`, `noteId#itemId`, plus
  /// the time for projected turns so one reminder's days never collide.
  String get key {
    final base = item == null ? note.id : '${note.id}#${item!.id}';
    return projected ? '$base@${at.millisecondsSinceEpoch}' : base;
  }

  /// What the row reads as: the item's own text, or the note's title.
  String get title {
    final text = item?.text.trim();
    if (text != null && text.isNotEmpty) {
      return text;
    }
    return widgetDisplayTitle(note);
  }

  ReminderOccurrence _at(DateTime when) => ReminderOccurrence(
    note: note,
    item: item,
    at: when,
    repeat: repeat,
    projected: true,
  );
}

/// Every stored reminder on [notes], soonest first.
///
/// Trashed notes are skipped, and so is a reminder whose row is gone or
/// already checked: the server prunes those, and a stale local copy should
/// not show a task that is no longer there to do.
List<ReminderOccurrence> scheduledReminders(Iterable<Note> notes) {
  final scheduled = <ReminderOccurrence>[];
  for (final note in notes) {
    if (note.trashed) {
      continue;
    }
    if (note.reminderAt case final DateTime at) {
      scheduled.add(
        ReminderOccurrence(note: note, at: at, repeat: note.reminderRepeat),
      );
    }
    for (final item in note.items) {
      final reminder = note.itemReminders[item.id];
      if (reminder == null || item.done) {
        continue;
      }
      scheduled.add(
        ReminderOccurrence(
          note: note,
          item: item,
          at: reminder.at,
          repeat: reminder.repeat,
        ),
      );
    }
  }
  scheduled.sort(_bySoonest);
  return scheduled;
}

int _bySoonest(ReminderOccurrence a, ReminderOccurrence b) {
  final byTime = a.at.compareTo(b.at);
  if (byTime != 0) {
    return byTime;
  }
  return a.title.toLowerCase().compareTo(b.title.toLowerCase());
}

/// The [n]th turn of a reminder first due at [first]. Months clamp to their
/// last day (Jan 31 -> Feb 28), as the server's `checked_add_months` does, so
/// the calendar draws the same days the alarms actually fire on.
DateTime _nthRepeat(DateTime first, ReminderRepeat repeat, int n) {
  DateTime addMonths(int months) {
    final month = first.month - 1 + months;
    final year = first.year + month ~/ 12;
    final monthOfYear = month % 12 + 1;
    final lastDay = DateTime(year, monthOfYear + 1, 0).day;
    return DateTime(
      year,
      monthOfYear,
      first.day > lastDay ? lastDay : first.day,
      first.hour,
      first.minute,
    );
  }

  DateTime addDays(int days) => DateTime(
    first.year,
    first.month,
    first.day + days,
    first.hour,
    first.minute,
  );

  return switch (repeat) {
    ReminderRepeat.daily => addDays(n),
    ReminderRepeat.weekly => addDays(n * DateTime.daysPerWeek),
    ReminderRepeat.monthly => addMonths(n),
    ReminderRepeat.yearly => addMonths(n * DateTime.monthsPerYear),
  };
}

/// Rough count of turns between [first] and [from], so projecting a daily
/// reminder into a month two years out does not walk every day in between.
int _turnsBefore(DateTime first, ReminderRepeat repeat, DateTime from) {
  final days = from.difference(first).inDays;
  final turns = switch (repeat) {
    ReminderRepeat.daily => days,
    ReminderRepeat.weekly => days ~/ DateTime.daysPerWeek,
    ReminderRepeat.monthly =>
      (from.year - first.year) * DateTime.monthsPerYear +
          from.month -
          first.month,
    ReminderRepeat.yearly => from.year - first.year,
  };
  // One turn of slack: the estimate may overshoot by a partial period.
  return turns > 1 ? turns - 1 : 0;
}

/// Every occurrence of [scheduled] in `[from, to)`, repeats included, soonest
/// first. What the calendar draws: a weekly reminder shows on every week of
/// the month, not only on its next one.
List<ReminderOccurrence> occurrencesBetween(
  Iterable<ReminderOccurrence> scheduled,
  DateTime from,
  DateTime to,
) {
  final found = <ReminderOccurrence>[];
  for (final reminder in scheduled) {
    final repeat = reminder.repeat;
    if (repeat == null) {
      if (!reminder.at.isBefore(from) && reminder.at.isBefore(to)) {
        found.add(reminder);
      }
      continue;
    }
    // Turn 0 is the stored occurrence; earlier ones have already fired.
    for (var n = _turnsBefore(reminder.at, repeat, from); ; n++) {
      final when = _nthRepeat(reminder.at, repeat, n);
      if (!when.isBefore(to)) {
        break;
      }
      if (when.isBefore(from)) {
        continue;
      }
      found.add(n == 0 ? reminder : reminder._at(when));
    }
  }
  found.sort(_bySoonest);
  return found;
}

/// Reminders per day in `[from, to)`, for the calendar's markers.
Map<DateTime, List<ReminderOccurrence>> remindersByDay(
  Iterable<ReminderOccurrence> scheduled,
  DateTime from,
  DateTime to,
) {
  final days = <DateTime, List<ReminderOccurrence>>{};
  for (final occurrence in occurrencesBetween(scheduled, from, to)) {
    days.putIfAbsent(dayOf(occurrence.at), () => []).add(occurrence);
  }
  return days;
}

/// One day of the agenda.
class AgendaDay {
  final DateTime day;
  final List<ReminderOccurrence> reminders;

  const AgendaDay(this.day, this.reminders);
}

/// The agenda: stored reminders from before today, then one group per day
/// that has any, in order. Each reminder appears once, at its next turn;
/// repeats are the calendar's business.
({List<ReminderOccurrence> earlier, List<AgendaDay> days}) agendaFor(
  List<ReminderOccurrence> scheduled,
  DateTime now,
) {
  final today = dayOf(now);
  final earlier = <ReminderOccurrence>[];
  final days = <AgendaDay>[];
  for (final reminder in scheduled) {
    final day = dayOf(reminder.at);
    if (day.isBefore(today)) {
      earlier.add(reminder);
      continue;
    }
    if (days.isEmpty || days.last.day != day) {
      days.add(AgendaDay(day, []));
    }
    days.last.reminders.add(reminder);
  }
  return (earlier: earlier, days: days);
}

/// A note reminded at a saved place.
class PlaceReminder {
  final Note note;
  final LocationReminder reminder;

  /// Null only if the place was deleted underneath its reminder, which the
  /// settings store normally prevents.
  final SavedLocation? place;

  const PlaceReminder(this.note, this.reminder, this.place);

  String get title => widgetDisplayTitle(note);
  String get placeName => place?.name ?? 'Unknown place';
}

/// [reminders] joined with their notes and places, grouped by place name and
/// then by title. A reminder whose note is not in [notes] (another workspace,
/// trashed, or filtered out by a search) is left out.
List<PlaceReminder> placeReminders({
  required Iterable<Note> notes,
  required Iterable<LocationReminder> reminders,
  required Iterable<SavedLocation> places,
}) {
  final notesById = {
    for (final note in notes)
      if (!note.trashed) note.id: note,
  };
  final placesById = {for (final place in places) place.id: place};
  final found = [
    for (final reminder in reminders)
      if (notesById[reminder.noteId] case final Note note)
        PlaceReminder(note, reminder, placesById[reminder.locationId]),
  ];
  found.sort((a, b) {
    final byPlace = a.placeName.toLowerCase().compareTo(
      b.placeName.toLowerCase(),
    );
    if (byPlace != 0) {
      return byPlace;
    }
    return a.title.toLowerCase().compareTo(b.title.toLowerCase());
  });
  return found;
}

/// When "morning" is, for snoozes that move a reminder to another day. Matches
/// the picker's own morning preset.
const int _morningHour = 9;

/// Quick ways to push a one-shot reminder later. Measured from now rather than
/// from when it was due, so snoozing something already late never lands it in
/// the past again.
enum ReminderSnooze {
  hour('In 1 hour'),
  tomorrow('Tomorrow morning'),
  nextWeek('Next week');

  final String label;

  const ReminderSnooze(this.label);

  DateTime after(DateTime now) => switch (this) {
    hour => DateTime(now.year, now.month, now.day, now.hour + 1, now.minute),
    tomorrow => DateTime(now.year, now.month, now.day + 1, _morningHour),
    nextWeek => DateTime(
      now.year,
      now.month,
      now.day + DateTime.daysPerWeek,
      _morningHour,
    ),
  };
}

/// [at] moved onto [day], keeping its time of day: what dropping a reminder
/// on another calendar day means.
DateTime movedToDay(DateTime at, DateTime day) =>
    DateTime(day.year, day.month, day.day, at.hour, at.minute);
