"use client"

import { useState } from "react"
import { AnimatePresence, motion, useReducedMotion } from "motion/react"
import { cn } from "cn"

import { TRANSITION } from "@/lib/theme/motion"

// The roll direction: up when counting up, down when counting down.
type Direction = 1 | -1

const digitVariants = {
  enter: (direction: Direction) => ({ y: `${direction * 100}%`, opacity: 0 }),
  center: { y: "0%", opacity: 1 },
  exit: (direction: Direction) => ({ y: `${-direction * 100}%`, opacity: 0 }),
}

/**
 * A number that rolls to its new value like an odometer. Only changed digits
 * move; a digit gained or lost opens or closes its slot in step, so the width
 * never jumps. Digits are tabular, so a roll never nudges its neighbours.
 */
export function RollingCount({ count, className }: { count: number; className?: string }) {
  const reduced = useReducedMotion()
  const [previous, setPrevious] = useState(count)
  const [direction, setDirection] = useState<Direction>(1)
  if (count !== previous) {
    setDirection(count > previous ? 1 : -1)
    setPrevious(count)
  }

  const digits = String(count).split("")
  if (reduced) {
    return <span className={cn("tabular-nums", className)}>{count}</span>
  }

  return (
    <span className={cn("inline-flex tabular-nums", className)} aria-label={String(count)} role="img">
      <AnimatePresence initial={false} custom={direction}>
        {digits.map((digit, index) => {
          // Slots are keyed from the right, so the ones digit keeps its slot
          // when a tens digit arrives.
          const slot = digits.length - index
          return (
            <motion.span
              key={slot}
              aria-hidden
              className="relative inline-flex overflow-hidden"
              initial={{ width: 0 }}
              animate={{ width: "auto" }}
              exit={{ width: 0 }}
              transition={TRANSITION.base}
            >
              <AnimatePresence initial={false} custom={direction} mode="popLayout">
                <motion.span
                  key={digit}
                  custom={direction}
                  variants={digitVariants}
                  initial="enter"
                  animate="center"
                  exit="exit"
                  transition={TRANSITION.base}
                  className="inline-block"
                >
                  {digit}
                </motion.span>
              </AnimatePresence>
            </motion.span>
          )
        })}
      </AnimatePresence>
    </span>
  )
}
