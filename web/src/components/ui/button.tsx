import * as React from "react"
import { cva, type VariantProps } from "class-variance-authority"
import { cn } from "cn"
import { Slot } from "radix-ui"

// Desktop-style buttons: an 8px rounded rectangle, no ripple. Hover and press
// lay a quiet veil of the text colour over the control's own fill. The
// default variant is the accent at full strength (primaryContainer), the
// app's one loud control.
const buttonVariants = cva(
  "relative inline-flex shrink-0 items-center justify-center gap-2 rounded-md text-sm font-medium whitespace-nowrap select-none transition-[background-color,color,box-shadow,border-color] duration-150 ease-standard outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50 disabled:pointer-events-none disabled:opacity-50 aria-invalid:ring-destructive/20 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
  {
    variants: {
      variant: {
        default:
          "bg-primary-container text-on-primary-container shadow-card hover:bg-[color-mix(in_srgb,var(--primary-container),var(--on-primary-container)_8%)] active:bg-[color-mix(in_srgb,var(--primary-container),var(--on-primary-container)_14%)]",
        destructive:
          "bg-error text-on-error shadow-card hover:bg-error/90 active:bg-error/85 focus-visible:ring-destructive/30",
        outline:
          "border border-outline-variant bg-surface text-on-surface shadow-card hover:bg-[color-mix(in_srgb,var(--surface),var(--on-surface)_6%)] active:bg-[color-mix(in_srgb,var(--surface),var(--on-surface)_10%)]",
        secondary:
          "bg-secondary-container text-on-secondary-container hover:bg-[color-mix(in_srgb,var(--secondary-container),var(--on-surface)_6%)] active:bg-[color-mix(in_srgb,var(--secondary-container),var(--on-surface)_10%)]",
        ghost: "text-on-surface hover:bg-hover active:bg-pressed",
        link: "text-primary underline-offset-4 hover:underline",
      },
      size: {
        default: "h-9 px-4 has-[>svg]:px-3",
        xs: "h-6 gap-1 px-2 text-xs has-[>svg]:px-1.5 [&_svg:not([class*='size-'])]:size-3",
        sm: "h-8 gap-1.5 px-3 text-[13px] has-[>svg]:px-2.5",
        lg: "h-10 px-6 has-[>svg]:px-4",
        icon: "size-9 text-on-surface-variant [&_svg:not([class*='size-'])]:size-5",
        "icon-xs": "size-6 text-on-surface-variant [&_svg:not([class*='size-'])]:size-3.5",
        "icon-sm": "size-8 text-on-surface-variant [&_svg:not([class*='size-'])]:size-[18px]",
        "icon-lg": "size-10 text-on-surface-variant [&_svg:not([class*='size-'])]:size-5",
      },
    },
    defaultVariants: {
      variant: "default",
      size: "default",
    },
  }
)

function Button({
  className,
  variant = "default",
  size = "default",
  asChild = false,
  ...props
}: React.ComponentProps<"button"> &
  VariantProps<typeof buttonVariants> & {
    asChild?: boolean
  }) {
  const Comp = asChild ? Slot.Root : "button"

  return (
    <Comp
      data-slot="button"
      data-variant={variant}
      data-size={size}
      className={cn(buttonVariants({ variant, size, className }))}
      {...props}
    />
  )
}

export { Button, buttonVariants }
