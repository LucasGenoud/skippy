"use client";

import { useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { motion, useReducedMotion } from "motion/react";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";

/**
 * Animates its height to fit its content (`AnimatedSize`), so swapping one
 * state of a card for another grows or shrinks the card instead of jumping.
 */
export function AutoHeight({ children }: { children: ReactNode }) {
  const inner = useRef<HTMLDivElement>(null);
  const [height, setHeight] = useState<number | "auto">("auto");
  const reduced = useReducedMotion();

  useLayoutEffect(() => {
    const element = inner.current;
    if (!element || typeof ResizeObserver === "undefined") {
      return;
    }
    const observer = new ResizeObserver(() => setHeight(element.offsetHeight));
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  return (
    <motion.div initial={false} animate={{ height }} transition={transitionFor(TRANSITION.base, reduced)} style={{ overflow: "hidden" }}>
      <div ref={inner}>{children}</div>
    </motion.div>
  );
}
