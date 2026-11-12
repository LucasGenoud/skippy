"use client";

import { useEffect, useState, type ReactNode } from "react";
import { DndContext, DragOverlay, MouseSensor, useSensor, useSensors, type DragEndEvent, type DragStartEvent } from "@dnd-kit/core";
import { Bell, CalendarDays, ChevronDown, ListTodo, SearchX, X } from "lucide-react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";

import { EmptyState } from "@/components/common/empty-state";
import { PageHeader } from "@/components/common/page-header";
import { Reveal } from "@/components/common/reveal";
import { Button } from "@/components/ui/button";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { IconButton } from "@/components/common/icon-button";
import { swallowNextClick } from "@/features/board/swallow-click";
import { useElementWidth, useMediaQuery, useMinWidth } from "@/features/board/use-viewport";
import { agendaFor, dayOf, occurrenceKey, occurrencesBetween, type ReminderOccurrence } from "@/lib/state/reminder-agenda";
import { formatDate, useEffectiveQuery, useNotesController, useReminderOccurrences, useSettings } from "@/lib/store";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";

import { ReminderCalendar } from "./reminder-calendar";
import { clearReminders, moveReminderToDay } from "./reminder-editing";
import { dayHeading, remindersSummary } from "./reminder-rules";
import { REMINDER_DRAG_TYPE, ReminderDragPreview, ReminderGroup, ReminderGroupHeader, ReminderTile } from "./reminder-tiles";

// The Reminders destination: every timed reminder in the open workspace, as a
// day-by-day agenda and a month calendar (`reminders_view.dart`). No place
// reminders on the web.
//
//   wide                               narrow
//   +-----------+------------------+   +---------------------+
//   | calendar  | Today            |   | [Agenda | Calendar] |
//   |           |   09:00 ...      |   | Today               |
//   |           | Tomorrow         |   |   09:00 ...         |
//   +-----------+------------------+   +---------------------+
//
// Picking a day on a wide calendar narrows the agenda to it; on a phone the
// calendar tab lists the picked day under the month.

/** Below this the calendar and the agenda take turns. */
const TWO_PANE_MIN_WIDTH = 840;
const CALENDAR_PANE_WIDTH = 360;
/** Where the top bar names the view itself (`HomeTopBar.showsTitle`). */
const TOP_BAR_TITLE_MIN_WIDTH = 650;
const CLOCK_TICK_MS = 60_000;
const MOUSE_DISTANCE_PX = 6;

type Mode = "agenda" | "calendar";

/** Now, refreshed every minute, so "past" styling and Today stay honest while the view sits open. */
function useNow(): Date {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    const timer = window.setInterval(() => setNow(new Date()), CLOCK_TICK_MS);
    return () => window.clearInterval(timer);
  }, []);
  return now;
}

