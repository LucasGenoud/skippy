"use client"

import { useEffect, useRef, useState } from "react"
import { Check } from "lucide-react"
import { motion, useReducedMotion } from "motion/react"

import { DURATION, EASE } from "@/lib/theme/motion"

const PIECES = 24
const SAMPLES = 12
const MIN_FIELD = 160
const MAX_FIELD = 320
const FADE_FROM = 0.55
const COLORS = ["var(--primary)", "var(--tertiary)", "var(--secondary-tone)", "var(--primary-container)"] as const

interface Confetto {
  angle: number
  reach: number
  fall: number
  spin: number
  length: number
  thickness: number
  round: boolean
  color: string
}

function spawn(): Confetto[] {
  const jitter = (amount: number): number => (Math.random() - 0.5) * amount
  return Array.from({ length: PIECES }, (_, i) => ({
    // Fanned across the upper half, so pieces arc up and out before gravity
    // takes them: a throw, not an explosion.
    angle: Math.PI + (i / (PIECES - 1)) * Math.PI + jitter(0.25),
    reach: 0.55 + Math.random() * 0.75,
    fall: 0.6 + Math.random() * 0.8,
    spin: (Math.random() - 0.5) * 3,
    length: 5 + Math.random() * 4,
    thickness: 2 + Math.random() * 2,
    round: Math.random() < 0.5,
    color: COLORS[i % COLORS.length] ?? COLORS[0],
  }))
}

const easeOutCubic = (t: number): number => 1 - Math.pow(1 - t, 3)
const times = Array.from({ length: SAMPLES + 1 }, (_, i) => i / SAMPLES)

// The flight sampled into keyframes: outward travel eases off while gravity
// keeps accumulating, which bends each path into an arc.
function flight(piece: Confetto, field: number) {
  const half = field * 0.5
  return {
    x: times.map((t) => Math.cos(piece.angle) * piece.reach * half * easeOutCubic(t)),
    y: times.map((t) => Math.sin(piece.angle) * piece.reach * half * easeOutCubic(t) + piece.fall * half * t * t),
    rotate: times.map((t) => (piece.round ? 0 : piece.spin * t * 360)),
    opacity: times.map((t) => (t < FADE_FROM ? 1 : 1 - (t - FADE_FROM) / (1 - FADE_FROM))),
  }
}

/**
 * The flourish for finishing a checklist: confetti thrown over the list and a
 * short "All done" label in the middle. Plays once on mount, then calls
 * `onDone` so the caller can unmount it; remount (new key) to replay. Paints
 * over its positioned parent and never takes a pointer. Skipped under reduced
 * motion.
 */
export function AllDoneBurst({ onDone }: { onDone?: () => void }) {
  const reduced = useReducedMotion()
  const box = useRef<HTMLDivElement>(null)
  const [confetti] = useState(spawn)
  const [field, setField] = useState<number | null>(null)

  useEffect(() => {
    const rect = box.current?.getBoundingClientRect()
    const longest = rect ? Math.max(rect.width, rect.height) : MIN_FIELD
    setField(Math.min(MAX_FIELD, Math.max(MIN_FIELD, longest)))
  }, [])

  useEffect(() => {
    if (!onDone) {
      return
    }
    const timer = window.setTimeout(onDone, reduced ? 0 : DURATION.celebration)
    return () => window.clearTimeout(timer)
  }, [onDone, reduced])

  if (reduced) {
    return null
  }

  const seconds = DURATION.celebration / 1000
  return (
    <div ref={box} aria-hidden className="pointer-events-none absolute inset-0 z-10 flex items-center justify-center overflow-visible">
      {field === null
        ? null
        : confetti.map((piece, i) => (
            <motion.span
              key={i}
              className="absolute top-1/2 left-1/2"
              style={{
                width: piece.round ? piece.thickness * 2 : piece.thickness,
                height: piece.round ? piece.thickness * 2 : piece.length,
                marginLeft: -piece.thickness / 2,
                marginTop: -piece.length / 2,
                borderRadius: piece.round ? "50%" : piece.thickness / 2,
                background: piece.color,
              }}
              initial={{ x: 0, y: 0, opacity: 1 }}
              animate={flight(piece, field)}
              transition={{ duration: seconds, times, ease: "linear" }}
            />
          ))}
      <motion.span
        role="status"
        className="relative inline-flex items-center gap-1.5 rounded-md bg-primary-container px-3.5 py-2 text-sm font-semibold text-on-primary-container shadow-raised"
        initial={{ opacity: 0, scale: 0.7 }}
        animate={{ opacity: [0, 1, 1, 0], scale: [0.7, 1, 0.97, 0.94] }}
        transition={{ duration: seconds, times: [0, 0.1, 0.72, 1], ease: [[...EASE.back], "linear", [...EASE.standard]] }}
      >
        <Check className="size-[18px]" strokeWidth={2.5} />
        All done
      </motion.span>
    </div>
  )
}
