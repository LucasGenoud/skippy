"use client";

import { useState, type ReactNode } from "react";
import { useDraggable } from "@dnd-kit/core";
import { AlarmClock, Archive, BellOff, CalendarClock, Clock, EllipsisVertical, ListTodo, Repeat } from "lucide-react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { cn } from "cn";

import { IconButton } from "@/components/common/icon-button";
import { MenuLabel } from "@/components/common/menu-label";
import { ReminderPicker, type ReminderValue } from "@/components/common/reminder-picker";
import { REPEAT_LABELS } from "@/components/common/reminder-format";
import { Checkbox } from "@/components/ui/checkbox";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuSeparator, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { useBrightness } from "@/features/board/use-viewport";
import { navigate } from "@/lib/router";
import { noteDisplayTitle } from "@/lib/state/display-title";
import { REMINDER_SNOOZES, occurrenceKey, occurrenceTitle, snoozeAfter, type ReminderOccurrence } from "@/lib/state/reminder-agenda";
import { formatClock, reminderLabel, resolveNoteColor, useNote, useNotesController, useSettings } from "@/lib/store";
import { DURATION, TRANSITION, transitionFor } from "@/lib/theme/motion";

import { completeReminderItem, removeReminder, rescheduleReminder } from "./reminder-editing";

// The rows of the Reminders view (`reminder_tiles.dart`):
//
//   [leading]  Title that may wrap                    09:00  [...]
//              (icon) meta   (icon) meta
//
// A checklist row's reminder is ticked off right here; a note's opens the
// note. With a pointer, a stored reminder can be carried onto a calendar day.

/** How a row writes its time: under a day header "09:00", elsewhere "Yesterday 09:00". */
export type ReminderTimeStyle = "clock" | "dayAndClock";

export const REMINDER_DRAG_TYPE = "reminder";

/** A rounded surface holding a run of rows; rows that leave fold away. */
export function ReminderGroup({ children }: { children: ReactNode }) {
  return (
    <div className="overflow-hidden rounded-md border border-hairline bg-surface shadow-card">
      <AnimatePresence initial={false}>{children}</AnimatePresence>
    </div>
  );
}

/** A group's title line: "Today  Wednesday, 7 Oct ........ 3". */
export function ReminderGroupHeader({
  title,
  subtitle,
  count,
  highlighted = false,
  trailing,
}: {
  title: string;
  subtitle?: string;
  count?: number | null;
  highlighted?: boolean;
  trailing?: ReactNode;
}) {
  return (
    <div className="flex min-h-9 items-baseline gap-2 px-2 pt-4 pb-2">
      <h3 className={cn("text-sm font-semibold", highlighted ? "text-primary" : "text-on-surface")}>{title}</h3>
      <span className="min-w-0 flex-1 truncate text-xs text-on-surface-variant">{subtitle}</span>
      {count !== null && count !== undefined ? <span className="text-xs text-on-surface-variant tabular-nums">{count}</span> : null}
      {trailing ? <span className="flex items-center self-center">{trailing}</span> : null}
    </div>
  );
}

function Meta({ icon: Icon, children }: { icon: typeof Clock; children: ReactNode }) {
  return (
    <span className="inline-flex min-w-0 items-center gap-1 text-xs text-on-surface-variant">
      <Icon className="size-3.5 shrink-0" />
      <span className="truncate">{children}</span>
    </span>
  );
}

/** A square in the note's own colour, so a row is recognisable as the card it came from. */
function NoteBadge({ noteId }: { noteId: string }) {
  const note = useNote(noteId);
  const brightness = useBrightness();
  const fill = useSettings((s) => (note ? resolveNoteColor(s, note.color, brightness) : null));
  return (
    <span className="grid size-8 place-items-center rounded-md border border-hairline bg-surface-container-highest text-on-surface-variant" style={fill ? { background: fill } : undefined}>
      <AlarmClock className="size-4" />
    </span>
  );
}

