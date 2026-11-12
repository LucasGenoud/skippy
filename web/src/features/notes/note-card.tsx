"use client";

import { createContext, memo, useContext, useEffect, useRef, useState, type CSSProperties, type KeyboardEvent, type MouseEvent } from "react";
import { Check, Folder } from "lucide-react";
import { AnimatePresence, motion } from "motion/react";
import { cn } from "cn";

import { LabelChip, LabelMarker, LabelOverflowMarker } from "@/components/common/label-chip";
import { NotePattern } from "@/components/common/note-pattern";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { generalCollectionId } from "@/lib/models/workspace";
import type { Note } from "@/lib/models/note";
import { navigate } from "@/lib/router";
import { highlightQueryOf, useNav, useNotesController, useSettings, useUiController } from "@/lib/store";
import { LabelIcon } from "@/lib/theme/label-style";
import { TRANSITION } from "@/lib/theme/motion";
import { noteColor } from "@/lib/theme/palette";
import type { NotePatternId } from "@/lib/theme/patterns";

import { CardActions } from "./card-actions";
import { cardClickIntent, linkPreviewUrls, noteLinkText, type CardClick } from "./card-rules";
import { toggleArchive } from "./note-actions";
import { cardTags, tagEqual, tagOf, tagsEqual, type CardTag } from "./card-tags";
import { Spinner } from "./link-summary-indicator";
import { LINK_PREVIEW_HEIGHT } from "./link-preview-card";
import { NoteCardContent } from "./note-card-content";
import { PinIcon } from "./pin-icon";
import { observeSize, useTouchPrimary } from "./platform";
import { SwipeToArchive } from "./swipe-to-archive";

export interface NoteCardProps {
  noteId: string;
  variant: "grid" | "list" | "board";
  /** A board's drag listeners and attributes, spread on the card. */
  dragHandleProps?: Record<string, unknown>;
}

/**
 * What a grid around the cards supplies once for all of them, so each card
 * keeps one store subscription: the words to highlight, how a click selects
 * (range selection needs the grid's order), and the swipe's raise signal.
 */
export interface CardEnvironment {
  readonly query: string;
  onSelect(id: string, intent: Exclude<CardClick, "open">): void;
  onSwipeActive?(id: string, active: boolean): void;
}

export const CardEnvironmentContext = createContext<CardEnvironment | null>(null);

interface CardModel {
  readonly note: Note | null;
  readonly selected: boolean;
  readonly selectionMode: boolean;
  readonly rewriting: boolean;
  readonly labels: readonly CardTag[];
  /** The archive view marks each card with its collection. */
  readonly collection: CardTag | null;
  readonly query: string;
}

function modelsEqual(a: CardModel, b: CardModel): boolean {
  return (
    a.note === b.note &&
    a.selected === b.selected &&
    a.selectionMode === b.selectionMode &&
    a.rewriting === b.rewriting &&
    a.query === b.query &&
    tagsEqual(a.labels, b.labels) &&
    tagEqual(a.collection, b.collection)
  );
}

/** The footer slot's height and offset from the card's bottom. */
const FOOTER_HEIGHT = 40;

/**
 * A note in the grid, list or board (`widgets/note_card.dart`). Clicking opens
 * the editor; the hover row, pin and selection badge are pointer affordances
 * built the first time they show.
 */
