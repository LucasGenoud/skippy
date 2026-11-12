"use client";

import type { ReactNode } from "react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";

/** Rows that collapse when revoked and grow in when added, instead of jumping. */
export function RevocableList<T>({ items, keyOf, children }: { items: readonly T[]; keyOf: (item: T) => string; children: (item: T) => ReactNode }) {
  const reduced = useReducedMotion();
  const transition = transitionFor(TRANSITION.base, reduced);
  return (
    <ul className="flex flex-col">
      <AnimatePresence initial={false}>
        {items.map((item) => (
          <motion.li
            key={keyOf(item)}
            initial={{ opacity: 0, height: 0 }}
            animate={{ opacity: 1, height: "auto" }}
            exit={{ opacity: 0, height: 0 }}
            transition={transition}
            className="overflow-hidden"
          >
            {children(item)}
          </motion.li>
        ))}
      </AnimatePresence>
    </ul>
  );
}

/** A dense row inside a section's list: icon, title, meta, actions. */
export function DenseRow({ icon, title, meta, actions }: { icon: ReactNode; title: string; meta: string; actions: ReactNode }) {
  return (
    <div className="flex items-center gap-3 rounded-md py-1.5 pr-1 pl-12 transition-colors duration-150 ease-standard hover:bg-hover">
      <span className="text-on-surface-variant [&_svg]:size-4">{icon}</span>
      <span className="flex min-w-0 flex-1 flex-col">
        <span className="truncate text-sm text-on-surface">{title}</span>
        <span className="truncate text-xs text-on-surface-variant">{meta}</span>
      </span>
      {actions}
    </div>
  );
}