export function RemindersView() {
  const notes = useNotesController();
  const scheduled = useReminderOccurrences();
  const now = useNow();
  const query = useEffectiveQuery();
  const dateFormat = useSettings((s) => s.dateFormat);
  const [rootRef, width] = useElementWidth<HTMLDivElement>();
  const twoPanes = width >= TWO_PANE_MIN_WIDTH;
  const showTitle = !useMinWidth(TOP_BAR_TITLE_MIN_WIDTH);
  // Carrying a reminder to a day is a pointer gesture, as in Flutter.
  const pointer = useMediaQuery("(hover: hover) and (pointer: fine)");
  const [mode, setMode] = useState<Mode>("agenda");
  const [selectedDay, setSelectedDay] = useState<Date | null>(null);
  const [carried, setCarried] = useState<ReminderOccurrence | null>(null);
  const sensors = useSensors(useSensor(MouseSensor, { activationConstraint: { distance: MOUSE_DISTANCE_PX } }));
  const summary = remindersSummary(scheduled, now);
  const searching = query.trim() !== "";

  const onDragStart = ({ active }: DragStartEvent): void => {
    const occurrence = active.data.current?.occurrence as ReminderOccurrence | undefined;
    setCarried(active.data.current?.type === REMINDER_DRAG_TYPE && occurrence ? occurrence : null);
  };
  const onDragEnd = ({ over }: DragEndEvent): void => {
    const day = over?.data.current?.day as Date | undefined;
    if (carried && day && dayOf(carried.at).getTime() !== day.getTime()) {
      moveReminderToDay(notes, carried, day, formatDate(day, dateFormat, day.getFullYear() !== now.getFullYear()));
    }
    setCarried(null);
    swallowNextClick();
  };

  const header = (trailing?: ReactNode) => <PageHeader title={showTitle ? "Reminders" : undefined} subtitle={summary} trailing={trailing} />;
  const toggleDay = (day: Date): void => setSelectedDay((current) => (current?.getTime() === day.getTime() ? null : day));

  let body: ReactNode;
  if (twoPanes) {
    body = (
      <div className="flex h-full min-h-0 flex-col px-8">
        {header()}
        <div className="flex min-h-0 flex-1 gap-6">
          <div className="shrink-0 overflow-y-auto pt-2 pb-4" style={{ width: CALENDAR_PANE_WIDTH }}>
            <CalendarCard>
              <ReminderCalendar scheduled={scheduled} now={now} selectedDay={selectedDay} onDaySelected={toggleDay} />
            </CalendarCard>
          </div>
          <Fade stateKey={selectedDay ? `day:${selectedDay.getTime()}` : "agenda"}>
            {selectedDay ? (
              <ScrollingList panes="two">
                <DaySection day={selectedDay} now={now} scheduled={scheduled} draggable={pointer} onClose={() => setSelectedDay(null)} />
              </ScrollingList>
            ) : (
              <Agenda scheduled={scheduled} now={now} searching={searching} panes="two" draggable={pointer} />
            )}
          </Fade>
        </div>
      </div>
    );
  } else {
    const tabs = (
      <Tabs value={mode} onValueChange={(value) => setMode(value as Mode)}>
        <TabsList aria-label="Reminders view">
          <ModeTab value="agenda" label="Agenda" icon={<ListTodo />} />
          <ModeTab value="calendar" label="Calendar" icon={<CalendarDays />} />
        </TabsList>
      </Tabs>
    );
    const day = selectedDay ?? dayOf(now);
    body = (
      <div className="flex h-full min-h-0 flex-col">
        <div className="px-4">{header(tabs)}</div>
        <Fade stateKey={mode}>
          {mode === "agenda" ? (
            <Agenda scheduled={scheduled} now={now} searching={searching} panes="one" draggable={pointer} />
          ) : (
            <ScrollingList panes="one">
              <div className="pt-2">
                <CalendarCard>
                  <ReminderCalendar scheduled={scheduled} now={now} selectedDay={day} onDaySelected={setSelectedDay} />
                </CalendarCard>
              </div>
              <DaySection day={day} now={now} scheduled={scheduled} draggable={pointer} />
            </ScrollingList>
          )}
        </Fade>
      </div>
    );
  }

  return (
    <div ref={rootRef} className="h-full min-h-0">
      <DndContext sensors={sensors} onDragStart={onDragStart} onDragEnd={onDragEnd} onDragCancel={() => setCarried(null)}>
        {body}
        <DragOverlay dropAnimation={null}>{carried ? <ReminderDragPreview reminder={carried} /> : null}</DragOverlay>
      </DndContext>
    </div>
  );
}

function ModeTab({ value, label, icon }: { value: Mode; label: string; icon: ReactNode }) {
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <TabsTrigger value={value} aria-label={label} className="px-2">
          {icon}
        </TabsTrigger>
      </TooltipTrigger>
      <TooltipContent>{label}</TooltipContent>
    </Tooltip>
  );
}

/** The surface the month sits on. */
function CalendarCard({ children }: { children: ReactNode }) {
  return <div className="rounded-md border border-hairline bg-surface p-2 shadow-card">{children}</div>;
}

/** Cross-fades the view's panes (agenda, a picked day, the month) in one slot. */
function Fade({ stateKey, children }: { stateKey: string; children: ReactNode }) {
  const reduced = useReducedMotion();
  const transition = transitionFor(TRANSITION.base, reduced);
  return (
    <div className="relative min-h-0 min-w-0 flex-1">
      <AnimatePresence initial={false}>
        <motion.div key={stateKey} className="absolute inset-0" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={transition}>
          {children}
        </motion.div>
      </AnimatePresence>
    </div>
  );
}

/** A scrolling column capped to a readable width: centred in one pane, against the calendar in two. */
function ScrollingList({ panes, children }: { panes: "one" | "two"; children: ReactNode }) {
  return (
    <div className={panes === "one" ? "h-full overflow-y-auto px-4 pb-24" : "h-full overflow-y-auto pb-24"}>
      <div className={panes === "one" ? "mx-auto flex max-w-[720px] flex-col" : "flex max-w-[720px] flex-col"}>{children}</div>
    </div>
  );
}

