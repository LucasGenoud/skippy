"use client";

import { memo, useEffect, useRef, useState } from "react";
import { AudioLines, Paperclip, Users } from "lucide-react";
import { AnimatePresence, motion } from "motion/react";
import { cn } from "cn";

import { AllDoneBurst } from "@/components/common/all-done-burst";
import { LabelChip } from "@/components/common/label-chip";
import { ProgressRing } from "@/components/common/progress-ring";
import { ReminderChip } from "@/components/common/reminder-chip";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { audioClip, isAudioAttachment, isImageAttachment, isNoteEmpty, isNoteShared, type ChecklistItem, type Note } from "@/lib/models/note";
import { useNotesController } from "@/lib/store";
import { TRANSITION } from "@/lib/theme/motion";
import { highlightSegments } from "@/lib/util/highlight";

import { AudioPlayer } from "./audio-player";
import { checklistPreview, linkPreviewUrls, noteLinkText, sharedByLabel, sharedTooltip, titleHasMarkdown } from "./card-rules";
import type { CardTag } from "./card-tags";
import { LinkPreviewCard } from "./link-preview-card";
import { LinkSummaryIndicator } from "./link-summary-indicator";
import { LinkedText } from "./linked-text";
import { NoteImage } from "./note-image";
import { NoteMarkdown } from "./note-markdown";
import { TranscribingIndicator, TranscriptFailed } from "./transcribing-indicator";

// What a card shows of its note: title, body preview, checklist rows, images,
// files and the chips under them (`note_card/content.dart`).

const MAX_MARKDOWN_PREVIEW_HEIGHT = 440;
const MAX_IMAGE_HEIGHT = 280;
const VISIBLE_FILES = 2;
const VISIBLE_BODY_LABELS = 3;
/** The hover row's reserved slot under the content. */
export const ACTIONS_SLOT_HEIGHT = 48;
/** A tick shows on the box for this long before the row files itself away. */
const CHECK_SETTLE_MS = 160;

export interface CardContentProps {
  note: Note;
  query: string;
  /** Leave room for the desktop hover row (labels show there instead). */
  reserveActions: boolean;
  labels: readonly CardTag[];
}

