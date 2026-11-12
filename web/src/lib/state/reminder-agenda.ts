import type { ChecklistItem, Note, ReminderRepeat } from "@/lib/models/note";
import { noteDisplayTitle } from "./display-title";

// Pure rules behind the Reminders view: which reminders exist, when they fall,
// and how they group into days. Ported from `state/reminder_agenda.dart`.
// Place reminders are out of scope on the web, as in the Flutter web build.

const DAYS_PER_WEEK = 7;
const MONTHS_PER_YEAR = 12;
const MS_PER_DAY = 24 * 60 * 60 * 1000;

/** Calendar day of [t], as local midnight. */
export function dayOf(t: Date): Date {
  return new Date(t.getFullYear(), t.getMonth(), t.getDate());
}

/** One time a reminder goes off: a note's own, or one checklist row's. */
export interface ReminderOccurrence {
  readonly note: Note;
  /** The row this reminder belongs to, or null for the note's own. */
  readonly item: ChecklistItem | null;
  readonly at: Date;
  readonly repeat: ReminderRepeat | null;
  /** A later turn of a repeating reminder; only a forecast. */
  readonly projected: boolean;
}

/** Unique per occurrence: `noteId`, `noteId#itemId`, plus the time for projected turns. */
export function occurrenceKey(o: ReminderOccurrence): string {
  const base = o.item === null ? o.note.id : `${o.note.id}#${o.item.id}`;
  return o.projected ? `${base}@${o.at.getTime()}` : base;
}

/** The item's own text, or the note's title. */
export function occurrenceTitle(o: ReminderOccurrence): string {
  const text = o.item?.text.trim();
  if (text) {
    return text;
  }
  return noteDisplayTitle(o.note);
}

function bySoonest(a: ReminderOccurrence, b: ReminderOccurrence): number {
  const byTime = a.at.getTime() - b.at.getTime();
  if (byTime !== 0) {
    return byTime;
  }
  const ta = occurrenceTitle(a).toLowerCase();
  const tb = occurrenceTitle(b).toLowerCase();
  return ta < tb ? -1 : ta > tb ? 1 : 0;
}

/** Every stored reminder on [notes], soonest first (trash and checked rows skipped). */
export function scheduledReminders(notes: Iterable<Note>): ReminderOccurrence[] {
  const scheduled: ReminderOccurrence[] = [];
  for (const note of notes) {
    if (note.trashed) {
      continue;
    }
    if (note.reminderAt) {
      scheduled.push({ note, item: null, at: note.reminderAt, repeat: note.reminderRepeat, projected: false });
    }
    for (const item of note.items) {
      const reminder = note.itemReminders[item.id];
      if (!reminder || item.done) {
        continue;
      }
      scheduled.push({ note, item, at: reminder.at, repeat: reminder.repeat, projected: false });
    }
  }
  return scheduled.sort(bySoonest);
}

/** The [n]th turn of a reminder first due at [first]. Months clamp to their last day. */
function nthRepeat(first: Date, repeat: ReminderRepeat, n: number): Date {
  const addMonths = (months: number): Date => {
    const month = first.getMonth() + months;
    const year = first.getFullYear() + Math.floor(month / MONTHS_PER_YEAR);
    const monthOfYear = ((month % MONTHS_PER_YEAR) + MONTHS_PER_YEAR) % MONTHS_PER_YEAR;
    const lastDay = new Date(year, monthOfYear + 1, 0).getDate();
    return new Date(year, monthOfYear, Math.min(first.getDate(), lastDay), first.getHours(), first.getMinutes());
  };
  const addDays = (days: number): Date =>
    new Date(first.getFullYear(), first.getMonth(), first.getDate() + days, first.getHours(), first.getMinutes());
  switch (repeat) {
    case "daily":
      return addDays(n);
    case "weekly":
      return addDays(n * DAYS_PER_WEEK);
    case "monthly":
      return addMonths(n);
    case "yearly":
      return addMonths(n * MONTHS_PER_YEAR);
  }
}

