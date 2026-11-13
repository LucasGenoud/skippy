import type { Note, Stage } from "@/lib/models/note";
import { boardPositionForInsertion, boardPositionForReorder, type Board } from "@/lib/state/board-layout";

// Pure rules behind dragging on the board: which column a card is in while it
// is carried, what a drop writes, and which drops are allowed. Ported from the
// drag halves of `board_view.dart` and `board_column_view.dart`.

/** The Unassigned column's key; stage ids are uuids, so this never clashes. */
export const UNASSIGNED_KEY = "unassigned";

export const columnKeyOf = (stageId: string | null): string => stageId ?? UNASSIGNED_KEY;
export const stageIdOfKey = (key: string): string | null => (key === UNASSIGNED_KEY ? null : key);

/** One column as the board renders it: ids only, so a card owns its note. */
export interface ColumnIds {
  readonly key: string;
  readonly stage: Stage | null;
  readonly ids: readonly string[];
  readonly totalCount: number;
}

export function columnIdsOf(board: Board): ColumnIds[] {
  return board.columns.map((c) => ({ key: columnKeyOf(c.stage?.id ?? null), stage: c.stage, ids: c.notes.map((n) => n.id), totalCount: c.totalCount }));
}

/** Same columns (stage identity) holding the same ids in the same order. */
export function columnIdsEqual(a: readonly ColumnIds[], b: readonly ColumnIds[]): boolean {
  return (
    a === b ||
    (a.length === b.length &&
      a.every((col, i) => {
        const other = b[i];
        return other !== undefined && col.stage === other.stage && col.totalCount === other.totalCount && sameIds(col.ids, other.ids);
      }))
  );
}

function sameIds(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((id, i) => id === b[i]);
}

/** What a drag carries: the whole selection when the card is in it, else the card. */
export function draggedIdsFor(activeId: string, selectedIds: readonly string[]): readonly string[] {
  return selectedIds.includes(activeId) ? selectedIds : [activeId];
}

/** Column ids by key, the board's state while a card is in the air. */
export type DragColumns = Readonly<Record<string, readonly string[]>>;

export function dragColumnsOf(columns: readonly ColumnIds[]): DragColumns {
  return Object.fromEntries(columns.map((c) => [c.key, c.ids]));
}

export function containerOf(columns: DragColumns, id: string): string | null {
  for (const [key, ids] of Object.entries(columns)) {
    if (ids.includes(id)) {
      return key;
    }
  }
  return null;
}

/** [id] taken out of its column and put in [toKey] at [index] (clamped). */
export function moveToColumn(columns: DragColumns, id: string, toKey: string, index: number): DragColumns {
  const next: Record<string, readonly string[]> = {};
  for (const [key, ids] of Object.entries(columns)) {
    next[key] = ids.filter((x) => x !== id);
  }
  const target = [...(next[toKey] ?? [])];
  const slot = Math.max(0, Math.min(index, target.length));
  target.splice(slot, 0, id);
  next[toKey] = target;
  return next;
}

/** [ids] with the item at [from] moved to [to] (dnd-kit's arrayMove). */
export function moveWithin<T>(ids: readonly T[], from: number, to: number): T[] {
  const next = [...ids];
  const [item] = next.splice(from, 1);
  if (item === undefined) {
    return next;
  }
  next.splice(to, 0, item);
  return next;
}

/** One `setNoteStage` call; no position means the end of the column. */
export interface StageWrite {
  readonly noteId: string;
  readonly stageId: string | null;
  readonly position?: number;
}

export interface CardDrop {
  /** The card under the pointer. */
  readonly moved: Note;
  /** The card plus the rest of the selection it belongs to. */
  readonly draggedIds: readonly string[];
  readonly targetStageId: string | null;
  /** The target column's ids as shown at the drop, the moved card at its slot. */
  readonly shownIds: readonly string[];
  /** The target column's cards before the drag, in board order. */
  readonly before: readonly Note[];
  readonly noteById: (id: string) => Note | null;
}

/**
 * The writes a card drop makes. Within its own column the card gets one new
 * position, the midpoint between its neighbours, or nothing when its order
 * did not change. Arriving from another column it lands in the slot it was
 * shown in. Other selected cards follow it to the end of the column.
 */
export function planCardDrop(drop: CardDrop): StageWrite[] {
  const { moved, targetStageId, noteById } = drop;
  const writes: StageWrite[] = [];

  if (moved.stageId === targetStageId) {
    const after = drop.shownIds.map(noteById).filter((n): n is Note => n !== null);
    const position = boardPositionForReorder(moved, drop.before, after);
    if (position !== null && position !== moved.stagePosition) {
      writes.push({ noteId: moved.id, stageId: targetStageId, position });
    }
  } else {
    const here = new Set(drop.before.map((n) => n.id));
    const ordered = drop.shownIds
      .filter((id) => id === moved.id || here.has(id))
      .map((id) => (id === moved.id ? moved : noteById(id)))
      .filter((n): n is Note => n !== null);
    const position = boardPositionForInsertion(moved, ordered);
    writes.push(position === null ? { noteId: moved.id, stageId: targetStageId } : { noteId: moved.id, stageId: targetStageId, position });
  }

  for (const id of drop.draggedIds) {
    if (id === moved.id) {
      continue;
    }
    const note = noteById(id);
    if (!note || note.stageId === targetStageId) {
      continue;
    }
    writes.push({ noteId: id, stageId: targetStageId });
  }
  return writes;
}

/** A column chip lights up only when the drop would move something. */
export function canDropOnStage(notes: readonly (Note | null)[], stageId: string | null): boolean {
  return notes.some((n) => n !== null && n.stageId !== stageId);
}

export type BoardExitKind = "archive" | "trash";

/**
 * Archive and Trash take a drop only when every carried card can go there.
 * They keep the card's stage, so restoring it puts it back in its column.
 */
export function canDropOnExit(notes: readonly (Note | null)[], exit: BoardExitKind, canTrash: (id: string) => boolean): boolean {
  return notes.every((n) => n !== null && !n.archived && !n.trashed && (exit === "archive" || canTrash(n.id)));
}

/** How much of a column the selection covers. */
export type ColumnSelection = "none" | "some" | "all";

export function columnSelectionOf(ids: readonly string[], selected: ReadonlySet<string>): ColumnSelection {
  const count = ids.filter((id) => selected.has(id)).length;
  if (count === 0) {
    return "none";
  }
  return count === ids.length ? "all" : "some";
}

/** Which page of a paged board is showing, from the scroller's offset. */
export function pageAt(scrollLeft: number, pageWidth: number, pages: number): number {
  if (pageWidth <= 0 || pages <= 0) {
    return 0;
  }
  return Math.max(0, Math.min(pages - 1, Math.round(scrollLeft / pageWidth)));
}
