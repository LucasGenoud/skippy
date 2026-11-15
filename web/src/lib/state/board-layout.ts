import type { Label, Note, Stage } from "@/lib/models/note";
import { filtersOnly, parseSearchQuery, queryMatches, searchContext } from "@/lib/util/search-query";
import { ALL_SCOPE, scopeContains, type SortMode, type WorkspaceScope } from "./note-collection";
import { positionBetween } from "./sparse-position";

// Groups notes into board columns. Ported from `state/board_layout.dart`. A
// note's column is its stageId and nothing else; labels play no part.

/** One column: a stage (null for unassigned) and its cards in board order. */
export interface BoardColumn {
  readonly stage: Stage | null;
  readonly notes: readonly Note[];
  /** Cards the column holds; more than notes.length only when capped. */
  readonly totalCount: number;
}

export const isUnassignedColumn = (c: BoardColumn): boolean => c.stage === null;
export const hiddenCount = (c: BoardColumn): number => c.totalCount - c.notes.length;
export const columnTitle = (c: BoardColumn): string => c.stage?.name ?? "Unassigned";

export interface Board {
  readonly columns: readonly BoardColumn[];
}

/** True when the collection has no stages at all. */
export const boardHasNoStages = (b: Board): boolean => b.columns.every(isUnassignedColumn);
export const boardIsEmpty = (b: Board): boolean => b.columns.every((c) => c.notes.length === 0) && boardHasNoStages(b);

/** How many unassigned cards show before collapsing the rest behind a count. */
export const UNASSIGNED_PREVIEW_LIMIT = 20;

export interface BuildBoardInput {
  readonly notes: Iterable<Note>;
  readonly stages: Iterable<Stage>;
  readonly scope?: WorkspaceScope;
  readonly query?: string;
  /** Only to resolve `label:` terms in [query]. */
  readonly labels?: Iterable<Label>;
  readonly sortMode?: SortMode;
  readonly showAllUnassigned?: boolean;
  /** Semantic ranking narrows the board; filters still apply. */
  readonly rankedIds?: ReadonlySet<string> | null;
}

export function buildBoard(input: BuildBoardInput): Board {
  const scope = input.scope ?? ALL_SCOPE;
  const sortMode = input.sortMode ?? "custom";
  const rankedIds = input.rankedIds ?? null;
  const all = parseSearchQuery(input.query ?? "");
  const parsed = rankedIds === null ? all : filtersOnly(all);
  const context = searchContext(input.labels ?? []);
  const ordered = [...input.stages].sort((a, b) => a.position - b.position);
  const known = new Set(ordered.map((s) => s.id));

  const unassigned: Note[] = [];
  const buckets = new Map<string, Note[]>(ordered.map((s) => [s.id, []]));
  for (const note of input.notes) {
    if (note.archived || note.trashed || !scopeContains(scope, note)) {
      continue;
    }
    if (rankedIds !== null && !rankedIds.has(note.id)) {
      continue;
    }
    if (!queryMatches(parsed, note, context)) {
      continue;
    }
    // A stage the client has not caught up on reads as unassigned.
    const bucket = note.stageId !== null && known.has(note.stageId) ? buckets.get(note.stageId) : undefined;
    (bucket ?? unassigned).push(note);
  }

  const compare = (a: Note, b: Note): number => compareCards(a, b, sortMode);
  unassigned.sort(compare);
  for (const bucket of buckets.values()) {
    bucket.sort(compare);
  }
  const capped = input.showAllUnassigned || unassigned.length <= UNASSIGNED_PREVIEW_LIMIT ? unassigned : unassigned.slice(0, UNASSIGNED_PREVIEW_LIMIT);

  return {
    columns: [
      { stage: null, notes: capped, totalCount: unassigned.length },
      ...ordered.map((stage) => {
        const notes = buckets.get(stage.id) ?? [];
        return { stage, notes, totalCount: notes.length };
      }),
    ],
  };
}

/**
 * The sparse stage position for a card reordered within one column, or null
 * when it did not change order within its pin group.
 */
export function boardPositionForReorder(moved: Note, before: Iterable<Note>, after: Iterable<Note>): number | null {
  const beforePeers = orderingPeers(moved, before);
  const afterPeers = orderingPeers(moved, after);
  const beforeIds = beforePeers.map((n) => n.id);
  const afterIds = afterPeers.map((n) => n.id);
  const beforeSet = new Set(beforeIds);
  if (beforeIds.length !== afterIds.length || !afterIds.every((id) => beforeSet.has(id)) || sameOrder(beforeIds, afterIds)) {
    return null;
  }
  return positionOf(moved.id, afterPeers);
}

/** The sparse stage position for [moved] inserted into [ordered] at its slot. */
export function boardPositionForInsertion(moved: Note, ordered: Iterable<Note>): number | null {
  return positionOf(moved.id, orderingPeers(moved, ordered));
}

function orderingPeers(moved: Note, notes: Iterable<Note>): Note[] {
  return [...notes].filter((n) => n.pinned === moved.pinned);
}

function positionOf(movedId: string, peers: readonly Note[]): number | null {
  const index = peers.findIndex((n) => n.id === movedId);
  if (index === -1) {
    return null;
  }
  const above = index > 0 ? peers[index - 1] : undefined;
  const below = index + 1 < peers.length ? peers[index + 1] : undefined;
  return positionBetween(above?.stagePosition, below?.stagePosition);
}

function sameOrder(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((id, i) => id === b[i]);
}

/** Pinned cards ride at the top of their column; each group follows the sort. */
function compareCards(a: Note, b: Note, sortMode: SortMode): number {
  if (a.pinned !== b.pinned) {
    return a.pinned ? -1 : 1;
  }
  switch (sortMode) {
    case "custom":
      return a.stagePosition - b.stagePosition;
    case "edited":
      return b.updatedAt.getTime() - a.updatedAt.getTime();
    case "newest":
      return b.createdAt.getTime() - a.createdAt.getTime();
    case "oldest":
      return a.createdAt.getTime() - b.createdAt.getTime();
  }
}
