import type { ReactNode } from "react"
import { cn } from "cn"

import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip"

const SIZES = { sm: "size-8", md: "size-10", lg: "size-12" } as const

/**
 * One choosable tile in a colour or pattern row: a 6px square with a hairline
 * edge that thickens to a 2px ring in the accent tone when selected. The edge
 * is an inset shadow, so selecting never shifts the layout. The tooltip is
 * the name and the accessible label.
 */
export function Swatch({
  label,
  selected,
  onSelect,
  fill,
  size = "md",
  ring = "primary",
  children,
  className,
}: {
  label: string
  selected: boolean
  onSelect: () => void
  /** CSS background; null draws the surface. */
  fill?: string | null
  size?: keyof typeof SIZES
  /** "strong" rings in the text colour, for fills the accent may match. */
  ring?: "primary" | "strong"
  children?: ReactNode
  className?: string
}) {
  const ringColor = ring === "strong" ? "var(--on-surface)" : "var(--primary)"
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <button
          type="button"
          role="radio"
          aria-checked={selected}
          aria-label={label}
          onClick={onSelect}
          className={cn(
            "relative isolate inline-flex shrink-0 items-center justify-center overflow-hidden rounded-md transition-[box-shadow,transform] duration-150 ease-standard outline-none hover:brightness-[0.97] active:scale-[0.96] focus-visible:ring-[3px] focus-visible:ring-ring/50",
            SIZES[size],
            className,
          )}
          style={{
            background: fill ?? "var(--surface)",
            boxShadow: selected ? `inset 0 0 0 2px ${ringColor}` : "inset 0 0 0 1px var(--outline-variant)",
          }}
        >
          {children}
        </button>
      </TooltipTrigger>
      <TooltipContent>{label}</TooltipContent>
    </Tooltip>
  )
}

/** The check a selected swatch shows, popping in with a small overshoot. */
export function SwatchCheck({ className, color }: { className?: string; color?: string }) {
  return (
    <svg
      aria-hidden
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={2.75}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={cn("relative size-5 animate-in zoom-in-50 duration-150 ease-back", className)}
      style={{ color }}
    >
      <path d="M20 6 9 17l-5-5" />
    </svg>
  )
}
