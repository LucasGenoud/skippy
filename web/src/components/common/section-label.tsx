import type { ReactNode } from "react"
import { cn } from "cn"

/**
 * The small caps over a group: "PINNED" above the grid, a sidebar section, a
 * settings group (`sectionLabelStyle`). Muted rather than accented: the accent
 * marks what is selected, and a header in it competes with the selection.
 */
export function SectionLabel({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <div className={cn("px-2 text-2xs font-bold tracking-[0.11em] text-on-surface-variant uppercase", className)}>
      {children}
    </div>
  )
}