export const NoteCard = memo(function NoteCard({ noteId, variant, dragHandleProps }: NoteCardProps) {
  const env = useContext(CardEnvironmentContext);
  const notes = useNotesController();
  const ui = useUiController();
  const touch = useTouchPrimary();
  const palette = useSettings((s) => s.palette);
  const model = useNav<CardModel>(
    (n, u) => {
      const note = noteId in n.editingCards ? (n.editingCards[noteId] ?? null) : (n.notes[noteId] ?? null);
      let collection: CardTag | null = null;
      if (note && u.destination === "archive") {
        const workspace = n.workspaces.find((w) => w.id === note.workspaceId);
        const target = note.collectionId ?? generalCollectionId(note.workspaceId);
        const found = workspace?.collections.find((c) => c.id === target);
        collection = found ? tagOf(found) : null;
      }
      return {
        note,
        selected: u.selectedIds.includes(noteId),
        selectionMode: u.selectedIds.length > 0,
        rewriting: noteId in n.rewriting,
        labels: note ? cardTags(note.labelIds, n.labels) : [],
        collection,
        query: env ? env.query : highlightQueryOf(n, u),
      };
    },
    modelsEqual,
    [noteId, env],
  );
  const [hovered, setHovered] = useState(false);
  const [everHovered, setEverHovered] = useState(false);
  const [overlayOpen, setOverlayOpen] = useState(false);

  const { note, selected, selectionMode, rewriting, labels, collection, query } = model;
  if (!note) {
    return null;
  }

  const actionsSlot = !note.trashed && !touch;
  const desktopActions = actionsSlot && !selectionMode;
  // Keep the row while a menu or picker it opened is up: those live in a portal.
  const actionsVisible = hovered || overlayOpen;
  const previewInset = linkPreviewUrls(noteLinkText(note)).length * (LINK_PREVIEW_HEIGHT + 1);
  const fillLight = noteColor(note.color, "light", palette);
  const fillDark = noteColor(note.color, "dark", palette);
  const title = note.title.trim() || "untitled note";

  const select = (intent: Exclude<CardClick, "open">): void => {
    if (env) {
      env.onSelect(note.id, intent);
    } else {
      ui.toggleSelected(note.id);
    }
  };

  const onClick = (event: MouseEvent): void => {
    const intent = cardClickIntent(event, selectionMode);
    if (intent === "open") {
      navigate({ name: "note", noteId: note.id });
      return;
    }
    event.preventDefault();
    select(intent);
  };

  const onKeyDown = (event: KeyboardEvent): void => {
    if (event.target !== event.currentTarget) {
      return;
    }
    if (event.key === "Enter") {
      event.preventDefault();
      if (selectionMode) {
        select("toggle");
      } else {
        navigate({ name: "note", noteId: note.id });
      }
    } else if (event.key === " ") {
      event.preventDefault();
      select("toggle");
    }
  };

  const style = {
    "--note-fill-l": fillLight ?? "var(--surface)",
    "--note-fill-d": fillDark ?? "var(--surface)",
    "--note-edge-l": fillLight && fillDark ? `color-mix(in srgb, ${fillLight}, ${fillDark} 35%)` : "var(--outline-variant)",
    "--note-edge-d": fillLight && fillDark ? `color-mix(in srgb, ${fillDark}, ${fillLight} 35%)` : "var(--outline-variant)",
    "--note-edge-hover-l": fillLight && fillDark ? `color-mix(in srgb, ${fillLight}, ${fillDark} 55%)` : "var(--outline-variant)",
    "--note-edge-hover-d": fillLight && fillDark ? `color-mix(in srgb, ${fillDark}, ${fillLight} 55%)` : "var(--outline-variant)",
  } as CSSProperties;

  return (
    <SwipeToArchive
      enabled={touch && variant !== "board" && !note.trashed && !selectionMode}
      archived={note.archived}
      onArchive={() => toggleArchive(notes, notes.noteById(note.id) ?? note)}
      onActive={(active) => env?.onSwipeActive?.(note.id, active)}
    >
      <div
        className="relative"
        data-note-card={note.id}
        onPointerEnter={(event) => {
          if (event.pointerType === "mouse" || event.pointerType === "pen") {
            setHovered(true);
            setEverHovered(true);
          }
        }}
        onPointerLeave={() => setHovered(false)}
      >
        <article
          role="button"
          tabIndex={0}
          aria-label={`${selectionMode ? (selected ? "Deselect" : "Select") : "Open"} ${title}`}
          aria-pressed={selectionMode ? selected : undefined}
          {...dragHandleProps}
          onClick={(event) => {
            onClick(event);
            if (!event.defaultPrevented) {
              (dragHandleProps?.onClick as ((e: MouseEvent) => void) | undefined)?.(event);
            }
          }}
          onKeyDown={(event) => {
            // Enter opens and Space selects; a board's own keys get what is left.
            onKeyDown(event);
            if (!event.defaultPrevented) {
              (dragHandleProps?.onKeyDown as ((e: KeyboardEvent) => void) | undefined)?.(event);
            }
          }}
          style={style}
          className={cn(
            "relative cursor-pointer overflow-hidden rounded-md border text-on-surface outline-none select-none [-webkit-touch-callout:none]",
            "bg-(--note-fill-l) dark:bg-(--note-fill-d)",
            "transition-[box-shadow,border-color] duration-150 ease-standard focus-visible:ring-[3px] focus-visible:ring-ring/50",
            selected
              ? "border-primary ring-1 ring-primary"
              : hovered
                ? "border-(--note-edge-hover-l) dark:border-(--note-edge-hover-d)"
                : "border-(--note-edge-l) dark:border-(--note-edge-d)",
            hovered ? "shadow-raised" : "shadow-card",
          )}
        >
          <NotePattern pattern={note.pattern as NotePatternId} />
          <div className="relative">
            <NoteCardContent note={note} query={query} reserveActions={actionsSlot} labels={labels} />
          </div>

          {collection ? <CollectionMarker tag={collection} /> : null}

          {!note.trashed ? (
            <motion.div
              className="absolute top-1 right-1"
              initial={false}
              animate={{ opacity: !rewriting && (hovered || note.pinned) ? 1 : 0 }}
              transition={TRANSITION.fast}
              style={{ pointerEvents: !rewriting && (hovered || note.pinned) ? "auto" : "none" }}
            >
              {everHovered || note.pinned ? (
                <Tooltip>
                  <TooltipTrigger asChild>
                    <button
                      type="button"
                      aria-label={note.pinned ? "Unpin note" : "Pin note"}
                      className="inline-flex size-8 items-center justify-center rounded-md text-on-surface-variant transition-colors duration-150 ease-standard outline-none hover:bg-hover focus-visible:ring-[3px] focus-visible:ring-ring/50"
                      onClick={(event) => {
                        event.stopPropagation();
                        notes.togglePin(note.id);
                      }}
                      onPointerDown={(event) => event.stopPropagation()}
                    >
                      <PinIcon pinned={note.pinned} />
                    </button>
                  </TooltipTrigger>
                  <TooltipContent>{note.pinned ? "Unpin note" : "Pin note"}</TooltipContent>
                </Tooltip>
              ) : null}
            </motion.div>
          ) : null}

          {rewriting ? (
            <span role="status" aria-label="AI editing note" className="absolute top-[11px] right-[11px]">
              <Spinner className="size-[18px]" />
            </span>
          ) : null}

          {actionsSlot ? (
            <div className="absolute right-2 left-2" style={{ bottom: 4 + previewInset, height: FOOTER_HEIGHT }}>
              <AnimatePresence initial={false}>
                {desktopActions && actionsVisible ? (
                  <motion.div key="actions" className="h-full" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={TRANSITION.fast}>
                    <CardActions note={note} onOverlayChange={setOverlayOpen} />
                  </motion.div>
                ) : null}
              </AnimatePresence>
            </div>
          ) : null}

          {actionsSlot && labels.length > 0 ? (
            <FooterLabels labels={labels} visible={!(desktopActions && actionsVisible)} bottom={8 + previewInset} />
          ) : null}
        </article>

        {!touch ? (
          <SelectionBadge selected={selected} visible={selectionMode || hovered} built={everHovered || selectionMode} onToggle={() => select("toggle")} />
        ) : null}
      </div>
    </SwipeToArchive>
  );
});

