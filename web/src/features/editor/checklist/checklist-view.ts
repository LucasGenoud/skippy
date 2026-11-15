import type { ChecklistItem } from "@/lib/models/note";
import { canShiftDepth, isFinished, normalizeDepths, rootIndexOf, shiftDepth } from "@/lib/state/checklist-tree";

// How the checklist editor arranges a flat list of rows on screen
// (`animated_checklist.dart`). Pure, so the rules the widget follows can be
// tested without one.
//
//   unchecked rows (open tasks, with any subtasks ticked under them)
//   composer       where the next row is written
//   N checked      finished tasks, subtasks and all, folded away

type Items = readonly ChecklistItem[];

/** How far one nesting level moves a row, in px. */
export const INDENT_STEP = 24;

/**
 * Rows that belong in the checked section: finished, unless the task they
 * belong to is still being held in place after its tick ([held]).
 */
export function checkedRows(items: Items, held: ReadonlySet<string>): ChecklistItem[] {
  const out: ChecklistItem[] = [];
  items.forEach((item, i) => {
    const root = items[rootIndexOf(items, i)];
    if (isFinished(items, i) && !(root && held.has(root.id))) {
      out.push(item);
    }
  });
  return out;
}

/** The unchecked rows in list order, without the one the composer is writing. */
export function uncheckedIds(items: Items, checked: ReadonlySet<string>, composingId: string | null): string[] {
  return items.filter((item) => !checked.has(item.id) && item.id !== composingId).map((item) => item.id);
}

/** The rows a drag carries: [id] and whatever is nested under it in [order]. */
export function blockFor(order: readonly string[], byId: ReadonlyMap<string, ChecklistItem>, id: string): string[] {
  const start = order.indexOf(id);
  if (start < 0) {
    return [id];
  }
  const depth = byId.get(id)?.depth ?? 0;
  const block = [id];
  for (let i = start + 1; i < order.length; i++) {
    const next = byId.get(order[i] ?? "");
    if (!next || next.depth <= depth) {
      break;
    }
    block.push(next.id);
  }
  return block;
}

/**
 * The list after dropping [activeId]'s subtree where [overId] stood among the
 * rows on screen during the drag (the dragged row's children hidden), nested
 * [depthDelta] levels further in or out where the rules allow it.
 */
export function dropBlock(
  items: Items,
  options: {
    order: readonly string[];
    composingId: string | null;
    checked: Items;
    activeId: string;
    overId: string | null;
    depthDelta: number;
  },
): readonly ChecklistItem[] {
  const byId = new Map(items.map((item) => [item.id, item]));
  const block = blockFor(options.order, byId, options.activeId);
  const visible = options.order.filter((id) => id === options.activeId || !block.includes(id));
  const from = visible.indexOf(options.activeId);
  const to = options.overId === null ? from : visible.indexOf(options.overId);
  if (from < 0 || to < 0) {
    return items;
  }
  const moved = [...visible];
  moved.splice(from, 1);
  moved.splice(to, 0, options.activeId);
  const expanded = moved.flatMap((id) => (id === options.activeId ? block : [id]));
  const composing = options.composingId === null ? undefined : byId.get(options.composingId);
  const reordered = [
    ...expanded.map((id) => byId.get(id)).filter((item): item is ChecklistItem => item !== undefined),
    ...(composing ? [composing] : []),
    ...options.checked,
  ];
  let result: readonly ChecklistItem[] = normalizeDepths(reordered);
  const step = Math.sign(options.depthDelta);
  for (let i = 0; i < Math.abs(options.depthDelta); i++) {
    if (!canShiftDepth(result, options.activeId, step)) {
      break;
    }
    result = shiftDepth(result, options.activeId, step);
  }
  return result;
}

/** Whether two lists hold the same rows in the same order and shape. */
export function sameRows(a: Items, b: Items): boolean {
  return a.length === b.length && a.every((item, i) => item.id === b[i]?.id && item.depth === b[i]?.depth);
}

/** Whether ticking [item] leaves nothing unchecked. Unticking never does. */
export function completesList(items: Items, item: ChecklistItem): boolean {
  if (item.done) {
    return false;
  }
  return items.every((other) => other.done || other.id === item.id);
}

/**
 * Texts already active on the list, which a suggestion would only duplicate.
 * A checked-off row is not active: offering it back is the point of history.
 */
export function activeTexts(items: Items, except: string | null = null): string[] {
  return items.filter((item) => !item.done && item.id !== except && item.text.trim() !== "").map((item) => item.text);
}

/** Ids of rows whose text contains [query] (find in note). */
export function matchingRows(items: Items, query: string): string[] {
  const needle = query.trim().toLowerCase();
  if (!needle) {
    return [];
  }
  return items.filter((item) => item.text.toLowerCase().includes(needle)).map((item) => item.id);
}

/** Rows without whitespace-only ones, for the final save when the editor closes. */
export function prunedRows(items: Items): readonly ChecklistItem[] | null {
  const kept = items.filter((item) => item.text.trim() !== "");
  return kept.length === items.length ? null : kept;
}

export type RowKeyAction =
  | { readonly kind: "indent"; readonly delta: 1 | -1 }
  | { readonly kind: "outdentEmpty" }
  | { readonly kind: "removeEmpty" }
  | { readonly kind: "insertAfter" }
  | { readonly kind: "none" };

/**
 * What a key in a row asks for. Tab nests (Shift+Tab un-nests) and is always
 * taken, so a refused indent never moves focus; Enter continues the list;
 * Backspace on an empty row brings a subtask out a level, else removes it.
 */
export function rowKeyAction(key: { key: string; shiftKey: boolean; isComposing?: boolean }, rowText: string, depth: number): RowKeyAction {
  if (key.isComposing) {
    return { kind: "none" };
  }
  if (key.key === "Tab") {
    return { kind: "indent", delta: key.shiftKey ? -1 : 1 };
  }
  if (key.key === "Enter" && !key.shiftKey) {
    return { kind: "insertAfter" };
  }
  if (key.key === "Backspace" && rowText === "") {
    return depth > 0 ? { kind: "outdentEmpty" } : { kind: "removeEmpty" };
  }
  return { kind: "none" };
}
