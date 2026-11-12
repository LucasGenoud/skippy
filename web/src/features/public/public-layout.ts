import type { ChecklistItem, Note, Stage } from "@/lib/models/note";
import { isImageAttachment } from "@/lib/models/note";

// The public page's layout rules (`screens/public_share_screen.dart`), pure so
// they can be tested without a browser.

/** A card is about this wide in the grid. */
const TARGET_CARD_WIDTH = 250;
const MAX_GRID_COLUMNS = 4;

/** A card previews this many checklist rows; the single-note page shows all. */
export const CHECKLIST_PREVIEW_ROWS = 8;

export function gridColumnCount(width: number): number {
  return Math.min(MAX_GRID_COLUMNS, Math.max(1, Math.floor(width / TARGET_CARD_WIDTH)));
}

// Rough card heights in px, enough to balance columns without measuring.
const BASE_HEIGHT = 32;
const TITLE_HEIGHT = 30;
const LINE_HEIGHT = 20;
const CHARS_PER_LINE = 32;
const MAX_TEXT_LINES = 12;
const ROW_HEIGHT = 24;
const IMAGE_HEIGHT = 180;
const LABELS_HEIGHT = 34;

function estimatedHeight(note: Note): number {
  let height = BASE_HEIGHT;
  if (note.title.trim() !== "") {
    height += TITLE_HEIGHT;
  }
  if (note.kind === "checklist") {
    height += Math.min(note.items.length, CHECKLIST_PREVIEW_ROWS + 1) * ROW_HEIGHT;
  } else {
    const lines = note.content.split("\n").reduce((sum, line) => sum + Math.max(1, Math.ceil(line.length / CHARS_PER_LINE)), 0);
    height += Math.min(lines, MAX_TEXT_LINES) * LINE_HEIGHT;
  }
  height += note.attachments.filter(isImageAttachment).length * IMAGE_HEIGHT;
  if (note.labelIds.length > 0) {
    height += LABELS_HEIGHT;
  }
  return height;
}

/**
 * [notes] dealt into [count] columns, each next card into the shortest one,
 * as the masonry grid does. Reading order stays left to right, top to bottom.
 */
export function masonryColumns(notes: readonly Note[], count: number): Note[][] {
  const columns: Note[][] = Array.from({ length: Math.max(1, count) }, () => []);
  const heights = columns.map(() => 0);
  for (const note of notes) {
    let shortest = 0;
    for (let i = 1; i < heights.length; i++) {
      if ((heights[i] ?? 0) < (heights[shortest] ?? 0)) {
        shortest = i;
      }
    }
    columns[shortest]?.push(note);
    heights[shortest] = (heights[shortest] ?? 0) + estimatedHeight(note);
  }
  return columns;
}

export interface PublicBoardColumn {
  readonly key: string;
  readonly title: string;
  readonly notes: readonly Note[];
}

/** Unassigned first when it has cards, then the stages left to right, each in its own order. */
export function boardColumns(notes: readonly Note[], stages: readonly Stage[]): PublicBoardColumn[] {
  const unassigned = notes.filter((n) => n.stageId === null);
  const columns: PublicBoardColumn[] = [];
  if (unassigned.length > 0) {
    columns.push({ key: "unassigned", title: "Unassigned", notes: unassigned });
  }
  for (const stage of [...stages].sort((a, b) => a.position - b.position)) {
    columns.push({
      key: stage.id,
      title: stage.name,
      notes: notes.filter((n) => n.stageId === stage.id).sort((a, b) => a.stagePosition - b.stagePosition),
    });
  }
  return columns;
}

/** Pending rows first, then the done ones; capped unless [expanded]. */
export function checklistPreview(items: readonly ChecklistItem[], expanded: "full" | "preview"): { shown: ChecklistItem[]; hidden: number } {
  const ordered = [...items.filter((i) => !i.done), ...items.filter((i) => i.done)];
  if (expanded === "full" || ordered.length <= CHECKLIST_PREVIEW_ROWS) {
    return { shown: ordered, hidden: 0 };
  }
  return { shown: ordered.slice(0, CHECKLIST_PREVIEW_ROWS), hidden: ordered.length - CHECKLIST_PREVIEW_ROWS };
}
