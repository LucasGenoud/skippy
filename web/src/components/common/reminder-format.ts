// Reminder wording shared by the chip and the picker.

export type ReminderRepeat = "daily" | "weekly" | "monthly" | "yearly"

/** What the picker hands back; null removes the reminder. */
export interface ReminderValue {
  at: Date
  repeat?: ReminderRepeat
}

export const REPEAT_LABELS: Readonly<Record<ReminderRepeat, string>> = {
  daily: "Every day",
  weekly: "Every week",
  monthly: "Every month",
  yearly: "Every year",
}

export interface ReminderPreset {
  id: string
  label: string
  at: Date
}

const MORNING = 9
const NOON = 12
const EVENING = 18
const DAYS_PER_WEEK = 7
const MONDAY = 1

/** The quick choices (`reminderPresets`), computed from `now`. */
export function reminderPresets(now: Date): ReminderPreset[] {
  const day = (offset: number, hour: number, minute = 0): Date =>
    new Date(now.getFullYear(), now.getMonth(), now.getDate() + offset, hour, minute)
  const untilMonday = (MONDAY - now.getDay() + DAYS_PER_WEEK) % DAYS_PER_WEEK || DAYS_PER_WEEK
  return [
    { id: "tomorrow-morning", label: "Tomorrow morning", at: day(1, MORNING) },
    { id: "tomorrow-noon", label: "Tomorrow at noon", at: day(1, NOON) },
    { id: "tomorrow-evening", label: "Tomorrow evening", at: day(1, EVENING) },
    { id: "next-week", label: "Next week", at: day(untilMonday, MORNING) },
    { id: "in-seven-days", label: "In 7 days", at: day(DAYS_PER_WEEK, now.getHours(), now.getMinutes()) },
  ]
}

/** "Nov 12, 9:00 AM"; the year only when it is not this one. */
export function formatWhen(at: Date, { now, use24h }: { now?: Date; use24h?: boolean } = {}): string {
  const sameYear = at.getFullYear() === (now ?? new Date()).getFullYear()
  const date = at.toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    year: sameYear ? undefined : "numeric",
  })
  return `${date}, ${formatClock(at, use24h)}`
}

/** "9:00 AM" or "09:00". */
export function formatClock(at: Date, use24h?: boolean): string {
  return at.toLocaleTimeString(undefined, {
    hour: use24h ? "2-digit" : "numeric",
    minute: "2-digit",
    hour12: use24h === undefined ? undefined : !use24h,
  })
}