/** The box a checklist row's reminder is ticked off with; the tick lands before the row leaves. */
function CompleteBox({ reminder }: { reminder: ReminderOccurrence }) {
  const notes = useNotesController();
  const reduced = useReducedMotion();
  const [checked, setChecked] = useState(false);
  const enabled = !reminder.projected;
  return (
    <Checkbox
      aria-label="Mark done"
      checked={checked}
      disabled={!enabled}
      className="relative z-[1] size-5"
      onClick={(event) => event.stopPropagation()}
      onCheckedChange={(value) => {
        if (value !== true || checked) {
          return;
        }
        setChecked(true);
        window.setTimeout(() => completeReminderItem(notes, reminder), reduced ? 0 : DURATION.base);
      }}
    />
  );
}

export function ReminderTile({ reminder, now, timeStyle = "clock", draggable }: { reminder: ReminderOccurrence; now: Date; timeStyle?: ReminderTimeStyle; draggable: boolean }) {
  const notes = useNotesController();
  const reduced = useReducedMotion();
  const [editing, setEditing] = useState(false);
  const use24h = useSettings((s) => s.use24hTime);
  const dateFormat = useSettings((s) => s.dateFormat);
  const key = occurrenceKey(reminder);
  const { attributes, listeners, setNodeRef, isDragging } = useDraggable({
    id: key,
    data: { type: REMINDER_DRAG_TYPE, occurrence: reminder },
    disabled: !draggable || reminder.projected,
  });
  const past = reminder.at.getTime() < now.getTime();
  const time = timeStyle === "clock" ? formatClock(reminder.at, use24h) : reminderLabel(reminder.at, { use24hTime: use24h, dateFormat }, now);
  const title = occurrenceTitle(reminder);
  const open = (): void => navigate({ name: "note", noteId: reminder.note.id });

  return (
    <motion.div
      initial={{ height: 0, opacity: 0 }}
      animate={{ height: "auto", opacity: 1 }}
      exit={{ height: 0, opacity: 0 }}
      transition={transitionFor(TRANSITION.base, reduced)}
      className="overflow-hidden"
    >
      <div
        ref={setNodeRef}
        {...attributes}
        {...listeners}
        // The title button is the keyboard path; the whole row is the pointer's.
        tabIndex={-1}
        role={undefined}
        onClick={open}
        className={cn(
          "group/tile relative flex min-h-14 cursor-pointer items-center gap-2 py-2 pr-1 pl-2 transition-[background-color,opacity] duration-150 ease-standard hover:bg-hover",
          isDragging && "opacity-40",
        )}
      >
        <span className="relative z-[1] grid size-10 shrink-0 place-items-center" onClick={(event) => reminder.item && event.stopPropagation()}>
          {reminder.item ? <CompleteBox key={key} reminder={reminder} /> : <NoteBadge noteId={reminder.note.id} />}
        </span>
        <span className="flex min-w-0 flex-1 flex-col gap-0.5">
          <button
            type="button"
            onClick={(event) => {
              event.stopPropagation();
              open();
            }}
            className={cn("line-clamp-2 rounded-xs text-left text-sm outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50", past ? "text-on-surface-variant" : "text-on-surface")}
          >
            {title}
          </button>
          {reminder.item || reminder.repeat || reminder.note.archived ? (
            <span className="flex flex-wrap gap-x-3 gap-y-0.5">
              {reminder.item ? <Meta icon={ListTodo}>{noteDisplayTitle(reminder.note)}</Meta> : null}
              {reminder.repeat ? <Meta icon={Repeat}>{REPEAT_LABELS[reminder.repeat]}</Meta> : null}
              {reminder.note.archived ? <Meta icon={Archive}>Archived</Meta> : null}
            </span>
          ) : null}
        </span>
        <span className={cn("shrink-0 text-sm font-medium tabular-nums", past ? "text-on-surface-variant" : "text-on-surface", past && reminder.repeat === null && "line-through")}>{time}</span>
        <span className="relative z-[1]" onClick={(event) => event.stopPropagation()}>
          <TileMenu reminder={reminder} onEdit={() => setEditing(true)} onRemove={() => removeReminder(notes, reminder)} />
        </span>
      </div>
      <EditReminderDialog reminder={reminder} open={editing} onOpenChange={setEditing} />
    </motion.div>
  );
}

