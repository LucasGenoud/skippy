// The pure half of the animated masonry: packing cards into columns, and
// reading a drag pointer back into a new order. Ported from `AnimatedMasonry`
// in `widgets/masonry.dart`.
//
//   columns = 3, spacing = 8
//   ┌────┐ ┌────┐ ┌────┐
//   │ a  │ │ b  │ │ c  │      each card goes to the shortest column
//   └────┘ │    │ └────┘      (spanning cards to the lowest run of
//   ┌───────────┐ ┌────┐       `span` adjacent columns)
//   │  d (2)    │ │ e  │
//   └───────────┘ └────┘

/** A card nobody has measured yet is laid out at this height. */
export const ESTIMATED_CARD_HEIGHT = 120;

/** Columns closer than this are treated as level, so ties go left. */
const LEVEL_TOLERANCE = 0.5;

export interface MasonrySlot {
  readonly x: number;
  readonly y: number;
  readonly width: number;
}

export interface MasonryLayout {
  readonly slots: ReadonlyMap<string, MasonrySlot>;
  readonly columnWidth: number;
  readonly totalHeight: number;
}

export interface PackInput {
  readonly order: readonly string[];
  /** Grid span per id (1..3); missing ids span one column. */
  readonly spans: ReadonlyMap<string, number>;
  readonly heights: ReadonlyMap<string, number>;
  readonly columns: number;
  readonly spacing: number;
  readonly width: number;
}

const heightOf = (heights: ReadonlyMap<string, number>, id: string): number => heights.get(id) ?? ESTIMATED_CARD_HEIGHT;

export function packMasonry({ order, spans, heights, columns, spacing, width }: PackInput): MasonryLayout {
  const cols = Math.max(1, columns);
  const columnWidth = Math.max(0, (width - spacing * (cols - 1)) / cols);
  const columnHeights = new Array<number>(cols).fill(0);
  const slots = new Map<string, MasonrySlot>();

  for (const id of order) {
    const span = Math.min(Math.max(1, spans.get(id) ?? 1), cols);
    let col = 0;
    let y = Number.POSITIVE_INFINITY;
    for (let start = 0; start <= cols - span; start++) {
      const top = Math.max(...columnHeights.slice(start, start + span));
      if (top < y - LEVEL_TOLERANCE) {
        col = start;
        y = top;
      }
    }
    const cardWidth = columnWidth * span + spacing * (span - 1);
    slots.set(id, { x: col * (columnWidth + spacing), y, width: cardWidth });
    const bottom = y + heightOf(heights, id) + spacing;
    for (let c = col; c < col + span; c++) {
      columnHeights[c] = bottom;
    }
  }

  const total = Math.max(0, ...columnHeights);
  return { slots, columnWidth, totalHeight: total <= 0 ? 0 : total - spacing };
}

export interface DragTarget {
  readonly order: readonly string[];
  readonly layout: MasonryLayout;
  readonly heights: ReadonlyMap<string, number>;
  /** Every card being carried (a multi-selection moves together). */
  readonly dragging: ReadonlySet<string>;
  /** The card under the pointer. */
  readonly draggingId: string;
  readonly gridWidth: number;
}

/**
 * The order with the carried cards moved to the card under [point] (grid
 * coordinates), or null when the pointer is over no card. Below the last
 * card, inside the grid's width, means "at the end".
 */
export function orderAtPoint(target: DragTarget, point: { x: number; y: number }): string[] | null {
  const { order, layout, heights, dragging, draggingId, gridWidth } = target;
  let targetId: string | null = null;
  for (const id of order) {
    if (dragging.has(id)) {
      continue;
    }
    const slot = layout.slots.get(id);
    if (!slot) {
      continue;
    }
    const height = heightOf(heights, id);
    if (point.x >= slot.x && point.x < slot.x + slot.width && point.y >= slot.y && point.y < slot.y + height) {
      targetId = id;
      break;
    }
  }

  const atEnd = targetId === null && point.y > layout.totalHeight && point.x >= 0 && point.x <= gridWidth;
  if (targetId === null && !atEnd) {
    return null;
  }

  const from = order.indexOf(draggingId);
  const moving = order.filter((id) => dragging.has(id));
  const remaining = order.filter((id) => !dragging.has(id));
  let insertAt = remaining.length;
  if (targetId !== null) {
    const targetIndex = order.indexOf(targetId);
    insertAt = remaining.indexOf(targetId) + (targetIndex > from ? 1 : 0);
  }
  return [...remaining.slice(0, insertAt), ...moving, ...remaining.slice(insertAt)];
}

/** Whether two orders hold the same ids in the same places. */
export function sameOrder(a: readonly string[] | null, b: readonly string[] | null): boolean {
  if (a === b) {
    return true;
  }
  if (!a || !b || a.length !== b.length) {
    return false;
  }
  return a.every((id, i) => id === b[i]);
}

/** Whether two orders hold the same ids, in any order. */
export function sameMembers(a: readonly string[], b: readonly string[]): boolean {
  if (a.length !== b.length) {
    return false;
  }
  const set = new Set(a);
  return b.every((id) => set.has(id));
}

/**
 * The order to show while a drag is in progress and the source list changes
 * underneath it (a collaborator's edit): keep the dragged order, drop what
 * left, append what arrived.
 */
export function mergeDuringDrag(current: readonly string[], incoming: readonly string[]): string[] {
  const keep = new Set(incoming);
  const existing = new Set(current);
  return [...current.filter((id) => keep.has(id)), ...incoming.filter((id) => !existing.has(id))];
}

export interface GridMetrics {
  /** Gutter either side. */
  readonly pad: number;
  /** The widest the cards may spread. */
  readonly maxWidth: number;
  readonly columns: number;
}

const WIDE_GUTTER_FROM = 900;
const WIDE_GUTTER = 32;
const NARROW_GUTTER = 16;
const LIST_MAX_WIDTH = 600;
const MIN_COLUMNS = 2;

/**
 * How the grid fills [width]: a wider gutter on a roomy window, cards capped
 * at the chosen grid width (one readable column in list mode), and as many
 * columns as fit the density's card width (`_gridMetrics` in home_screen).
 */
export function gridMetrics(
  width: number,
  density: { readonly targetWidth: number; readonly maxColumns: number },
  gridMaxWidth: number,
  layout: "masonry" | "list",
): GridMetrics {
  const pad = width >= WIDE_GUTTER_FROM ? WIDE_GUTTER : NARROW_GUTTER;
  const maxWidth = layout === "list" ? LIST_MAX_WIDTH : gridMaxWidth;
  const usable = Math.min(width - pad * 2, maxWidth);
  const columns = layout === "list" ? 1 : Math.min(Math.max(Math.floor(usable / density.targetWidth), MIN_COLUMNS), density.maxColumns);
  return { pad, maxWidth, columns };
}

/** Ids whose slot overlaps the band [top, bottom] (grid coordinates). */
export function idsInBand(order: readonly string[], layout: MasonryLayout, heights: ReadonlyMap<string, number>, top: number, bottom: number): Set<string> {
  const out = new Set<string>();
  for (const id of order) {
    const slot = layout.slots.get(id);
    if (slot && slot.y <= bottom && slot.y + heightOf(heights, id) >= top) {
      out.add(id);
    }
  }
  return out;
}