/** The archive's quiet corner glyph naming the card's collection. */
function CollectionMarker({ tag }: { tag: CardTag }) {
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <span className="absolute top-1.5 right-[38px] inline-flex size-7 items-center justify-center rounded-md bg-surface/75" aria-label={tag.name}>
          {tag.icon ? (
            <LabelIcon iconKey={tag.icon} aria-hidden className={cn("size-[15px]", !tag.color && "text-on-surface-variant")} style={tag.color ? { color: tag.color } : undefined} />
          ) : (
            <Folder aria-hidden className={cn("size-[15px]", !tag.color && "text-on-surface-variant")} style={tag.color ? { color: tag.color } : undefined} />
          )}
        </span>
      </TooltipTrigger>
      <TooltipContent>{tag.name}</TooltipContent>
    </Tooltip>
  );
}

/**
 * The badge for entering or extending a selection, on the card's top-left
 * corner, half over the canvas. Hidden until the pointer is over the card.
 */
function SelectionBadge({ selected, visible, built, onToggle }: { selected: boolean; visible: boolean; built: boolean; onToggle: () => void }) {
  if (!built) {
    return null;
  }
  return (
    <motion.button
      type="button"
      role="checkbox"
      aria-checked={selected}
      aria-label={selected ? "Deselect note" : "Select note"}
      title={selected ? "Deselect note" : "Select note"}
      initial={false}
      animate={{ opacity: visible ? 1 : 0 }}
      transition={TRANSITION.fast}
      style={{ pointerEvents: visible ? "auto" : "none" }}
      tabIndex={visible ? 0 : -1}
      onClick={(event) => {
        event.stopPropagation();
        onToggle();
      }}
      onPointerDown={(event) => event.stopPropagation()}
      className={cn(
        "absolute -top-[5px] -left-[5px] z-10 inline-flex size-5 items-center justify-center rounded-check border shadow-card transition-colors duration-150 ease-standard outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50",
        selected ? "border-primary-container bg-primary-container text-on-primary-container" : "border-primary bg-surface",
      )}
    >
      <AnimatePresence initial={false}>
        {selected ? (
          <motion.span key="check" className="inline-flex" initial={{ scale: 0 }} animate={{ scale: 1 }} exit={{ scale: 0 }} transition={TRANSITION.pop}>
            <Check aria-hidden className="size-[13px]" strokeWidth={3} />
          </motion.span>
        ) : null}
      </AnimatePresence>
    </motion.button>
  );
}

