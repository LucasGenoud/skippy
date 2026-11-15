// Arrow-key focus between cards, by where they are drawn rather than by
// order: the grid packs into columns, the board lays out columns of its own,
// and both read naturally as "the card to the right", "the one below".
//
//   +----+ +----+          Right from A: the nearest column to the right,
//   | A  | | B  |          then the card in it closest to A's height (B).
//   +----+ |    |          Down from A: the nearest card below whose middle
//   +----+ +----+          is closest to A's (C), not D in the next column.
//   | C  | +----+
//   +----+ | D  |

export type FocusDirection = "left" | "right" | "up" | "down";

export interface CardBox {
  readonly left: number;
  readonly top: number;
  readonly right: number;
  readonly bottom: number;
}

export interface Candidate {
  readonly id: string;
  readonly box: CardBox;
}

/** Edges this close count as touching (sub-pixel layout, borders). */
const EDGE_TOLERANCE = 4;
/** Candidates this much further than the nearest are still "the next row or column". */
const BAND_SHARE = 0.5;

const DIRECTION_KEYS: Readonly<Record<string, FocusDirection>> = {
  ArrowLeft: "left",
  ArrowRight: "right",
  ArrowUp: "up",
  ArrowDown: "down",
};

/** Marks the element that receives a card's keyboard focus. */
export const CARD_FOCUS_ATTR = "data-card-focus";

/** The direction an arrow key asks for, or null for any other key. */
export function arrowDirection(key: string): FocusDirection | null {
  return DIRECTION_KEYS[key] ?? null;
}

function centre(box: CardBox): { x: number; y: number } {
  return { x: (box.left + box.right) / 2, y: (box.top + box.bottom) / 2 };
}

/** How far [box] lies in [direction] from [from]; negative when it does not. */
function travel(from: CardBox, box: CardBox, direction: FocusDirection): number {
  switch (direction) {
    case "right":
      return box.left - from.right;
    case "left":
      return from.left - box.right;
    case "down":
      return box.top - from.bottom;
    case "up":
      return from.top - box.bottom;
  }
}

/** How far off the line of travel [box] sits: none when the line runs through it. */
function offset(from: CardBox, box: CardBox, direction: FocusDirection): number {
  const mid = centre(from);
  const horizontal = direction === "left" || direction === "right";
  const at = horizontal ? mid.y : mid.x;
  const start = horizontal ? box.top : box.left;
  const end = horizontal ? box.bottom : box.right;
  return at < start ? start - at : at > end ? at - end : 0;
}

/**
 * The card to move to from [from]: among the cards in [direction], those in
 * the nearest row or column, and of those the one most in line.
 */
export function nearestInDirection(from: CardBox, candidates: readonly Candidate[], direction: FocusDirection): string | null {
  const ahead = candidates
    .map((c) => ({ id: c.id, travel: travel(from, c.box, direction), offset: offset(from, c.box, direction) }))
    .filter((c) => c.travel >= -EDGE_TOLERANCE);
  if (ahead.length === 0) {
    return null;
  }

  const nearest = Math.min(...ahead.map((c) => c.travel));
  const size = direction === "left" || direction === "right" ? from.right - from.left : from.bottom - from.top;
  const band = nearest + Math.max(EDGE_TOLERANCE, size * BAND_SHARE);
  let best: { id: string; offset: number; travel: number } | null = null;
  for (const c of ahead) {
    if (c.travel > band) {
      continue;
    }
    if (!best || c.offset < best.offset || (c.offset === best.offset && c.travel < best.travel)) {
      best = c;
    }
  }
  return best?.id ?? null;
}

/** The focusable faces of the cards drawn in [root], leaving cards and copies left out. */
function focusableCards(root: HTMLElement): HTMLElement[] {
  return Array.from(root.querySelectorAll<HTMLElement>(`[${CARD_FOCUS_ATTR}]`)).filter((el) => !el.closest("[aria-hidden='true']"));
}

/** Focuses the card [id] in [root], bringing it into view. */
export function focusCard(root: HTMLElement, id: string): boolean {
  const target = focusableCards(root).find((el) => el.getAttribute(CARD_FOCUS_ATTR) === id);
  if (!target) {
    return false;
  }
  target.focus({ preventScroll: true });
  target.scrollIntoView?.({ block: "nearest", inline: "nearest" });
  return true;
}

/** The card next to [card] in [direction], within [root]. */
export function neighbourOf(root: HTMLElement, card: HTMLElement, direction: FocusDirection): string | null {
  const from = card.getBoundingClientRect();
  const candidates = focusableCards(root)
    .filter((el) => el !== card)
    .map((el) => ({ id: el.getAttribute(CARD_FOCUS_ATTR) ?? "", box: el.getBoundingClientRect() }));
  return nearestInDirection(from, candidates, direction);
}

/**
 * Moves focus between the cards in [root] for an arrow key pressed on one of
 * them. True when it handled the key (the caller prevents the default).
 */
export function moveCardFocus(event: KeyboardEvent, root: HTMLElement): boolean {
  const direction = arrowDirection(event.key);
  const card = event.target instanceof HTMLElement ? event.target : null;
  if (!direction || !card?.hasAttribute(CARD_FOCUS_ATTR) || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) {
    return false;
  }
  const next = neighbourOf(root, card, direction);
  return next !== null && focusCard(root, next);
}

/** After [card] leaves (archived, trashed), the card focus should land on next. */
export function focusAfterLeaving(card: HTMLElement): void {
  const root = card.closest<HTMLElement>("[data-card-grid]");
  if (!root) {
    return;
  }
  const next = neighbourOf(root, card, "right") ?? neighbourOf(root, card, "down") ?? neighbourOf(root, card, "left") ?? neighbourOf(root, card, "up");
  if (next) {
    requestAnimationFrame(() => focusCard(root, next));
  }
}
