"use client";

import { createContext, useContext, useState } from "react";
import { useDndContext, useDroppable } from "@dnd-kit/core";
import type { DayButtonProps } from "react-day-picker";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { cn } from "cn";

import { IconButton } from "@/components/common/icon-button";
import { CrossFade } from "@/components/common/reveal";
import { Button } from "@/components/ui/button";
import { Calendar } from "@/components/ui/calendar";
import { dayOf, remindersByDay, type ReminderOccurrence } from "@/lib/state/reminder-agenda";
import { formatDate, useSettings } from "@/lib/store";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";

import { MONTH_NAMES, WEEKDAY_SHORT, addMonths, monthGridRange, monthOf, reminderCountLabel, sameMonth, weekStartsOn } from "./reminder-rules";
import { REMINDER_DRAG_TYPE } from "./reminder-tiles";

// A month of days, each marked with how many reminders fall on it
// (`reminder_calendar.dart`). Arrows change the month; a day shows its
// reminders; with a pointer, a reminder dragged from a list can be dropped on
// a day to move it there, keeping its time.

/** More reminders than this on one day still show this many dots. */
const MAX_DOTS = 3;
const SLIDE_PX = 24;

export const dayDroppableId = (day: Date): string => `day:${day.getTime()}`;

interface CalendarMarks {
  readonly byDay: ReadonlyMap<number, readonly ReminderOccurrence[]>;
  readonly today: number;
  readonly label: (day: Date, count: number) => string;
}

const MarksContext = createContext<CalendarMarks>({ byDay: new Map(), today: 0, label: () => "" });

export function ReminderCalendar({
  scheduled,
  now,
  selectedDay,
  onDaySelected,
}: {
  scheduled: readonly ReminderOccurrence[];
  now: Date;
  selectedDay: Date | null;
  onDaySelected: (day: Date) => void;
}) {
  const reduced = useReducedMotion();
  const dateFormat = useSettings((s) => s.dateFormat);
  const weekStart = weekStartsOn(dateFormat);
  const [month, setMonth] = useState(() => monthOf(selectedDay ?? now));
  const [direction, setDirection] = useState<1 | -1>(1);
  const [followed, setFollowed] = useState<number | null>(selectedDay?.getTime() ?? null);

  const showMonth = (next: Date): void => {
    if (sameMonth(next, month)) {
      return;
    }
    setDirection(next.getTime() > month.getTime() ? 1 : -1);
    setMonth(monthOf(next));
  };

  // Follow a selection made elsewhere (the Today button, a day in the next
  // month's leading row) to its month.
  const selectedMs = selectedDay?.getTime() ?? null;
  if (selectedMs !== followed) {
    setFollowed(selectedMs);
    if (selectedDay && !sameMonth(selectedDay, month)) {
      setDirection(selectedDay.getTime() > month.getTime() ? 1 : -1);
      setMonth(monthOf(selectedDay));
    }
  }

  const today = dayOf(now);
  const showingToday = sameMonth(today, month) && selectedMs === today.getTime();
  const { start, end } = monthGridRange(month, weekStart);
  const marks: CalendarMarks = {
    byDay: remindersByDay(scheduled, start, end),
    today: today.getTime(),
    label: (day, count) => `${formatDate(day, dateFormat)}, ${reminderCountLabel(count)}`,
  };
  const slide = transitionFor(TRANSITION.slow, reduced);

  return (
    <div className="flex flex-col">
      <div className="flex items-center gap-1 pl-2">
        <h3 className="min-w-0 flex-1 text-base font-semibold text-on-surface">
          <CrossFade stateKey={month.getTime()}>
            {MONTH_NAMES[month.getMonth()]} {month.getFullYear()}
          </CrossFade>
        </h3>
        <Button
          variant="ghost"
          size="sm"
          tabIndex={showingToday ? -1 : undefined}
          aria-hidden={showingToday || undefined}
          className={cn("transition-opacity duration-150 ease-standard", showingToday && "pointer-events-none opacity-0")}
          onClick={() => {
            onDaySelected(today);
            showMonth(today);
          }}
        >
          Today
        </Button>
        <IconButton label="Previous month" size="sm" icon={<ChevronLeft />} onClick={() => showMonth(addMonths(month, -1))} />
        <IconButton label="Next month" size="sm" icon={<ChevronRight />} onClick={() => showMonth(addMonths(month, 1))} />
      </div>
      <div className="relative overflow-hidden">
        <AnimatePresence initial={false} mode="popLayout" custom={direction}>
          <motion.div
            key={month.getTime()}
            custom={direction}
            variants={{
              enter: (d: number) => ({ x: d * SLIDE_PX, opacity: 0 }),
              center: { x: 0, opacity: 1 },
              exit: (d: number) => ({ x: -d * SLIDE_PX, opacity: 0 }),
            }}
            initial="enter"
            animate="center"
            exit="exit"
            transition={slide}
          >
            <MarksContext.Provider value={marks}>
              <Calendar
                mode="single"
                month={month}
                onMonthChange={showMonth}
                selected={selectedDay ?? undefined}
                onSelect={(_, day) => onDaySelected(dayOf(day))}
                weekStartsOn={weekStart}
                fixedWeeks
                showOutsideDays
                hideNavigation
                formatters={{ formatWeekdayName: (d) => WEEKDAY_SHORT[d.getDay()] ?? "" }}
                className="w-full p-0 pt-1"
                classNames={{
                  root: "w-full",
                  months: "relative flex flex-col",
                  month: "flex w-full flex-col",
                  month_caption: "hidden",
                  weekdays: "flex",
                  weekday: "flex-1 pb-1 text-center text-2xs font-medium text-on-surface-variant select-none",
                  week: "flex w-full",
                  day: "relative h-12 flex-1 p-0 text-center select-none",
                  today: "",
                  outside: "",
                  selected: "",
                }}
                components={{ DayButton: ReminderDayButton }}
              />
            </MarksContext.Provider>
          </motion.div>
        </AnimatePresence>
      </div>
    </div>
  );
}

