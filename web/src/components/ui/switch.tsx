"use client"

import * as React from "react"
import { cn } from "cn"
import { Switch as SwitchPrimitive } from "radix-ui"

// A flat track and thumb in the app's own colours, squared off to the
// radius scale instead of a pill: accent track with an onPrimaryContainer
// thumb when on, a faint veil track when off. The thumb slides on transform.
function Switch({
  className,
  size = "default",
  ...props
}: React.ComponentProps<typeof SwitchPrimitive.Root> & {
  size?: "sm" | "default"
}) {
  return (
    <SwitchPrimitive.Root
      data-slot="switch"
      data-size={size}
      className={cn(
        "peer group/switch inline-flex shrink-0 items-center rounded-md p-0.5 transition-[background-color,box-shadow] duration-150 ease-standard outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50 disabled:cursor-not-allowed disabled:opacity-50 data-[size=default]:h-5 data-[size=default]:w-9 data-[size=sm]:h-4 data-[size=sm]:w-7 data-[state=checked]:bg-primary-container data-[state=unchecked]:bg-on-surface/15 data-[state=unchecked]:hover:bg-on-surface/20",
        className
      )}
      {...props}
    >
      <SwitchPrimitive.Thumb
        data-slot="switch-thumb"
        className={cn(
          "pointer-events-none block rounded-sm shadow-[0_1px_2px_rgb(13_16_26/0.2)] transition-transform duration-150 ease-standard group-data-[size=default]/switch:size-4 group-data-[size=sm]/switch:size-3 data-[state=checked]:translate-x-4 data-[state=checked]:bg-on-primary-container data-[state=unchecked]:translate-x-0 data-[state=unchecked]:bg-white dark:data-[state=unchecked]:bg-on-surface-variant group-data-[size=sm]/switch:data-[state=checked]:translate-x-3"
        )}
      />
    </SwitchPrimitive.Root>
  )
}

export { Switch }
