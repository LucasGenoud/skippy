// Shared motion tokens (`util/motion.dart`), so every animation feels like one
// system. Durations stay short (nothing over SLOW = 250ms but the decorative
// celebration) and easing is always a cubic bezier, never linear.
//
// CSS: the same values live in globals.css as --motion-fast/base/slow and the
// Tailwind easings ease-emphasized / ease-standard / ease-back, so
// `duration-150 ease-standard` in a class is the FAST/standard pair here.

import type { Transition } from "motion/react";

/** Durations in milliseconds. */
export const DURATION = {
  /** Small state flips: hover, press, toggles, a check landing. */
  fast: 150,
  /** The workhorse: reflows, morphs, most transitions, overlay entrances. */
  base: 240,
  /** The ceiling, for larger entrances (view changes, staggered grids). */
  slow: 250,
  /** The one exception: the all-done burst, which nothing waits on. */
  celebration: 1100,
} as const;

export type Bezier = readonly [number, number, number, number];

/** Cubic-bezier control points, usable as a `motion` `ease`. */
export const EASE = {
  /** Material 3 emphasized: enter/exit, anything that grows or morphs. */
  emphasized: [0.2, 0, 0, 1],
  /** easeOutCubic: hovers, fades, moves in place. */
  standard: [0.215, 0.61, 0.355, 1],
  /** easeOutBack: a small overshoot for a check or swatch popping in. */
  back: [0.175, 0.885, 0.32, 1.275],
} as const satisfies Record<string, Bezier>;

/** A CSS `cubic-bezier()` for an easing. */
export function cssEase(ease: Bezier): string {
  return `cubic-bezier(${ease.join(", ")})`;
}

const MS_PER_S = 1000;
const seconds = (ms: number): number => ms / MS_PER_S;

/** `motion` transitions for the common cases. */
export const TRANSITION = {
  fast: { duration: seconds(DURATION.fast), ease: [...EASE.standard] },
  base: { duration: seconds(DURATION.base), ease: [...EASE.emphasized] },
  slow: { duration: seconds(DURATION.slow), ease: [...EASE.emphasized] },
  pop: { duration: seconds(DURATION.fast), ease: [...EASE.back] },
  /**
   * For motion that can be retargeted mid-flight (a dragged card settling):
   * critically damped, perceived as BASE long. A tween restarted midway jumps
   * in speed; a spring keeps the speed it has.
   */
  spring: { type: "spring", visualDuration: seconds(DURATION.base), bounce: 0 },
} as const satisfies Record<string, Transition>;

/** Overlays open with BASE/emphasized and close with FAST/standard. */
export const OVERLAY = { open: TRANSITION.base, close: TRANSITION.fast } as const;

const NO_MOTION: Transition = { duration: 0 };
const REDUCED_QUERY = "(prefers-reduced-motion: reduce)";

/** Whether the OS asks for reduced motion. False where there is no window. */
export function prefersReducedMotion(): boolean {
  if (typeof window === "undefined" || typeof window.matchMedia !== "function") {
    return false;
  }
  return window.matchMedia(REDUCED_QUERY).matches;
}

/**
 * The transition to use, or an instant one under reduced motion. Pass the
 * value of motion's `useReducedMotion()` from a component; omit it to read the
 * media query now.
 */
export function transitionFor(transition: Transition, reduced: boolean | null = prefersReducedMotion()): Transition {
  return reduced ? NO_MOTION : transition;
}
