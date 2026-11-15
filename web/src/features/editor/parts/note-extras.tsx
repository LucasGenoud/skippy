"use client";

import { useState } from "react";
import { CalendarDays, X } from "lucide-react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { cn } from "cn";

import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { ReminderPicker, type ReminderValue } from "@/components/common/reminder-picker";
import type { Label } from "@/lib/models/note";
import { LabelIcon, labelStyle } from "@/lib/theme/label-style";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";
import { findUrls } from "@/lib/util/linkify";
import { LinkPreviewCard } from "@/features/notes/link-preview-card";
import { NoteLabelPicker } from "../label-picker";

// What sits under the note's text: reminder and label chips, and previews of
// the links it holds (`_metaChips`, `_linkPreviews` in editor_screen.dart).

/** Most link previews one note shows (`kMaxLinkPreviewCards`). */
export const MAX_LINK_PREVIEWS = 5;

/** The distinct URLs in [text] that get a preview card, first five. */
export function linkPreviewUrls(text: string): string[] {
  return [...new Set(findUrls(text).map((m) => m.url))].slice(0, MAX_LINK_PREVIEWS);
}

const CHIP =
  "inline-flex h-7 max-w-full min-w-0 items-center gap-1.5 rounded-md border text-xs font-medium transition-colors duration-150 ease-standard";

function ChipRemove({ label, onRemove }: { label: string; onRemove(): void }) {
  return (
    <button
      type="button"
      aria-label={label}
      onClick={onRemove}
      className="-mr-1 inline-flex size-5 items-center justify-center rounded-xs opacity-70 outline-none hover:bg-on-surface/10 hover:opacity-100 focus-visible:ring-[3px] focus-visible:ring-ring/50"
    >
      <X aria-hidden className="size-3.5" />
    </button>
  );
}

export function MetaChips({
  noteId,
  reminder,
  reminderText,
  labels,
  readOnly,
  use24h,
  onReminder,
  onRemoveLabel,
}: {
  noteId: string;
  reminder: ReminderValue | null;
  reminderText: string;
  labels: readonly Label[];
  readOnly: boolean;
  use24h: boolean;
  onReminder(value: ReminderValue | null): void;
  onRemoveLabel(labelId: string): void;
}) {
  const [open, setOpen] = useState(false);
  const [openedAt] = useState(Date.now);
  const reduced = useReducedMotion();
  const transition = transitionFor(TRANSITION.fast, reduced);
  const chipMotion = { initial: { opacity: 0, scale: 0.9 }, animate: { opacity: 1, scale: 1 }, exit: { opacity: 0, scale: 0.9 }, transition };
  return (
    <div className="flex flex-wrap gap-2 pt-3">
      <AnimatePresence initial={false} mode="popLayout">
        {reminder ? (
          <motion.span key="reminder" layout {...chipMotion} className={cn(CHIP, "border-outline-variant bg-on-surface/6 pr-2 pl-2 text-on-surface-variant")}>
            <Popover open={open} onOpenChange={setOpen}>
              <PopoverTrigger asChild disabled={readOnly}>
                <button type="button" className="inline-flex min-w-0 items-center gap-1.5 outline-none">
                  <CalendarDays aria-hidden className="size-3.5 shrink-0" />
                  <span className={cn("truncate", reminder.at.getTime() < openedAt && "line-through")}>{reminderText}</span>
                </button>
              </PopoverTrigger>
              <PopoverContent className="w-[360px]" align="start">
                <ReminderPicker
                  value={reminder}
                  use24h={use24h}
                  onChange={(value) => {
                    onReminder(value);
                    setOpen(false);
                  }}
                />
              </PopoverContent>
            </Popover>
            {readOnly ? null : <ChipRemove label="Remove reminder" onRemove={() => onReminder(null)} />}
          </motion.span>
        ) : null}
        {labels.map((label) => (
          <motion.span key={label.id} layout {...chipMotion} className={cn(CHIP, label.icon ? "pl-2" : "pl-2.5", "pr-2")} style={labelStyle(label.color)}>
            {readOnly ? (
              <span className="inline-flex min-w-0 items-center gap-1.5">
                <LabelIcon iconKey={label.icon} aria-hidden className="size-3.5 shrink-0 text-(--label-tint)" />
                <span className="truncate">{label.name}</span>
              </span>
            ) : (
              <NoteLabelPicker noteIds={[noteId]}>
                <button type="button" className="inline-flex min-w-0 items-center gap-1.5 outline-none">
                  <LabelIcon iconKey={label.icon} aria-hidden className="size-3.5 shrink-0 text-(--label-tint)" />
                  <span className="truncate">{label.name}</span>
                </button>
              </NoteLabelPicker>
            )}
            {readOnly ? null : <ChipRemove label={`Remove label ${label.name}`} onRemove={() => onRemoveLabel(label.id)} />}
          </motion.span>
        ))}
      </AnimatePresence>
    </div>
  );
}

export function LinkPreviews({
  noteId,
  urls,
  summarizing,
  onSummarize,
  onStopSummarize,
}: {
  noteId: string;
  urls: readonly string[];
  summarizing: ReadonlySet<string>;
  onSummarize: ((url: string) => void) | null;
  onStopSummarize(url: string): void;
}) {
  return (
    <div className="mt-3 flex flex-col overflow-hidden rounded-md border border-outline-variant [&>*+*]:border-t [&>*+*]:border-hairline">
      {urls.map((url) => (
        <LinkPreviewCard
          key={url}
          noteId={noteId}
          url={url}
          variant="editor"
          onSummarize={onSummarize ?? undefined}
          onStopSummarize={onStopSummarize}
          summarizing={summarizing.has(url)}
        />
      ))}
    </div>
  );
}
