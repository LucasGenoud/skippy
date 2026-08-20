/// Pure rules for mirroring note reminders onto this device's OS alarm
/// scheduler. Kept free of `flutter_local_notifications` so the decisions that
/// matter for reliability (which reminders get armed, and what changed since
/// the last pass) are unit-testable without a platform channel.
library;

import '../models/note.dart';

/// Max characters of note content in a notification body. Mirrors the
/// backend's `NOTIFICATION_BODY_CHARS` so a reminder reads the same whether it
/// arrives from this device or from the server's ntfy/Telegram sweep.
const int kNotificationBodyChars = 500;

/// How many reminders may be armed at once. iOS keeps at most 64 pending local
/// notifications per app and silently drops anything past that, so the soonest
/// reminders win: a reminder set years out must never cost us a near one.
const int kMaxScheduledReminders = 64;

/// Marks a notification payload as one of ours, so a reconcile can tell our
/// reminders apart from anything else this app might schedule later.
const String _payloadPrefix = 'skippy-reminder:';

/// Separates the note id from the due timestamp inside a notification payload.
/// Note ids are UUIDs, so this never occurs in one.
const String _payloadSeparator = '|';

/// Separates the note id from the checklist item id, for a reminder set on one
/// row rather than on the whole note. Absent for a note reminder, so a payload
/// written before item reminders existed still reads correctly and the alarms
/// armed by an older build survive the upgrade.
const String _payloadItemSeparator = '#';

/// One reminder armed with the OS notification scheduler.
class ScheduledReminder {
  /// Stable id, derived from the note (and item) via [reminderNotificationId].
  final int id;
  final String noteId;

  /// The checklist item this reminder belongs to, or null for the note's own
  /// reminder.
  final String? itemId;

  /// When it fires, in UTC. Converted to a device-local zoned time at the
  /// platform boundary: scheduling must respect DST, so the offset can't be
  /// baked in here.
  final DateTime dueUtc;
  final String title;
  final String body;

  const ScheduledReminder({
    required this.id,
    required this.noteId,
    required this.dueUtc,
    required this.title,
    required this.body,
    this.itemId,
  });

  /// Round-trips the note id and the exact due time through the OS, so a
  /// reconcile can tell an untouched alarm from a rescheduled one by reading
  /// back what is actually pending, so there is no local bookkeeping to drift
  /// out of sync.
  String get payload =>
      '$_payloadPrefix$noteId'
      '${itemId == null ? '' : '$_payloadItemSeparator$itemId'}'
      '$_payloadSeparator${dueUtc.millisecondsSinceEpoch}';

  /// The note a delivered notification refers to, for tap handling. Returns
  /// null for anything that isn't one of our reminder payloads.
  static String? noteIdFromPayload(String? payload) {
    if (payload == null || !payload.startsWith(_payloadPrefix)) return null;
    final rest = payload.substring(_payloadPrefix.length);
    final cut = rest.indexOf(_payloadSeparator);
    var id = cut < 0 ? rest : rest.substring(0, cut);
    // An item reminder still points at the note holding the item: tapping one
    // opens the list, there is nowhere else to go.
    final item = id.indexOf(_payloadItemSeparator);
    if (item >= 0) id = id.substring(0, item);
    return id.isEmpty ? null : id;
  }

