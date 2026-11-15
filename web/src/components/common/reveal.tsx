"use client"

import type { ReactNode } from "react"
import { AnimatePresence, motion, useReducedMotion } from "motion/react"

import { TRANSITION, transitionFor } from "@/lib/theme/motion"

/**
 * Shows `children`, or nothing when null, growing and fading in and out rather
 * than shoving what sits below in one frame (`AnimatedReveal`). For a row that
 * comes and goes under a form or list: an error line, a probe result. Keyed on
 * presence only, so new content updates in place. Not for long lists.
 */
export function Reveal({ children }: { children: ReactNode }) {
  const reduced = useReducedMotion()
  const transition = transitionFor(TRANSITION.base, reduced)
  return (
    <AnimatePresence initial={false}>
      {children ? (
        <motion.div
          key="reveal"
          initial={{ height: 0, opacity: 0 }}
          animate={{ height: "auto", opacity: 1 }}
          exit={{ height: 0, opacity: 0 }}
          transition={transition}
          style={{ overflow: "hidden" }}
        >
          {children}
        </motion.div>
      ) : null}
    </AnimatePresence>
  )
}

/**
 * Cross-fades between states of one slot (`StateCrossFade`): pass a `stateKey`
 * that changes when the content should swap. The two never travel, so a
 * control trading places with another stays on its spot.
 */
export function CrossFade({
  stateKey,
  children,
  className,
}: {
  stateKey: string | number | boolean
  children: ReactNode
  className?: string
}) {
  const reduced = useReducedMotion()
  const transition = transitionFor(TRANSITION.fast, reduced)
  return (
    <span className={className} style={{ display: "inline-grid" }}>
      <AnimatePresence initial={false}>
        <motion.span
          key={String(stateKey)}
          initial={{ opacity: 0, scale: 0.96 }}
          animate={{ opacity: 1, scale: 1 }}
          exit={{ opacity: 0, scale: 0.96 }}
          transition={transition}
          style={{ gridArea: "1 / 1", display: "inline-flex", alignItems: "center" }}
        >
          {children}
        </motion.span>
      </AnimatePresence>
    </span>
  )
}
