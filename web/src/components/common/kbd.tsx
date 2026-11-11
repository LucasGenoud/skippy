import type { ReactNode } from "react"
import { cn } from "cn"

/** A keyboard shortcut hint: `<Kbd>⌘</Kbd><Kbd>K</Kbd>`, or one `<Kbd>/</Kbd>`. */
export function Kbd({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <kbd
      className={cn(
        "inline-flex h-5 min-w-5 items-center justify-center rounded-xs border border-outline-variant bg-surface-container-low px-1 font-sans text-2xs font-medium text-on-surface-variant shadow-[0_1px_0_var(--outline-variant)]",
        className,
      )}
    >
      {children}
    </kbd>
  )
}