/** Rough count of turns before [from], so projecting far ahead does not walk every day. */
function turnsBefore(first: Date, repeat: ReminderRepeat, from: Date): number {
  const days = Math.trunc((from.getTime() - first.getTime()) / MS_PER_DAY);
  let turns: number;
  switch (repeat) {
    case "daily":
      turns = days;
      break;
    case "weekly":
      turns = Math.trunc(days / DAYS_PER_WEEK);
      break;
    case "monthly":
      turns = (from.getFullYear() - first.getFullYear()) * MONTHS_PER_YEAR + from.getMonth() - first.getMonth();
      break;
    case "yearly":
      turns = from.getFullYear() - first.getFullYear();
      break;
  }
  // One turn of slack: the estimate may overshoot by a partial period.
  return turns > 1 ? turns - 1 : 0;
}

/** Every occurrence in `[from, to)`, repeats included, soonest first. */
export function occurrencesBetween(scheduled: Iterable<ReminderOccurrence>, from: Date, to: Date): ReminderOccurrence[] {
  const found: ReminderOccurrence[] = [];
  const fromMs = from.getTime();
  const toMs = to.getTime();
  for (const reminder of scheduled) {
    const repeat = reminder.repeat;
    if (repeat === null) {
      const at = reminder.at.getTime();
      if (at >= fromMs && at < toMs) {
        found.push(reminder);
      }
      continue;
    }
    // Turn 0 is the stored occurrence; earlier ones have already fired.
    for (let n = turnsBefore(reminder.at, repeat, from); ; n++) {
      const when = nthRepeat(reminder.at, repeat, n);
      if (when.getTime() >= toMs) {
        break;
      }
      if (when.getTime() < fromMs) {
        continue;
      }
      found.push(n === 0 ? reminder : { ...reminder, at: when, projected: true });
    }
  }
  return found.sort(bySoonest);
}

/** Reminders per day in `[from, to)`, keyed by local-midnight epoch ms. */
export function remindersByDay(scheduled: Iterable<ReminderOccurrence>, from: Date, to: Date): Map<number, ReminderOccurrence[]> {
  const days = new Map<number, ReminderOccurrence[]>();
  for (const occurrence of occurrencesBetween(scheduled, from, to)) {
    const key = dayOf(occurrence.at).getTime();
    const list = days.get(key) ?? [];
    list.push(occurrence);
    days.set(key, list);
  }
  return days;
}

export interface AgendaDay {
  readonly day: Date;
  readonly reminders: ReminderOccurrence[];
}

/** Stored reminders from before today, then one group per day. */
export function agendaFor(scheduled: readonly ReminderOccurrence[], now: Date): { earlier: ReminderOccurrence[]; days: AgendaDay[] } {
  const today = dayOf(now).getTime();
  const earlier: ReminderOccurrence[] = [];
  const days: AgendaDay[] = [];
  for (const reminder of scheduled) {
    const day = dayOf(reminder.at);
    if (day.getTime() < today) {
      earlier.push(reminder);
      continue;
    }
    const last = days[days.length - 1];
    if (!last || last.day.getTime() !== day.getTime()) {
      days.push({ day, reminders: [reminder] });
    } else {
      last.reminders.push(reminder);
    }
  }
  return { earlier, days };
}

/** When "morning" is for day-moving snoozes. */
const MORNING_HOUR = 9;

export const REMINDER_SNOOZES = [
  { id: "hour", label: "In 1 hour" },
  { id: "tomorrow", label: "Tomorrow morning" },
  { id: "nextWeek", label: "Next week" },
] as const;
export type ReminderSnooze = (typeof REMINDER_SNOOZES)[number]["id"];

/** When a snooze lands, measured from now so a late reminder never lands in the past. */
export function snoozeAfter(snooze: ReminderSnooze, now: Date): Date {
  switch (snooze) {
    case "hour":
      return new Date(now.getFullYear(), now.getMonth(), now.getDate(), now.getHours() + 1, now.getMinutes());
    case "tomorrow":
      return new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1, MORNING_HOUR);
    case "nextWeek":
      return new Date(now.getFullYear(), now.getMonth(), now.getDate() + DAYS_PER_WEEK, MORNING_HOUR);
  }
}

/** [at] moved onto [day], keeping its time of day. */
export function movedToDay(at: Date, day: Date): Date {
  return new Date(day.getFullYear(), day.getMonth(), day.getDate(), at.getHours(), at.getMinutes());
}
