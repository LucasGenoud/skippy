import type { ReactNode } from "react"
import { cn } from "cn"

/**
 * The quiet label over a group: "Pinned" above the grid, a sidebar section, a
 * settings group. Sentence case in the muted text colour, not tracked small
 * caps: the accent marks what is selected, and a loud header competes with it.
 */
export function SectionLabel({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <div className={cn("px-2 text-xs font-medium text-on-surface-variant", className)}>
      {children}
    </div>
  )
}
