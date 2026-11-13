import * as React from "react"
import { cn } from "cn"
import { CheckIcon } from "lucide-react"
import { Checkbox as CheckboxPrimitive } from "radix-ui"

// A checked box is the accent at full strength (primaryContainer) with the
// tick in onPrimaryContainer. The corner is 3px rather than 6: on a box this
// small a 6px corner reads as a circle. The tick pops in with a small
// overshoot rather than appearing.
function Checkbox({
  className,
  ...props
}: React.ComponentProps<typeof CheckboxPrimitive.Root>) {
  return (
    <CheckboxPrimitive.Root
      data-slot="checkbox"
      className={cn(
        "peer size-[18px] shrink-0 rounded-check border-[1.5px] border-on-surface-variant/70 bg-transparent text-on-primary-container transition-[background-color,border-color,box-shadow] duration-150 ease-standard outline-none hover:border-on-surface hover:bg-hover focus-visible:ring-[3px] focus-visible:ring-ring/50 disabled:cursor-not-allowed disabled:opacity-50 aria-invalid:border-destructive data-[state=checked]:border-primary-container data-[state=checked]:bg-primary-container data-[state=indeterminate]:border-primary-container data-[state=indeterminate]:bg-primary-container",
        className
      )}
      {...props}
    >
      <CheckboxPrimitive.Indicator
        data-slot="checkbox-indicator"
        className="grid place-content-center text-current data-[state=checked]:animate-in data-[state=checked]:zoom-in-50 data-[state=checked]:duration-150 data-[state=checked]:ease-back"
      >
        <CheckIcon className="size-3.5" strokeWidth={3} />
      </CheckboxPrimitive.Indicator>
    </CheckboxPrimitive.Root>
  )
}

export { Checkbox }
