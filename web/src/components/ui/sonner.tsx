"use client"

import { Toaster as Sonner, type ToasterProps } from "sonner"

// Toasts are a raised surface card with an outline, not the dark inverse bar:
// a toast lands over the canvas and over white cards alike, so the shadow
// alone cannot be trusted to draw its edge. One is on screen at a time; see
// showAppSnack in components/common/snack.ts.
const TOAST_GAP = 16

const Toaster = ({ theme = "system", ...props }: ToasterProps) => {
  return (
    <Sonner
      theme={theme}
      position="bottom-left"
      offset={TOAST_GAP}
      mobileOffset={TOAST_GAP}
      visibleToasts={1}
      className="toaster group"
      toastOptions={{
        unstyled: true,
        classNames: {
          toast:
            "group/toast flex w-[var(--width)] max-w-[calc(100vw-32px)] items-center gap-2.5 rounded-md border border-outline-variant bg-surface py-1.5 pr-1.5 pl-3 text-[13.5px] leading-5 text-on-surface shadow-raised",
          icon: "flex size-[26px] shrink-0 items-center justify-center rounded-md [&_svg]:size-[15px]",
          content: "min-w-0 flex-1 py-1.5",
          title: "font-normal",
          description: "text-xs text-on-surface-variant",
          actionButton:
            "order-2 h-8 shrink-0 rounded-md px-2.5 text-sm font-semibold text-primary transition-colors duration-150 ease-standard hover:bg-hover active:bg-pressed focus-visible:ring-[3px] focus-visible:ring-ring/50 focus-visible:outline-none",
          cancelButton:
            "order-2 h-8 shrink-0 rounded-md px-2.5 text-sm text-on-surface-variant transition-colors duration-150 ease-standard hover:bg-hover",
          closeButton:
            "order-3 inline-flex size-8 shrink-0 items-center justify-center rounded-md text-on-surface-variant transition-colors duration-150 ease-standard hover:bg-hover hover:text-on-surface [&_svg]:size-4",
        },
      }}
      {...props}
    />
  )
}

export { Toaster }