function ReminderDayButton({ day, modifiers, ...props }: DayButtonProps) {
  const marks = useContext(MarksContext);
  const date = dayOf(day.date);
  const ms = date.getTime();
  const reminders = marks.byDay.get(ms) ?? [];
  const isToday = ms === marks.today;
  const isPast = ms < marks.today;
  const selected = modifiers.selected === true;
  const outside = modifiers.outside === true;
  const { active } = useDndContext();
  const carried = active?.data.current?.type === REMINDER_DRAG_TYPE ? (active.data.current.occurrence as ReminderOccurrence | undefined) : undefined;
  // A day takes a reminder only when the drop would move it.
  const accepts = carried !== undefined && dayOf(carried.at).getTime() !== ms;
  const { setNodeRef, isOver } = useDroppable({ id: dayDroppableId(date), data: { type: "day", day: date }, disabled: !accepts });
  const label = marks.label(date, reminders.length);

  return (
    <button
      {...props}
      ref={setNodeRef}
      type="button"
      aria-label={label}
      className="group/day flex h-12 w-full flex-col items-center justify-center gap-[3px] rounded-md outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50"
    >
      <span
        className={cn(
          "grid size-8 place-items-center rounded-md text-sm tabular-nums transition-[background-color,box-shadow,color] duration-150 ease-standard group-hover/day:bg-hover",
          selected
            ? "bg-primary-container font-semibold text-on-primary-container group-hover/day:bg-primary-container"
            : isOver && accepts
              ? "bg-primary-container/40"
              : isToday
                ? "font-semibold text-primary ring-[1.5px] ring-primary ring-inset"
                : outside
                  ? "text-on-surface-variant/50"
                  : "text-on-surface",
        )}
      >
        {date.getDate()}
      </span>
      <span aria-hidden className="flex h-[5px] items-center gap-0.5">
        {reminders.slice(0, MAX_DOTS).map((r, i) => (
          <span key={i} className={cn("size-[5px] rounded-[1px]", isPast ? "bg-on-surface-variant/50" : "bg-primary")} data-key={r.note.id} />
        ))}
      </span>
    </button>
  );
}
