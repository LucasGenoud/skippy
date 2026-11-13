import * as React from "react"
import { cn } from "cn"
import { RadioGroup as RadioGroupPrimitive } from "radix-ui"

function RadioGroup({
  className,
  ...props
}: React.ComponentProps<typeof RadioGroupPrimitive.Root>) {
  return (
    <RadioGroupPrimitive.Root
      data-slot="radio-group"
      className={cn("grid gap-3", className)}
      {...props}
    />
  )
}

// The one round control: a radio's circle is what tells it from a checkbox.
// Selected is the accent fill with an onPrimaryContainer dot, like a checkbox.
function RadioGroupItem({
  className,
  ...props
}: React.ComponentProps<typeof RadioGroupPrimitive.Item>) {
  return (
    <RadioGroupPrimitive.Item
      data-slot="radio-group-item"
      className={cn(
        "aspect-square size-[18px] shrink-0 rounded-full border-[1.5px] border-on-surface-variant/70 transition-[background-color,border-color,box-shadow] duration-150 ease-standard outline-none hover:border-on-surface hover:bg-hover focus-visible:ring-[3px] focus-visible:ring-ring/50 disabled:cursor-not-allowed disabled:opacity-50 aria-invalid:border-destructive data-[state=checked]:border-primary-container data-[state=checked]:bg-primary-container",
        className
      )}
      {...props}
    >
      <RadioGroupPrimitive.Indicator
        data-slot="radio-group-indicator"
        className="flex items-center justify-center data-[state=checked]:animate-in data-[state=checked]:zoom-in-50 data-[state=checked]:duration-150 data-[state=checked]:ease-back"
      >
        <span className="size-1.5 rounded-full bg-on-primary-container" />
      </RadioGroupPrimitive.Indicator>
    </RadioGroupPrimitive.Item>
  )
}

export { RadioGroup, RadioGroupItem }
