// Ordered things (cards, columns, labels, collections, smart views) store a
// sparse `position` rather than an index, so a move rewrites only the item
// that moved:
//
//   1024     2048     3072          drop C between A and B
//    A        B        C       ->   A 1024, C 1536, B 2048

/** Spacing between neighbours placed at either end of a list. */
export const POSITION_GAP = 1024;

/** A position between [above] and [below]; [alone] when both are absent. */
export function positionBetween(above: number | null | undefined, below: number | null | undefined, alone = POSITION_GAP): number {
  const hasAbove = above !== null && above !== undefined;
  const hasBelow = below !== null && below !== undefined;
  if (!hasAbove && !hasBelow) {
    return alone;
  }
  if (!hasAbove) {
    return (below as number) - POSITION_GAP;
  }
  if (!hasBelow) {
    return above + POSITION_GAP;
  }
  return (above + below) / 2;
}

/**
 * The position for an item dropped at [index] among [others] (the other
 * items' positions, in order, without the moved one). [current] is kept when
 * there is nothing to order against.
 */
export function positionAt(others: readonly number[], index: number, current: number): number {
  const slot = Math.min(Math.max(index, 0), others.length);
  return positionBetween(slot > 0 ? others[slot - 1] : null, slot < others.length ? others[slot] : null, current);
}