  /// The due time encoded in one of our payloads, or null if it isn't ours or
  /// carries no parsable timestamp.
  static DateTime? dueFromPayload(String? payload) {
    if (payload == null || !payload.startsWith(_payloadPrefix)) return null;
    final cut = payload.lastIndexOf(_payloadSeparator);
    if (cut < 0) return null;
    final millis = int.tryParse(payload.substring(cut + 1));
    if (millis == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }
}

/// A reminder the OS reports as currently armed. Mirrors the fields of the
/// plugin's `PendingNotificationRequest` without depending on it.
typedef PendingReminder = ({
  int id,
  String? title,
  String? body,
  String? payload,
});

/// Stable 32-bit notification id for a note. Android notification ids are Java
/// ints, so this is an FNV-1a hash masked to a positive value. Deriving it from
/// the note id (rather than handing out counters) means any pass, including
/// the first one after a cold start, can cancel or replace a note's alarm
/// without remembering what it assigned last time.
int reminderNotificationId(String noteId, {String? itemId}) {
  // Hashing the same string the payload carries keeps a note reminder's id
  // exactly what it has always been, so upgrading re-arms nothing.
  final key = itemId == null ? noteId : '$noteId$_payloadItemSeparator$itemId';
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash ^= unit;
    // FNV prime, kept inside 32 bits (JS numbers have no int32 wraparound).
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash & 0x7FFFFFFF;
}

/// Cap a body the way the backend does: [kNotificationBodyChars] characters
/// plus an ellipsis when there was more.
String _capBody(String body) {
  final runes = body.runes;
  if (runes.length <= kNotificationBodyChars) return body;
  return '${String.fromCharCodes(runes.take(kNotificationBodyChars))}…';
}

/// Title and body for a due checklist-item reminder, mirroring the backend's
/// `item_reminder_notification`: the item's own text over the note holding it
/// ("Milk" / "Groceries"). The item leads because the item is the thing to do.
({String title, String body}) itemReminderText(Note note, String itemId) {
  final text = note.items
      .where((item) => item.id == itemId)
      .map((item) => item.text.trim())
      .firstOrNull;
  return (
    title: text == null || text.isEmpty ? 'Reminder' : _capBody(text),
    body: note.title.trim(),
  );
}

/// Title and body for a due note reminder, mirroring the backend's
/// `reminder_notification` so the same reminder reads identically whichever
/// transport delivers it: the note's title over its content, or over a
/// checklist's still-pending items.
({String title, String body}) reminderText(Note note) {
  final trimmedTitle = note.title.trim();
  final body = note.items.isEmpty
      ? note.content.trim()
      : [
          for (final item in note.items)
            if (!item.done) item.text,
        ].join('\n');
  return (
    title: trimmedTitle.isEmpty ? 'Reminder' : trimmedTitle,
    body: _capBody(body),
  );
}

/// The reminders this device should have armed, soonest first.
///
/// Matches the drawer's Reminders view (`NoteView.reminders`): any non-trashed
/// note with a reminder, archived included, plus one alarm for each of its
/// checklist items that carries one. Reminders already due are skipped: the
/// server's sweep owns those, and re-announcing a long-past reminder the
/// moment the app syncs is noise rather than a reminder.
///
/// Note and item reminders compete for the same [kMaxScheduledReminders]
/// slots, soonest first. A list with dozens of dated rows can therefore crowd
/// out a note reminder set years away, which is the right priority: the near
/// alarm is the one a person is relying on.
List<ScheduledReminder> plannedReminders(
  Iterable<Note> notes, {
  required DateTime now,
}) {
  final nowUtc = now.toUtc();
  final planned = <ScheduledReminder>[];
  for (final note in notes) {
    if (note.trashed) continue;
    final due = note.reminderAt?.toUtc();
    if (due != null && due.isAfter(nowUtc)) {
      final text = reminderText(note);
      planned.add(
        ScheduledReminder(
          id: reminderNotificationId(note.id),
          noteId: note.id,
          dueUtc: due,
          title: text.title,
          body: text.body,
        ),
      );
    }
    for (final item in note.items) {
      // Checked rows carry no reminder; both the server and the store drop it
      // as the box is ticked, so this only refuses to arm one that is still
      // in flight.
      if (item.done) continue;
      final reminder = note.itemReminders[item.id];
      if (reminder == null) continue;
      final itemDue = reminder.at.toUtc();
      if (!itemDue.isAfter(nowUtc)) continue;
      final text = itemReminderText(note, item.id);
      planned.add(
        ScheduledReminder(
          id: reminderNotificationId(note.id, itemId: item.id),
          noteId: note.id,
          itemId: item.id,
          dueUtc: itemDue,
          title: text.title,
          body: text.body,
        ),
      );
    }
  }
  planned.sort((a, b) => a.dueUtc.compareTo(b.dueUtc));
  if (planned.length > kMaxScheduledReminders) {
    return planned.sublist(0, kMaxScheduledReminders);
  }
  return planned;
}

/// What a reconcile pass has to change to make the OS match [desired].
class ReminderScheduleDiff {
  /// Notification ids to cancel: reminders that were removed, cleared,
  /// trashed, or pushed out of the [kMaxScheduledReminders] window.
  final List<int> cancel;

  /// Reminders to (re)arm. Rescheduling an existing id replaces it, so an
  /// entry here needs no matching [cancel].
  final List<ScheduledReminder> schedule;

  const ReminderScheduleDiff({required this.cancel, required this.schedule});

  bool get isEmpty => cancel.isEmpty && schedule.isEmpty;
}

/// How long a just-fired reminder is left alone before it counts as stale.
///
/// [plannedReminders] drops a reminder the moment it is due, but the OS may not
/// have delivered it yet (Doze can hold one for minutes). Cancelling in that
/// window would suppress a reminder seconds before it lands, so anything
/// recently due is left armed; only reminders long past are cleaned up, so they
/// can't sit forever occupying one of the [kMaxScheduledReminders] slots.
const Duration kFiredReminderGrace = Duration(hours: 6);

/// Diff the OS's actual pending set against what it should be.
///
/// [pending] is the authoritative input, read back from the platform rather
/// than remembered, so an interrupted pass, a reboot, or an alarm the OS
/// dropped all self-heal on the next reconcile. Anything armed that we don't
/// recognize is left alone: this app schedules nothing else today, but silently
/// cancelling a stranger's notification would be a nasty surprise if it ever
/// does.
ReminderScheduleDiff diffReminders({
  required List<ScheduledReminder> desired,
  required List<PendingReminder> pending,
  required DateTime now,
}) {
  final nowUtc = now.toUtc();
  final pendingById = {for (final p in pending) p.id: p};
  final desiredIds = {for (final d in desired) d.id};

  final schedule = <ScheduledReminder>[];
  for (final reminder in desired) {
    final armed = pendingById[reminder.id];
    // The payload pins the due time and the id pins the note, so comparing
    // payload + text catches a moved reminder and an edited note alike.
    final unchanged =
        armed != null &&
        armed.payload == reminder.payload &&
        armed.title == reminder.title &&
        armed.body == reminder.body;
    if (!unchanged) schedule.add(reminder);
  }

  final cancel = <int>[];
  for (final p in pending) {
    if (desiredIds.contains(p.id)) continue;
    // Not ours: leave it be.
    if (ScheduledReminder.noteIdFromPayload(p.payload) == null) continue;
    final due = ScheduledReminder.dueFromPayload(p.payload);
    // Due any moment now: let it fire rather than racing the OS.
    if (due != null &&
        !due.isAfter(nowUtc) &&
        nowUtc.difference(due) < kFiredReminderGrace) {
      continue;
    }
    cancel.add(p.id);
  }

  return ReminderScheduleDiff(cancel: cancel, schedule: schedule);
}
