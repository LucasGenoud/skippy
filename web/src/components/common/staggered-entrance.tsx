"use client"

import type { ReactNode } from "react"
import { motion, useIsPresent, useReducedMotion } from "motion/react"
import { cn } from "cn"

import { DURATION, EASE, TRANSITION } from "@/lib/theme/motion"

/** Delay between one row and the next, and the most any row waits. */
const STAGGER_MS = 28
const STAGGER_CAP_MS = 200
/** How far a row rises as it lands (Flutter slides a tenth of the row). */
const RISE_PX = 6

const MS_PER_S = 1000

/**
 * Cascades a short list's rows in on mount (`StaggeredEntrance`): each row
 * fades and rises a little, offset by [index] so they do not all land at
 * once. For dialog-sized lists (a handful of rows), not the note grid.
 *
 * Inside an `AnimatePresence`, a removed row also folds away: it fades and
 * its height closes over BASE instead of the rows below jumping up.
 */
export function StaggeredEntrance({ index, children, className }: { index: number; children: ReactNode; className?: string }) {
  const reduced = useReducedMotion()
  const present = useIsPresent()
  const delay = Math.min(index * STAGGER_MS, STAGGER_CAP_MS) / MS_PER_S

  if (reduced) {
    return <div className={className}>{children}</div>
  }
  return (
    <motion.div
      className={cn(!present && "overflow-hidden", className)}
      initial={{ opacity: 0, y: RISE_PX }}
      animate={{
        opacity: 1,
        y: 0,
        transition: {
          y: { ...TRANSITION.base, delay },
          opacity: { duration: DURATION.base / MS_PER_S, ease: [...EASE.standard], delay },
        },
      }}
      exit={{ opacity: 0, height: 0, transition: TRANSITION.base }}
    >
      {children}
    </motion.div>
  )
}
