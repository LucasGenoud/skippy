import { cn } from "cn"

// Varied heights, so the placeholder reads as a masonry grid.
const HEIGHTS = [148, 96, 184, 120, 88, 156, 108, 132] as const
// Each tile pulses out of phase with its neighbours, so the shimmer sweeps.
const PHASE_STEP_S = 0.168

/**
 * The shimmering placeholder grid for a genuine cold load (no cache yet), so
 * the app fills in rather than showing a spinner.
 */
export function NotesSkeleton({ columns, className }: { columns: number; className?: string }) {
  const count = Math.max(1, columns)
  return (
    <div aria-busy aria-label="Loading notes" className={cn("flex items-start gap-2", className)}>
      {Array.from({ length: count }, (_, column) => (
        <div key={column} className="flex min-w-0 flex-1 flex-col gap-2">
          {HEIGHTS.map((height, index) =>
            index % count === column ? (
              <div
                key={index}
                className="animate-skeleton rounded-md bg-surface-container-highest"
                style={{ height, animationDelay: `${-index * PHASE_STEP_S}s` }}
              />
            ) : null,
          )}
        </div>
      ))}
    </div>
  )
}