function TileMenu({ reminder, onEdit, onRemove }: { reminder: ReminderOccurrence; onEdit(): void; onRemove(): void }) {
  const notes = useNotesController();
  // Snoozing a repeating reminder would move the whole series.
  const snoozes = reminder.projected || reminder.repeat !== null ? [] : REMINDER_SNOOZES;
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <IconButton
          label="Reminder options"
          size="sm"
          icon={<EllipsisVertical />}
          className="text-on-surface-variant opacity-0 transition-opacity duration-150 ease-standard group-hover/tile:opacity-100 focus-visible:opacity-100 data-[state=open]:opacity-100 [@media(hover:none)]:opacity-100"
        />
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="min-w-52">
        <DropdownMenuItem onSelect={onEdit}>
          <CalendarClock />
          <MenuLabel label="Edit reminder" />
        </DropdownMenuItem>
        {snoozes.map((snooze) => (
          <DropdownMenuItem key={snooze.id} onSelect={() => rescheduleReminder(notes, reminder, snoozeAfter(snooze.id, new Date()))}>
            <Clock />
            <MenuLabel label={snooze.label} />
          </DropdownMenuItem>
        ))}
        {reminder.projected ? null : (
          <>
            <DropdownMenuSeparator />
            <DropdownMenuItem variant="destructive" onSelect={onRemove}>
              <BellOff />
              <MenuLabel label="Remove reminder" tone="destructive" />
            </DropdownMenuItem>
          </>
        )}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

/** The stored reminder behind [reminder] (a forecast turn edits its series). */
function useStoredValue(reminder: ReminderOccurrence): ReminderValue | null {
  const note = useNote(reminder.note.id);
  if (!note) {
    return null;
  }
  const item = reminder.item;
  const stored = item ? note.itemReminders[item.id] : note.reminderAt ? { at: note.reminderAt, repeat: note.reminderRepeat } : undefined;
  if (!stored) {
    return null;
  }
  return stored.repeat ? { at: stored.at, repeat: stored.repeat } : { at: stored.at };
}

export function EditReminderDialog({ reminder, open, onOpenChange }: { reminder: ReminderOccurrence; open: boolean; onOpenChange(open: boolean): void }) {
  const notes = useNotesController();
  const use24h = useSettings((s) => s.use24hTime);
  const value = useStoredValue(reminder);

  const apply = (next: ReminderValue | null): void => {
    onOpenChange(false);
    const at = next?.at ?? null;
    const repeat = next?.repeat ?? null;
    if (reminder.item) {
      notes.setItemReminder(reminder.note.id, reminder.item.id, at, repeat);
    } else {
      notes.setReminder(reminder.note.id, at, repeat);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle className="truncate">{occurrenceTitle(reminder)}</DialogTitle>
          <DialogDescription>{reminder.item ? "Reminder for this item" : "Reminder for this note"}</DialogDescription>
        </DialogHeader>
        {open ? <ReminderPicker value={value} onChange={apply} use24h={use24h} /> : null}
      </DialogContent>
    </Dialog>
  );
}

/** What follows the pointer while a reminder is carried to another day. */
export function ReminderDragPreview({ reminder }: { reminder: ReminderOccurrence }) {
  return (
    <div className="flex max-w-60 cursor-grabbing items-center gap-2 rounded-md border border-outline-variant bg-surface px-3 py-2 shadow-raised">
      <AlarmClock className="size-4 shrink-0 text-primary" />
      <span className="truncate text-sm text-on-surface">{occurrenceTitle(reminder)}</span>
    </div>
  );
}
