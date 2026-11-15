import { dayOf, type ReminderOccurrence } from "@/lib/state/reminder-agenda";
import type { AppDateFormat } from "@/lib/store";

// Wording and calendar arithmetic of the Reminders view, kept pure so the
// rules are testable without rendering (`reminders_view.dart`,
// `reminder_calendar.dart`).

const DAYS_PER_WEEK = 7;
const MS_PER_DAY = 86_400_000;
/** A month is always drawn as six weeks, so paging never changes its height. */
export const WEEKS_SHOWN = 6;

export const WEEKDAY_NAMES = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"] as const;
export const WEEKDAY_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;
export const MONTH_NAMES = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"] as const;

/** "2 later today · 5 upcoming", or "Nothing coming up". */
export function remindersSummary(scheduled: readonly ReminderOccurrence[], now: Date): string {
  const today = dayOf(now).getTime();
  const upcoming = scheduled.filter((r) => r.at.getTime() > now.getTime());
  const laterToday = upcoming.filter((r) => dayOf(r.at).getTime() === today).length;
  const parts: string[] = [];
  if (laterToday > 0) {
    parts.push(`${laterToday} later today`);
  }
  if (upcoming.length > 0) {
    parts.push(`${upcoming.length} upcoming`);
  }
  return parts.length === 0 ? "Nothing coming up" : parts.join(" · ");
}

/** Whole calendar days from [from] to [to], so a daylight-saving night still counts as one. */
export function daysBetween(from: Date, to: Date): number {
  const a = Date.UTC(from.getFullYear(), from.getMonth(), from.getDate());
  const b = Date.UTC(to.getFullYear(), to.getMonth(), to.getDate());
  return Math.round((b - a) / MS_PER_DAY);
}

export interface DayHeading {
  readonly title: string;
  readonly subtitle: string;
  /** The one group that is "now", drawn in the accent. */
  readonly isToday: boolean;
}

/**
 * A day group's title line: "Today  Wednesday, 7 Oct", "Friday  9 Oct",
 * "14 Nov  Saturday". [formatDate] renders the date in the user's format.
 */
export function dayHeading(day: Date, now: Date, formatDate: (day: Date, withYear: boolean) => string): DayHeading {
  const date = formatDate(day, day.getFullYear() !== now.getFullYear());
  const weekday = WEEKDAY_NAMES[day.getDay()] ?? "";
  const offset = daysBetween(now, day);
  let relative: string | null = null;
  if (offset === -1) {
    relative = "Yesterday";
  } else if (offset === 0) {
    relative = "Today";
  } else if (offset === 1) {
    relative = "Tomorrow";
  } else if (offset > 1 && offset < DAYS_PER_WEEK) {
    relative = weekday;
  }
  if (relative === null) {
    return { title: date, subtitle: weekday, isToday: false };
  }
  return { title: relative, subtitle: relative === weekday ? date : `${weekday}, ${date}`, isToday: offset === 0 };
}

/** Countries that write the month first also start the week on Sunday. */
export function weekStartsOn(format: AppDateFormat): 0 | 1 {
  return format === "monthFirst" || format === "numericUS" ? 0 : 1;
}

export const monthOf = (t: Date): Date => new Date(t.getFullYear(), t.getMonth(), 1);
export const addMonths = (month: Date, n: number): Date => new Date(month.getFullYear(), month.getMonth() + n, 1);
export const sameMonth = (a: Date, b: Date): boolean => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth();

/** The first and one-past-last day a month grid draws: the tail of the month before through the head of the next. */
export function monthGridRange(month: Date, weekStart: 0 | 1): { start: Date; end: Date } {
  const first = monthOf(month);
  const lead = (first.getDay() - weekStart + DAYS_PER_WEEK) % DAYS_PER_WEEK;
  const start = new Date(first.getFullYear(), first.getMonth(), 1 - lead);
  const end = new Date(start.getFullYear(), start.getMonth(), start.getDate() + WEEKS_SHOWN * DAYS_PER_WEEK);
  return { start, end };
}

/** "no reminders", "1 reminder", "3 reminders". */
export function reminderCountLabel(count: number): string {
  if (count === 0) {
    return "no reminders";
  }
  return count === 1 ? "1 reminder" : `${count} reminders`;
}

/** "Cleared 1 past reminder" / "Cleared 3 past reminders". */
export function clearedLabel(count: number): string {
  return count === 1 ? "Cleared 1 past reminder" : `Cleared ${count} past reminders`;
}
