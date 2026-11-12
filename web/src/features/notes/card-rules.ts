import { findUrls } from "@/lib/util/linkify";
import { isNoteOwnedBy, type ChecklistItem, type Note } from "@/lib/models/note";

// The decisions a note card makes about what to show, kept pure so they can
// be tested without rendering. Ported from `note_card/content.dart`,
// `link_preview.dart` and `swipe_to_archive.dart`.

/** At most this many link previews hang under a card or editor. */
export const MAX_LINK_PREVIEWS = 5;
/** Unchecked rows a checklist card lists before "+ N more". */
export const MAX_CHECKLIST_PREVIEW_ITEMS = 16;
const MAX_SHARED_OWNER_CHARACTERS = 16;

/** Title, body and checklist rows: everywhere a link may be written. */
export function noteLinkText(note: Note): string {
  return [note.title, note.content, ...note.items.map((i) => i.text)].join("\n");
}

/** The distinct URLs that get a preview strip, in order of appearance. */
export function linkPreviewUrls(text: string): string[] {
  const seen: string[] = [];
  for (const match of findUrls(text)) {
    if (!seen.includes(match.url)) {
      seen.push(match.url);
    }
    if (seen.length === MAX_LINK_PREVIEWS) {
      break;
    }
  }
  return seen;
}

export interface ChecklistPreview {
  /** Rows with text; blank rows never show on a card. */
  readonly visible: readonly ChecklistItem[];
  readonly unchecked: readonly ChecklistItem[];
  readonly checkedCount: number;
  /** The unchecked rows the card lists. */
  readonly rows: readonly ChecklistItem[];
  /** Unchecked rows left out ("+ N more"). */
  readonly hidden: number;
}

/** What a checklist card lists: its open rows, capped; the done ones are only counted. */
export function checklistPreview(items: readonly ChecklistItem[]): ChecklistPreview {
  const visible = items.filter((i) => i.text.trim() !== "");
  const unchecked = visible.filter((i) => !i.done);
  const rows = unchecked.slice(0, MAX_CHECKLIST_PREVIEW_ITEMS);
  return { visible, unchecked, checkedCount: visible.length - unchecked.length, rows, hidden: unchecked.length - rows.length };
}

/** The owner's name for a note shared with the user, shortened; null for their own. */
export function sharedByLabel(note: Note, currentUserId: string | null): string | null {
  if (isNoteOwnedBy(note, currentUserId)) {
    return null;
  }
  const name = note.owner?.name.trim() ?? "";
  if (!name) {
    return null;
  }
  const characters = Array.from(name);
  if (characters.length <= MAX_SHARED_OWNER_CHARACTERS) {
    return name;
  }
  return `${characters.slice(0, MAX_SHARED_OWNER_CHARACTERS - 1).join("")}…`;
}

/** The people icon's tooltip. */
export function sharedTooltip(note: Note, sharedBy: string | null): string {
  if (sharedBy !== null && note.owner) {
    return `Shared by ${note.owner.name}`;
  }
  const names = [...(note.owner ? [note.owner.name] : []), ...note.collaborators.map((c) => c.name)];
  return `Shared with ${names.join(", ")}`;
}

const MARKDOWN_TITLE = /(^#{1,6}\s|[*_`~]|\[[^\]]+\]\([^)]+\))/m;

/** Whether a title carries markdown worth rendering rather than plain text. */
export function titleHasMarkdown(title: string): boolean {
  return MARKDOWN_TITLE.test(title);
}

// -- swipe to archive -----------------------------------------------------------

/** How far across its width a card travels to commit, capped in pixels. */
export const SWIPE_COMMIT_FRACTION = 0.35;
export const SWIPE_MAX_COMMIT_DISTANCE = 120;
/** A flick past this (px/s) commits from wherever it is. */
export const SWIPE_MIN_FLING_VELOCITY = 700;
/** Where in its travel the card starts fading. */
export const SWIPE_FADE_FROM = 0.55;

export function swipeCommitDistance(width: number): number {
  return Math.min(width * SWIPE_COMMIT_FRACTION, SWIPE_MAX_COMMIT_DISTANCE);
}

/**
 * What a released swipe does: commit (archive) when it travelled far enough
 * or was flung the same way it travelled, otherwise settle back.
 */
export function swipeOutcome(travelled: number, width: number, velocity: number): "commit" | "settle" {
  if (Math.abs(travelled) >= swipeCommitDistance(width)) {
    return "commit";
  }
  const flung = Math.abs(velocity) >= SWIPE_MIN_FLING_VELOCITY && travelled !== 0 && Math.sign(velocity) === Math.sign(travelled);
  return flung ? "commit" : "settle";
}

/** The card's opacity at a travel fraction (0..1): solid until FADE_FROM, then fading. */
export function swipeOpacity(fraction: number): number {
  const travelled = Math.abs(fraction);
  if (travelled <= SWIPE_FADE_FROM) {
    return 1;
  }
  return Math.min(1, Math.max(0, 1 - (travelled - SWIPE_FADE_FROM) / (1 - SWIPE_FADE_FROM)));
}

// -- selection --------------------------------------------------------------------

/**
 * A shift-click: every id between the anchor and the target in visible order
 * joins the selection. Without an anchor in view it is a plain toggle.
 */
export function rangeSelection(visible: readonly string[], selected: readonly string[], anchor: string | null, target: string): string[] {
  const from = anchor === null ? -1 : visible.indexOf(anchor);
  const to = visible.indexOf(target);
  if (from < 0 || to < 0) {
    return selected.includes(target) ? selected.filter((id) => id !== target) : [...selected, target];
  }
  const [lo, hi] = from <= to ? [from, to] : [to, from];
  const range = visible.slice(lo, hi + 1);
  return [...selected, ...range.filter((id) => !selected.includes(id))];
}

/** How a click on a card is read. */
export type CardClick = "open" | "toggle" | "range";

export function cardClickIntent(event: { metaKey: boolean; ctrlKey: boolean; shiftKey: boolean }, selectionMode: boolean): CardClick {
  if (event.shiftKey) {
    return "range";
  }
  if (event.metaKey || event.ctrlKey || selectionMode) {
    return "toggle";
  }
  return "open";
}

/** "Couldn't rewrite the note. <Reason>." from whatever failed. */
export function rewriteFailureSentence(reason: string): string {
  const trimmed = reason.trim() || "the server could not be reached";
  const sentence = trimmed.endsWith(".") ? trimmed : `${trimmed}.`;
  return sentence.charAt(0).toUpperCase() + sentence.slice(1);
}
