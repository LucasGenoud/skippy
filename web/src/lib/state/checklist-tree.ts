import { MAX_ITEM_DEPTH, type ChecklistItem } from "@/lib/models/note";

// Pure rules for the shape of a nested checklist: a flat list whose rows carry
// a depth, so every parent/child rule is arithmetic over a sequence. Ported
// from `state/checklist_tree.dart`.

type Items = readonly ChecklistItem[];

const withDepth = (item: ChecklistItem, depth: number): ChecklistItem =>
  item.depth === depth ? item : { ...item, depth };

const withDone = (item: ChecklistItem, done: boolean): ChecklistItem => (item.done === done ? item : { ...item, done });

/** The deepest row [index] may sit: one below its predecessor, 0 for the first. */
export function maxDepthAt(items: Items, index: number): number {
  if (index <= 0) {
    return 0;
  }
  const above = items[index - 1]?.depth ?? 0;
  return Math.min(above + 1, MAX_ITEM_DEPTH);
}

/** [items] with every depth pulled into a drawable shape (server's rule). */
export function normalizeDepths(items: Items): readonly ChecklistItem[] {
  const result: ChecklistItem[] = [];
  items.forEach((item, i) => {
    const ceiling = i === 0 ? 0 : maxDepthAt(result, i);
    result.push(item.depth > ceiling ? withDepth(item, ceiling) : item);
  });
  return result;
}

/** One past the last row of the subtree rooted at [index]. */
export function subtreeEnd(items: Items, index: number): number {
  const depth = items[index]?.depth ?? 0;
  let end = index + 1;
  while (end < items.length && (items[end]?.depth ?? 0) > depth) {
    end++;
  }
  return end;
}

export function hasSubtasks(items: Items, index: number): boolean {
  return subtreeEnd(items, index) > index + 1;
}

/** The top-level row the one at [index] belongs to. */
export function rootIndexOf(items: Items, index: number): number {
  let i = index;
  while (i > 0 && (items[i]?.depth ?? 0) > 0) {
    i--;
  }
  return i;
}

/** Whether the row belongs in the checked section: it and its task are done. */
export function isFinished(items: Items, index: number): boolean {
  return Boolean(items[index]?.done) && Boolean(items[rootIndexOf(items, index)]?.done);
}

/** Set a row's checkbox, carrying its subtasks with it (both directions). */
export function setDoneCascading(items: Items, itemId: string, done: boolean): readonly ChecklistItem[] {
  const index = items.findIndex((item) => item.id === itemId);
  if (index < 0) {
    return items;
  }
  const end = subtreeEnd(items, index);
  return items.map((item, i) => (i >= index && i < end ? withDone(item, done) : item));
}

/** The row drawn directly above [index], skipping filed-away rows. */
export function viewPredecessor(items: Items, index: number): number | null {
  const finished = isFinished(items, index);
  for (let i = index - 1; i >= 0; i--) {
    if (isFinished(items, i) === finished) {
      return i;
    }
  }
  return null;
}

/** The deepest [index] may sit, judged by what is drawn above it. */
export function maxDepthInView(items: Items, index: number): number {
  const above = viewPredecessor(items, index);
  if (above === null) {
    return 0;
  }
  return Math.min((items[above]?.depth ?? 0) + 1, MAX_ITEM_DEPTH);
}

/** Lift the subtree at [index] over finished rows between it and its view predecessor. */
function closeGapAbove(items: Items, index: number): readonly ChecklistItem[] {
  const above = viewPredecessor(items, index);
  if (above === null || above === index - 1) {
    return items;
  }
  const end = subtreeEnd(items, index);
  const block = items.slice(index, end);
  const rest = [...items.slice(0, index), ...items.slice(end)];
  return [...rest.slice(0, above + 1), ...block, ...rest.slice(above + 1)];
}

function subtreeSpan(items: Items, index: number): number {
  const end = subtreeEnd(items, index);
  const root = items[index]?.depth ?? 0;
  let deepest = root;
  for (let i = index + 1; i < end; i++) {
    deepest = Math.max(deepest, items[i]?.depth ?? 0);
  }
  return deepest - root;
}

/** Whether the row can move one level in [delta]'s direction, subtasks and all. */
export function canShiftDepth(items: Items, itemId: string, delta: number): boolean {
  const index = items.findIndex((item) => item.id === itemId);
  if (index < 0 || delta === 0) {
    return false;
  }
  const target = (items[index]?.depth ?? 0) + delta;
  if (target < 0 || target > maxDepthInView(items, index)) {
    return false;
  }
  return target + subtreeSpan(items, index) <= MAX_ITEM_DEPTH;
}

/** Move a row one level in or out, with its subtasks. Disallowed moves return a copy. */
export function shiftDepth(items: Items, itemId: string, delta: number): readonly ChecklistItem[] {
  if (!canShiftDepth(items, itemId, delta)) {
    return items;
  }
  const closed = closeGapAbove(
    items,
    items.findIndex((item) => item.id === itemId),
  );
  const index = closed.findIndex((item) => item.id === itemId);
  const end = subtreeEnd(closed, index);
  return closed.map((item, i) => (i >= index && i < end ? withDepth(item, item.depth + delta) : item));
}

/** Remove one row, promoting whatever was nested under it. */
export function removeItem(items: Items, itemId: string): readonly ChecklistItem[] {
  const index = items.findIndex((item) => item.id === itemId);
  if (index < 0) {
    return items;
  }
  const end = subtreeEnd(items, index);
  const out: ChecklistItem[] = [];
  items.forEach((item, i) => {
    if (i === index) {
      return;
    }
    out.push(i > index && i < end ? withDepth(item, item.depth - 1) : item);
  });
  return normalizeDepths(out);
}

/** Move the subtree at [itemId] to start at [to] (counted without it). */
export function moveSubtree(items: Items, itemId: string, to: number): readonly ChecklistItem[] {
  const index = items.findIndex((item) => item.id === itemId);
  if (index < 0) {
    return items;
  }
  const end = subtreeEnd(items, index);
  const block = items.slice(index, end);
  const rest = [...items.slice(0, index), ...items.slice(end)];
  const target = Math.min(Math.max(to, 0), rest.length);
  return normalizeDepths([...rest.slice(0, target), ...block, ...rest.slice(target)]);
}

/** Reopen [itemId] and bring it to where it is being written ([after], or the end). */
export function reopenWhereWritten(items: Items, itemId: string, after?: string | null): readonly ChecklistItem[] {
  const index = items.findIndex((item) => item.id === itemId);
  if (index < 0) {
    return items;
  }
  const reopened = setDoneCascading(items, itemId, false);
  const end = subtreeEnd(reopened, index);
  const block = reopened.slice(index, end);
  const rest = [...reopened.slice(0, index), ...reopened.slice(end)];
  const anchor = after == null ? -1 : rest.findIndex((i) => i.id === after);
  const to = anchor < 0 ? rest.length : subtreeEnd(rest, anchor);
  const depth = anchor >= 0 ? (rest[anchor]?.depth ?? 0) : rest.length === 0 ? 0 : (rest[rest.length - 1]?.depth ?? 0);
  const shift = depth - (block[0]?.depth ?? 0);
  return normalizeDepths([
    ...rest.slice(0, to),
    ...block.map((item) => withDepth(item, Math.min(Math.max(item.depth + shift, 0), MAX_ITEM_DEPTH))),
    ...rest.slice(to),
  ]);
}
