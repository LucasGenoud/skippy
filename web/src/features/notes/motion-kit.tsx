"use client";

import { useLayoutEffect, useRef, type CSSProperties, type ReactNode, type RefObject } from "react";
import { AnimatePresence, animate, motion, motionValue, useReducedMotion } from "motion/react";
import { cn } from "cn";

import { NotePattern } from "@/components/common/note-pattern";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";
import type { NotePatternId } from "@/lib/theme/patterns";

// Small motion pieces the notes, editor, board and reminders features share,
// each the web counterpart of a Flutter widget in `app/lib/widgets`.

/** Below this a height change is measurement noise, not a resize. */
const HEIGHT_EPSILON = 0.5;

/**
 * `AnimatedSize` for a box whose height is its content's: when [content]
 * changes height, [box] follows on a spring instead of jumping, and lets go
 * of its height once it rests. A change mid-glide retargets the spring, which
 * keeps its speed. The first measurement is taken as is.
 *
 * Only [box] is resized: [content] keeps its natural layout, so the hook can
 * read where the box is headed while it is still on its way.
 *
 *   content  +---------+          box  +---------+  height follows
 *            |  grew   |  --RO-->      |         |  on a spring
 *            |         |               +.........+  overflow clipped
 *            +---------+
 */
export function useFollowHeight(box: RefObject<HTMLElement | null>, content: RefObject<HTMLElement | null>, ready = true): void {
  const reduced = useReducedMotion() ?? false;
  const reducedRef = useRef(reduced);
  useLayoutEffect(() => {
    reducedRef.current = reduced;
  }, [reduced]);

  useLayoutEffect(() => {
    const el = box.current;
    const inner = content.current;
    if (!ready || !el || !inner || typeof ResizeObserver === "undefined") {
      return;
    }

    // What the box adds around the content (borders, padding), measured at rest.
    const chrome = el.offsetHeight - inner.offsetHeight;
    const shown = motionValue(el.offsetHeight);
    let target = el.offsetHeight;
    let following = false;
    let controls: { stop(): void } | null = null;

    const release = (): void => {
      following = false;
      controls = null;
      el.style.height = "";
    };
    const unsubscribe = shown.on("change", (value) => {
      if (following) {
        el.style.height = `${value}px`;
      }
    });

    const observer = new ResizeObserver(() => {
      const next = inner.offsetHeight + chrome;
      if (Math.abs(next - target) < HEIGHT_EPSILON) {
        return;
      }
      const from = following ? shown.get() : target;
      target = next;
      if (reducedRef.current || el.offsetParent === null) {
        controls?.stop();
        shown.jump(next);
        release();
        return;
      }
      if (!following) {
        // Hold the old height for this frame (the observer runs before paint), then glide.
        shown.jump(from);
        following = true;
        el.style.height = `${from}px`;
      }
      const glide = animate(shown, next, TRANSITION.spring);
      controls = glide;
      void glide.then(() => {
        if (following && Math.abs(shown.get() - target) < HEIGHT_EPSILON) {
          release();
        }
      });
    });
    observer.observe(inner);

    return () => {
      observer.disconnect();
      controls?.stop();
      unsubscribe();
      el.style.height = "";
    };
  }, [box, content, ready]);
}

/**
 * `StateCrossFade` for block content: when [stateKey] changes the old content
 * fades out while the new fades in, both on the same spot, neither travelling.
 * The slot is as tall as the taller of the two while they overlap.
 */
export function StateCrossFade({ stateKey, children, className, fast = true }: { stateKey: string | number | boolean; children: ReactNode; className?: string; fast?: boolean }) {
  const reduced = useReducedMotion();
  const transition = transitionFor(fast ? TRANSITION.fast : TRANSITION.base, reduced);
  return (
    <div className={cn("grid", className)}>
      <AnimatePresence initial={false}>
        <motion.div
          key={String(stateKey)}
          className="min-w-0 [grid-area:1/1]"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0, pointerEvents: "none" }}
          transition={transition}
        >
          {children}
        </motion.div>
      </AnimatePresence>
    </div>
  );
}

/**
 * A note's background pattern that cross-fades when it changes, rather than
 * one texture replacing another in a frame. "none" draws nothing at all, so a
 * plain card pays for no extra layer.
 */
export function FadingPattern({ pattern }: { pattern: NotePatternId }) {
  const reduced = useReducedMotion();
  return (
    <AnimatePresence initial={false}>
      {pattern !== "none" ? (
        <motion.div
          key={pattern}
          aria-hidden
          className="pointer-events-none absolute inset-0 rounded-[inherit]"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={transitionFor(TRANSITION.base, reduced)}
        >
          <NotePattern pattern={pattern} />
        </motion.div>
      ) : null}
    </AnimatePresence>
  );
}

/**
 * One row of an `AnimatedPresence` column: grows and fades in when it
 * arrives, shrinks and fades out when it leaves. Place inside AnimatePresence.
 * It clips only while it is resizing, so shadows and badges that reach past
 * its edges show once it rests.
 */
export function PresenceRow({ children, className, style }: { children: ReactNode; className?: string; style?: CSSProperties }) {
  const reduced = useReducedMotion();
  const ref = useRef<HTMLDivElement | null>(null);
  const clip = (on: boolean): void => {
    if (ref.current) {
      ref.current.style.overflow = on ? "hidden" : "";
    }
  };
  return (
    <motion.div
      ref={ref}
      className={className}
      style={style}
      initial={{ height: 0, opacity: 0 }}
      animate={{ height: "auto", opacity: 1, transition: transitionFor(TRANSITION.base, reduced) }}
      exit={{ height: 0, opacity: 0, transition: transitionFor(TRANSITION.fast, reduced) }}
      onAnimationStart={() => clip(true)}
      onAnimationComplete={(definition) => clip(typeof definition === "object" && definition !== null && "height" in definition && definition.height === 0)}
    >
      {children}
    </motion.div>
  );
}
