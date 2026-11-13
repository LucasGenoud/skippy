import { CalendarDays } from "lucide-react"
import { cn } from "cn"

import { formatWhen, REPEAT_LABELS, type ReminderRepeat } from "./reminder-format"

/**
 * The "when" pill for a reminder, shared by the card (a note's reminder) and
 * the checklist editor (one row's). A reminder in the past keeps its place,
 * struck through: it is history, not an error. With `onClick` it is a button.
 */
export function ReminderChip({
  at,
  repeat,
  label,
  now,
  onClick,
  className,
}: {
  at: Date
  repeat?: ReminderRepeat | null
  /** Overrides the formatted date (the settings' own date format). */
  label?: string
  /** "Now", for deciding whether it has passed. Defaults to the clock. */
  now?: Date
  onClick?: () => void
  className?: string
}) {
  const past = at.getTime() < (now ?? new Date()).getTime()
  const when = label ?? formatWhen(at, { now })
  const text = repeat ? `${when} · ${REPEAT_LABELS[repeat]}` : when
  const classes = cn(
    "inline-flex h-6 max-w-full min-w-0 items-center gap-1 rounded-md bg-on-surface/8 px-2 text-2xs font-medium text-on-surface-variant",
    onClick &&
      "transition-colors duration-150 ease-standard outline-none hover:bg-on-surface/12 active:bg-on-surface/16 focus-visible:ring-[3px] focus-visible:ring-ring/50",
    className,
  )
  const content = (
    <>
      <CalendarDays aria-hidden className="size-[13px] shrink-0" />
      <span className={cn("truncate", past && "line-through")}>{text}</span>
    </>
  )
  if (!onClick) {
    return <span className={classes}>{content}</span>
  }
  return (
    <button type="button" className={classes} onClick={onClick}>
      {content}
    </button>
  )
}