const MARKER_WIDTH = 24;
const MARKER_GAP = 6;
/** Chip padding plus edge, and the icon's room when it has one. */
const CHIP_CHROME = 22;
const CHIP_ICON = 14;

let measureContext: CanvasRenderingContext2D | null | undefined;

function textWidth(text: string, font: string): number {
  if (measureContext === undefined) {
    measureContext = typeof document === "undefined" ? null : document.createElement("canvas").getContext("2d");
  }
  if (!measureContext) {
    return text.length * 6.5;
  }
  measureContext.font = font;
  return measureContext.measureText(text).width;
}

/**
 * At rest the reserved desktop footer shows the labels; the hover row takes
 * their place without moving the card. Too many for the width become markers.
 */
function FooterLabels({ labels, visible, bottom }: { labels: readonly CardTag[]; visible: boolean; bottom: number }) {
  const ref = useRef<HTMLDivElement | null>(null);
  const [width, setWidth] = useState(0);
  const [font, setFont] = useState("500 11px sans-serif");
  useEffect(() => {
    const element = ref.current;
    if (!element) {
      return;
    }
    const style = getComputedStyle(element);
    setFont(`500 11px ${style.fontFamily}`);
    return observeSize(element, ({ width: w }) => setWidth(w));
  }, []);

  const full = labels.reduce((sum, tag, i) => sum + textWidth(tag.name, font) + CHIP_CHROME + (tag.icon ? CHIP_ICON : 0) + (i > 0 ? MARKER_GAP : 0), 1);
  const compact = width > 0 && full > width;
  const slots = Math.floor((width + MARKER_GAP) / (MARKER_WIDTH + MARKER_GAP));
  const overflow = compact && slots > 0 && labels.length > slots;
  const shown = compact ? Math.max(0, Math.min(labels.length, slots - (overflow ? 1 : 0))) : labels.length;

  return (
    <motion.div
      ref={ref}
      aria-hidden={!visible}
      className="pointer-events-none absolute right-4 left-4 flex items-center gap-1.5 overflow-hidden"
      style={{ bottom, height: FOOTER_HEIGHT }}
      initial={false}
      animate={{ opacity: visible ? 1 : 0 }}
      transition={TRANSITION.fast}
    >
      {compact
        ? labels.slice(0, shown).map((tag) => <LabelMarker key={tag.id} name={tag.name} color={tag.color} icon={tag.icon} />)
        : labels.map((tag) => <LabelChip key={tag.id} name={tag.name} color={tag.color} icon={tag.icon} className="shrink-0" />)}
      {overflow ? <LabelOverflowMarker count={labels.length - shown} /> : null}
    </motion.div>
  );
}