/** A section that folds in and out rather than popping (a day's last reminder done). */
function Section({ children }: { children: ReactNode }) {
  const reduced = useReducedMotion();
  return (
    <motion.section
      initial={{ height: 0, opacity: 0 }}
      animate={{ height: "auto", opacity: 1 }}
      exit={{ height: 0, opacity: 0 }}
      transition={transitionFor(TRANSITION.base, reduced)}
      className="overflow-hidden"
    >
      {children}
    </motion.section>
  );
}

function DayHeader({ day, now, count, trailing }: { day: Date; now: Date; count?: number | null; trailing?: ReactNode }) {
  const dateFormat = useSettings((s) => s.dateFormat);
  const heading = dayHeading(day, now, (d, withYear) => formatDate(d, dateFormat, withYear));
  return <ReminderGroupHeader title={heading.title} subtitle={heading.subtitle} count={count} highlighted={heading.isToday} trailing={trailing} />;
}

/** Every reminder from today on, one group per day, after a folded group of earlier ones. */
function Agenda({ scheduled, now, searching, panes, draggable }: { scheduled: readonly ReminderOccurrence[]; now: Date; searching: boolean; panes: "one" | "two"; draggable: boolean }) {
  const notes = useNotesController();
  const reduced = useReducedMotion();
  const [showEarlier, setShowEarlier] = useState(false);
  const { earlier, days } = agendaFor(scheduled, now);

  if (earlier.length === 0 && days.length === 0) {
    return searching ? <EmptyState icon={SearchX} message="No matching reminders" /> : <EmptyState icon={Bell} message="Notes with reminders appear here" />;
  }

  return (
    <ScrollingList panes={panes}>
      <AnimatePresence initial={false}>
        {earlier.length > 0 ? (
          <Section key="earlier">
            <ReminderGroupHeader
              title="Earlier"
              count={showEarlier ? null : earlier.length}
              trailing={
                <>
                  <AnimatePresence initial={false}>
                    {showEarlier ? (
                      <motion.span key="clear" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={transitionFor(TRANSITION.fast, reduced)}>
                        <Button variant="ghost" size="sm" onClick={() => clearReminders(notes, earlier)}>
                          Clear all
                        </Button>
                      </motion.span>
                    ) : null}
                  </AnimatePresence>
                  <IconButton
                    label={showEarlier ? "Hide earlier" : "Show earlier"}
                    size="sm"
                    aria-expanded={showEarlier}
                    onClick={() => setShowEarlier((v) => !v)}
                    icon={<ChevronDown className={`transition-transform duration-240 ease-emphasized ${showEarlier ? "rotate-180" : ""}`} />}
                  />
                </>
              }
            />
            <Reveal>
              {showEarlier ? (
                <ReminderGroup>
                  {earlier.map((reminder) => (
                    <ReminderTile key={occurrenceKey(reminder)} reminder={reminder} now={now} timeStyle="dayAndClock" draggable={draggable} />
                  ))}
                </ReminderGroup>
              ) : null}
            </Reveal>
          </Section>
        ) : null}
        {days.map((day) => (
          <Section key={day.day.getTime()}>
            <DayHeader day={day.day} now={now} count={day.reminders.length} />
            <ReminderGroup>
              {day.reminders.map((reminder) => (
                <ReminderTile key={occurrenceKey(reminder)} reminder={reminder} now={now} draggable={draggable} />
              ))}
            </ReminderGroup>
          </Section>
        ))}
      </AnimatePresence>
    </ScrollingList>
  );
}

/** The reminders on one picked day, forecast repeats included. */
function DaySection({ day, now, scheduled, draggable, onClose }: { day: Date; now: Date; scheduled: readonly ReminderOccurrence[]; draggable: boolean; onClose?: () => void }) {
  const reminders = occurrencesBetween(scheduled, day, new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1));
  return (
    <section>
      <DayHeader
        day={day}
        now={now}
        count={onClose ? null : reminders.length}
        trailing={
          onClose ? (
            <Button variant="ghost" size="sm" onClick={onClose}>
              <X />
              All reminders
            </Button>
          ) : null
        }
      />
      {reminders.length === 0 ? (
        <p className="p-4 text-center text-sm text-on-surface-variant">No reminders on this day</p>
      ) : (
        <ReminderGroup>
          {reminders.map((reminder) => (
            <ReminderTile key={occurrenceKey(reminder)} reminder={reminder} now={now} draggable={draggable} />
          ))}
        </ReminderGroup>
      )}
    </section>
  );
}
