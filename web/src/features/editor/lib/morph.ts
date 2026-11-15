// The card-to-editor container transform (`editor_morph.dart`). The editor
// keeps its final layout throughout; only a transform and a clip change, so a
// morph never lays the editor out again per frame.
//
//   t = 0    +==== card ====+          box = card
//   t = 1       +---------+            box = editor
//               | editor  |            scale = box.width / editor.width
//               +---------+            clip  = box.height / scale

export interface Box {
  readonly left: number;
  readonly top: number;
  readonly width: number;
  readonly height: number;
}

export interface MorphFrame {
  /** CSS transform, applied with `transform-origin: 0 0`. */
  readonly transform: string;
  /** CSS clip-path cutting the editor to the box's height. */
  readonly clipPath: string;
}

/** A note card's corner (`rounded-lg`), where the morph starts. */
const CARD_RADIUS_PX = 10;
/** The editor panel's corner (`rounded-xl`), where it rests. */
const PANEL_RADIUS_PX = 12;

/** The resting frame: the editor exactly where it lays out, in its own corners. */
export const MORPH_REST: MorphFrame = { transform: "translate(0px, 0px) scale(1)", clipPath: `inset(0px 0px 0px 0px round ${PANEL_RADIUS_PX}px)` };

/** The frame where the editor ([target]) sits on [source], scaled to its width. */
export function morphFrom(source: Box, target: Box): MorphFrame | null {
  if (target.width <= 0 || target.height <= 0 || source.width <= 0 || source.height <= 0) {
    return null;
  }
  const scale = source.width / target.width;
  const visible = source.height / scale;
  const cut = Math.max(0, target.height - visible);
  const dx = source.left - target.left;
  const dy = source.top - target.top;
  return {
    transform: `translate(${round(dx)}px, ${round(dy)}px) scale(${round(scale, 4)})`,
    clipPath: `inset(0px 0px ${round(cut)}px 0px round ${round(CARD_RADIUS_PX / scale)}px)`,
  };
}

function round(value: number, places = 2): number {
  const f = 10 ** places;
  return Math.round(value * f) / f;
}

/** A box from a DOM rect. */
export function boxOf(rect: { left: number; top: number; width: number; height: number }): Box {
  return { left: rect.left, top: rect.top, width: rect.width, height: rect.height };
}

/** The card a note's editor grows out of, if it is on screen. Cards carry `data-note-card`. */
export function noteCardBox(noteId: string): Box | null {
  if (typeof document === "undefined") {
    return null;
  }
  const card = document.querySelector(`[data-note-card="${CSS.escape(noteId)}"]`);
  if (!card) {
    return null;
  }
  const rect = card.getBoundingClientRect();
  const offscreen = rect.bottom < 0 || rect.top > window.innerHeight || rect.width === 0;
  return offscreen ? null : boxOf(rect);
}
