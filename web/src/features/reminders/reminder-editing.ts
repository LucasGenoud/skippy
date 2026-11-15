import { BellOff, CalendarDays, CircleCheck } from "lucide-react";

import { showAppSnack } from "@/components/common/snack";
import { movedToDay, occurrenceTitle, type ReminderOccurrence } from "@/lib/state/reminder-agenda";
import type { NotesStore } from "@/lib/store";

import { clearedLabel } from "./reminder-rules";

// What a reminder row can do to its reminder (`reminder_editing.dart`). The
// same calls serve a note's own reminder and a checklist row's.

/** Moves [reminder] to [at] keeping its cadence, or removes it when [at] is null. */
export function rescheduleReminder(notes: NotesStore, reminder: ReminderOccurrence, at: Date | null): void {
  const item = reminder.item;
  if (item === null) {
    notes.setReminder(reminder.note.id, at, reminder.repeat);
    return;
  }
  notes.setItemReminder(reminder.note.id, item.id, at, reminder.repeat);
}

/** Removes [reminder], offering to put it back. */
export function removeReminder(notes: NotesStore, reminder: ReminderOccurrence): void {
  rescheduleReminder(notes, reminder, null);
  showAppSnack("Reminder removed", { icon: BellOff, undo: () => rescheduleReminder(notes, reminder, reminder.at) });
}

/** Ticks off the row [reminder] belongs to. The server drops a checked row's reminder, so undo restores both. */
export function completeReminderItem(notes: NotesStore, reminder: ReminderOccurrence): void {
  const item = reminder.item;
  if (item === null) {
    return;
  }
  notes.setChecklistItemDone(reminder.note.id, item.id, true);
  showAppSnack(`Checked off “${occurrenceTitle(reminder)}”`, {
    icon: CircleCheck,
    undo: () => {
      notes.setChecklistItemDone(reminder.note.id, item.id, false);
      rescheduleReminder(notes, reminder, reminder.at);
    },
  });
}

/** Carries [reminder] onto [day], keeping its time of day. */
export function moveReminderToDay(notes: NotesStore, reminder: ReminderOccurrence, day: Date, dayLabel: string): void {
  rescheduleReminder(notes, reminder, movedToDay(reminder.at, day));
  showAppSnack(`Moved to ${dayLabel}`, { icon: CalendarDays, undo: () => rescheduleReminder(notes, reminder, reminder.at) });
}

/** Clears every reminder in [earlier], offering to put them all back. */
export function clearReminders(notes: NotesStore, earlier: readonly ReminderOccurrence[]): void {
  for (const reminder of earlier) {
    rescheduleReminder(notes, reminder, null);
  }
  showAppSnack(clearedLabel(earlier.length), {
    icon: BellOff,
    undo: () => {
      for (const reminder of earlier) {
        rescheduleReminder(notes, reminder, reminder.at);
      }
    },
  });
}
