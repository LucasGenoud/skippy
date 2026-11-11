import type { ComponentProps, ReactNode } from "react"
import { cn } from "cn"

import { Button } from "@/components/ui/button"
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip"

import { Kbd } from "./kbd"

type ButtonProps = Omit<ComponentProps<typeof Button>, "size" | "variant" | "children" | "aria-label">

const SIZES = { sm: "icon-sm", default: "icon", lg: "icon-lg" } as const

/**
 * A square ghost icon button with a hover tooltip (`AppIconButton`). The label
 * is both the tooltip and the accessible name; `shortcut` adds a key hint.
 * `active` marks a toggle that is on, in the accent wash.
 */
export function IconButton({
  label,
  icon,
  shortcut,
  size = "default",
  active = false,
  side = "bottom",
  className,
  ...props
}: ButtonProps & {
  label: string
  icon: ReactNode
  shortcut?: string
  size?: keyof typeof SIZES
  active?: boolean
  side?: "top" | "bottom" | "left" | "right"
}) {
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Button
          variant="ghost"
          size={SIZES[size]}
          aria-label={label}
          aria-pressed={active || undefined}
          className={cn(active && "bg-secondary-container text-on-secondary-container hover:bg-secondary-container", className)}
          {...props}
        >
          {icon}
        </Button>
      </TooltipTrigger>
      <TooltipContent side={side} className="flex items-center gap-2">
        {label}
        {shortcut ? <Kbd className="h-4 min-w-4 px-0.5">{shortcut}</Kbd> : null}
      </TooltipContent>
    </Tooltip>
  )
}
