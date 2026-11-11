import { MoreHorizontal } from "lucide-react"
import { cn } from "cn"

import { LabelIcon, labelStyle } from "@/lib/theme/label-style"

/**
 * A label as a card draws it: its name in its colour, a 14% wash behind, a
 * 55% edge, and its icon when it has one. Uncoloured labels draw only an edge.
 */
export function LabelChip({
  name,
  color,
  icon,
  className,
}: {
  name: string
  /** "#RRGGBB" or null for the theme default. */
  color?: string | null
  /** A LABEL_ICONS key, or null for no leading icon. */
  icon?: string | null
  className?: string
}) {
  return (
    <span
      className={cn(
        "inline-flex h-6 max-w-full min-w-0 items-center gap-1 rounded-md border pr-2.5 text-2xs font-medium",
        icon ? "pl-1.5" : "pl-2.5",
        className,
      )}
      style={labelStyle(color)}
    >
      {icon ? <LabelIcon iconKey={icon} aria-hidden className="size-[13px] shrink-0" /> : null}
      <span className="truncate">{name}</span>
    </span>
  )
}

/** The compact 24px square a crowded card footer shows instead of a chip. */
export function LabelMarker({ name, color, icon }: { name: string; color?: string | null; icon?: string | null }) {
  return (
    <span
      title={name}
      aria-label={name}
      role="img"
      className="inline-flex size-6 shrink-0 items-center justify-center rounded-md border"
      style={labelStyle(color)}
    >
      <LabelIcon iconKey={icon} aria-hidden className="size-[13px]" />
    </span>
  )
}

/** The "more labels" marker after the last LabelMarker that fits. */
export function LabelOverflowMarker({ count }: { count: number }) {
  return (
    <span
      role="img"
      aria-label={`${count} more labels`}
      className="inline-flex size-6 shrink-0 items-center justify-center rounded-md border text-on-surface-variant"
      style={labelStyle(null)}
    >
      <MoreHorizontal aria-hidden className="size-4" />
    </span>
  )
}