export const NoteCardContent = memo(function NoteCardContent({ note, query, reserveActions, labels }: CardContentProps) {
  const notes = useNotesController();
  const showLabelsInBody = !reserveActions;
  const checklist = note.kind === "checklist" ? checklistPreview(note.items) : null;
  const images = note.attachments.filter(isImageAttachment);
  // Audio clips are the audio note's own player, not a chip.
  const files = note.attachments.filter((a) => !isImageAttachment(a) && !isAudioAttachment(a));
  const previews = linkPreviewUrls(noteLinkText(note));
  const hasPreviews = previews.length > 0;
  const clip = note.kind === "audio" ? audioClip(note) : null;
  const sharedBy = sharedByLabel(note, notes.currentUserId);
  const empty = isNoteEmpty(note);

  const hasTextBlock =
    note.title !== "" ||
    note.kind === "audio" ||
    (note.kind !== "checklist" && note.content !== "") ||
    (checklist !== null && checklist.visible.length > 0) ||
    empty;
  const hasProgress = checklist !== null && checklist.visible.length > 0;
  const hasFooter = hasProgress || note.reminderAt !== null || (showLabelsInBody && labels.length > 0) || files.length > 0 || isNoteShared(note);
  const tailPad = hasPreviews ? "pb-3" : reserveActions ? "pb-1" : "pb-4";

  return (
    <div className="flex flex-col">
      {hasTextBlock ? (
        <div className={cn("px-4 pt-4", images.length > 0 || hasFooter ? "pb-0" : tailPad)}>
          {note.title !== "" ? (
            // Room for the pin, always: tying it to hover made titles reflow under the cursor.
            <div className={cn(note.trashed ? "" : "pr-7")}>
              <CardTitle title={note.title} query={query} />
            </div>
          ) : null}
          {note.title !== "" && (note.content !== "" || (checklist?.rows.length ?? 0) > 0 || note.kind === "audio") ? <div className="h-2" /> : null}
          {note.kind === "audio" ? (
            <AudioBody note={note} clipId={clip?.id ?? null} />
          ) : note.kind === "markdown" && note.content !== "" ? (
            <div className="pointer-events-none overflow-hidden" style={{ maxHeight: MAX_MARKDOWN_PREVIEW_HEIGHT }}>
              <NoteMarkdown source={note.content} variant="card" />
            </div>
          ) : note.kind !== "checklist" && note.content !== "" ? (
            <p className="line-clamp-[20] text-sm leading-[1.45]">
              <LinkedText text={note.content} highlight={query} variant="card" />
            </p>
          ) : null}
          {checklist ? <ChecklistRows note={note} rows={checklist.rows} hidden={checklist.hidden} /> : null}
          {empty ? <p className="text-sm text-on-surface-variant">Empty note</p> : null}
          <AnimatePresence initial={false}>
            {note.summarizingLinks ? (
              <motion.div key="summary" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={TRANSITION.fast} className="pt-2.5">
                <LinkSummaryIndicator compact onCancel={() => void notes.cancelLinkSummaries(note.id)} />
              </motion.div>
            ) : null}
          </AnimatePresence>
        </div>
      ) : null}

      {images.length > 0 ? (
        <div className={cn("relative", hasTextBlock && "pt-3")}>
          <NoteImage attachment={images[0]!} url={notes.fileUrl(images[0]!)} maxHeight={MAX_IMAGE_HEIGHT} />
          {images.length > 1 ? (
            <span className="absolute right-2 bottom-2 rounded-md bg-black/55 px-2 py-0.5 text-xs text-white">+{images.length - 1}</span>
          ) : null}
        </div>
      ) : null}

      {hasFooter ? (
        <div className={cn("flex flex-wrap items-center gap-1.5 px-4", hasTextBlock || images.length > 0 ? "pt-3" : "pt-4", tailPad)}>
          {hasProgress && checklist ? <ProgressRing done={checklist.checkedCount} total={checklist.visible.length} /> : null}
          {note.reminderAt ? <ReminderChip at={note.reminderAt} repeat={note.reminderRepeat} /> : null}
          {files.slice(0, VISIBLE_FILES).map((file) => (
            <span key={file.id} className="inline-flex h-6 max-w-[140px] items-center gap-1 rounded-md bg-on-surface/8 px-2 text-2xs font-medium text-on-surface-variant">
              <Paperclip aria-hidden className="size-[13px] shrink-0" />
              <span className="truncate">{file.filename || "file"}</span>
            </span>
          ))}
          {files.length > VISIBLE_FILES ? <LabelChip name={`+${files.length - VISIBLE_FILES} files`} /> : null}
          {showLabelsInBody ? (
            <>
              {labels.slice(0, VISIBLE_BODY_LABELS).map((tag) => (
                <LabelChip key={tag.id} name={tag.name} color={tag.color} icon={tag.icon} />
              ))}
              {labels.length > VISIBLE_BODY_LABELS ? <LabelChip name={`+${labels.length - VISIBLE_BODY_LABELS}`} /> : null}
            </>
          ) : null}
          {isNoteShared(note) ? (
            <Tooltip>
              <TooltipTrigger asChild>
                <span className="inline-flex max-w-40 items-center gap-1 text-xs text-on-surface-variant">
                  <Users aria-label={sharedTooltip(note, sharedBy)} className="size-4 shrink-0" />
                  {sharedBy ? <span className="truncate">{sharedBy}</span> : null}
                </span>
              </TooltipTrigger>
              <TooltipContent>{sharedTooltip(note, sharedBy)}</TooltipContent>
            </Tooltip>
          ) : null}
        </div>
      ) : null}

      {reserveActions ? <div aria-hidden style={{ height: ACTIONS_SLOT_HEIGHT }} /> : null}

      {previews.map((url) => (
        <LinkPreviewCard key={url} noteId={note.id} url={url} variant="card" />
      ))}
    </div>
  );
});

/** A title: plain with matches tinted, or rendered when it carries markdown. */
function CardTitle({ title, query }: { title: string; query: string }) {
  const className = "line-clamp-3 text-base leading-[1.3] font-semibold";
  if (titleHasMarkdown(title)) {
    return (
      <div className="pointer-events-none max-h-[3.9em] overflow-hidden text-base leading-[1.3] font-semibold [&_*]:!text-base [&_*]:!leading-[1.3] [&_*]:!font-semibold [&_*]:!m-0">
        <NoteMarkdown source={title} variant="card" />
      </div>
    );
  }
  return (
    <h3 className={className}>
      {highlightSegments(title, query).map((segment, i) =>
        segment.match ? (
          <mark key={i} className="rounded-xs bg-primary/30 text-inherit">
            {segment.text}
          </mark>
        ) : (
          segment.text
        ),
      )}
    </h3>
  );
}

