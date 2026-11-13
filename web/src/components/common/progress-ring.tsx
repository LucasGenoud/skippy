import { cn } from "cn"

const RING_SIZE = 13
const STROKE = 1.6

/**
 * How far through its tasks a checklist is: a ring that fills as items are
 * checked, and "3/5" beside it. The accent tone marks a finished list.
 */
export function ProgressRing({ done, total, className }: { done: number; total: number; className?: string }) {
  if (total <= 0) {
    return null
  }
  const complete = done >= total
  const radius = (RING_SIZE - STROKE) / 2
  const circumference = 2 * Math.PI * radius
  const fraction = Math.min(1, Math.max(0, done / total))
  return (
    <span
      role="img"
      aria-label={`${done} of ${total} tasks done`}
      className={cn(
        "inline-flex items-center gap-1 text-2xs tabular-nums",
        complete ? "text-primary" : "text-on-surface-variant",
        className,
      )}
    >
      <svg width={RING_SIZE} height={RING_SIZE} viewBox={`0 0 ${RING_SIZE} ${RING_SIZE}`} className="-rotate-90">
        <circle cx={RING_SIZE / 2} cy={RING_SIZE / 2} r={radius} fill="none" strokeWidth={STROKE} className="stroke-on-surface-variant/35" />
        <circle
          cx={RING_SIZE / 2}
          cy={RING_SIZE / 2}
          r={radius}
          fill="none"
          stroke="currentColor"
          strokeWidth={STROKE}
          strokeLinecap="round"
          strokeDasharray={circumference}
          strokeDashoffset={circumference * (1 - fraction)}
          opacity={fraction > 0 ? 1 : 0}
          className="transition-[stroke-dashoffset] duration-240 ease-standard"
        />
      </svg>
      <span aria-hidden>
        {done}/{total}
      </span>
    </span>
  )
}