function AudioBody({ note, clipId }: { note: Note; clipId: string | null }) {
  const transcribing = note.transcriptStatus === "pending";
  const failed = note.transcriptStatus === "failed";
  return (
    <div className="flex flex-col gap-2.5">
      {clipId ? (
        <AudioPlayer noteId={note.id} attachmentId={clipId} variant="card" />
      ) : (
        <span className="inline-flex w-fit items-center gap-1.5 rounded-md bg-on-surface/6 px-2.5 py-1 text-xs font-medium text-on-surface-variant">
          <AudioLines aria-hidden className="size-[15px] text-primary" />
          Audio
        </span>
      )}
      {transcribing ? (
        <TranscribingIndicator compact />
      ) : failed ? (
        <TranscriptFailed compact />
      ) : note.content !== "" ? (
        <p className="line-clamp-[12] text-sm leading-[1.45]">
          <LinkedText text={note.content} variant="card" />
        </p>
      ) : null}
    </div>
  );
}

/**
 * The card's open checklist rows. Only the box is pressable, so checking from
 * the grid never opens the editor; the rest of the row still does.
 */
function ChecklistRows({ note, rows, hidden }: { note: Note; rows: readonly ChecklistItem[]; hidden: number }) {
  const notes = useNotesController();
  const [burst, setBurst] = useState(0);
  const canToggle = !note.trashed;

  const check = (item: ChecklistItem): void => {
    const remaining = note.items.filter((i) => !i.done && i.text.trim() !== "" && i.id !== item.id);
    notes.setChecklistItemDone(note.id, item.id, true);
    if (remaining.length === 0) {
      setBurst((b) => b + 1);
    }
  };

  return (
    <div className="relative">
      <AnimatePresence initial={false}>
        {rows.map((item) => (
          <motion.div
            key={item.id}
            layout="position"
            initial={{ opacity: 0, height: 0 }}
            animate={{ opacity: 1, height: "auto" }}
            exit={{ opacity: 0, height: 0 }}
            transition={TRANSITION.base}
            className="overflow-hidden"
          >
            <CardChecklistRow item={item} canToggle={canToggle} onCheck={check} />
          </motion.div>
        ))}
      </AnimatePresence>
      {hidden > 0 ? <p className="pt-0.5 pl-7 text-xs text-on-surface-variant">+ {hidden} more</p> : null}
      {burst > 0 ? <AllDoneBurst key={burst} onDone={() => setBurst(0)} /> : null}
    </div>
  );
}

function CardChecklistRow({ item, canToggle, onCheck }: { item: ChecklistItem; canToggle: boolean; onCheck: (item: ChecklistItem) => void }) {
  // The tick lands on the box first; the row files itself away a moment later.
  const [ticked, setTicked] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => () => {
    if (timer.current) {
      clearTimeout(timer.current);
    }
  }, []);
  const done = item.done || ticked;
  return (
    <div className="flex items-start gap-2.5 py-0.5" style={{ paddingLeft: item.depth * 12 }} data-testid={`checklist-card-row-${item.id}`}>
      <button
        type="button"
        role="checkbox"
        aria-checked={done}
        aria-label={item.text}
        disabled={!canToggle || ticked}
        onClick={(event) => {
          event.stopPropagation();
          setTicked(true);
          timer.current = setTimeout(() => onCheck(item), CHECK_SETTLE_MS);
        }}
        onPointerDown={(event) => event.stopPropagation()}
        className={cn(
          "mt-[1px] inline-flex size-[18px] shrink-0 items-center justify-center rounded-check border transition-colors duration-150 ease-standard outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50 disabled:cursor-default",
          done ? "border-primary-container bg-primary-container text-on-primary-container" : "border-outline hover:bg-hover active:bg-pressed",
        )}
      >
        <AnimatePresence initial={false}>
          {done ? (
            <motion.svg key="tick" viewBox="0 0 16 16" aria-hidden className="size-3" initial={{ scale: 0 }} animate={{ scale: 1 }} exit={{ scale: 0 }} transition={TRANSITION.pop}>
              <path d="M3.5 8.5l3 3 6-7" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />
            </motion.svg>
          ) : null}
        </AnimatePresence>
      </button>
      <span className={cn("line-clamp-2 min-w-0 flex-1 text-sm leading-[1.35] transition-colors duration-150 ease-standard", done && "text-on-surface-variant line-through")}>
        {item.text}
      </span>
    </div>
  );
}
