"use client";

import type { ReactNode } from "react";
import { cn } from "cn";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Sheet, SheetContent, SheetDescription, SheetFooter, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { useWide } from "./responsive";

/**
 * A short list of choices or a small form: a centred dialog on a wide window,
 * a bottom sheet on a phone, where the thumb is (`showAdaptiveSelectionSurface`).
 */
export function AdaptiveSurface({
  open,
  onOpenChange,
  title,
  description,
  footer,
  children,
  className,
}: {
  open: boolean;
  onOpenChange(open: boolean): void;
  title: string;
  description?: string;
  footer?: ReactNode;
  children: ReactNode;
  className?: string;
}) {
  const wide = useWide();

  if (wide) {
    return (
      <Dialog open={open} onOpenChange={onOpenChange}>
        <DialogContent className={cn("flex max-h-[min(640px,calc(100dvh-2rem))] flex-col", className)}>
          <DialogHeader>
            <DialogTitle>{title}</DialogTitle>
            {description ? <DialogDescription>{description}</DialogDescription> : <DialogDescription className="sr-only">{title}</DialogDescription>}
          </DialogHeader>
          <div className="-mx-5 min-h-0 flex-1 overflow-y-auto px-5">{children}</div>
          {footer ? <DialogFooter>{footer}</DialogFooter> : null}
        </DialogContent>
      </Dialog>
    );
  }

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent side="bottom" className={cn("max-h-[85dvh] gap-3 pb-[env(safe-area-inset-bottom)]", className)}>
        <div aria-hidden className="mx-auto mt-2 h-1 w-8 shrink-0 rounded-xs bg-outline-variant" />
        <SheetHeader className="pt-0">
          <SheetTitle>{title}</SheetTitle>
          {description ? <SheetDescription>{description}</SheetDescription> : <SheetDescription className="sr-only">{title}</SheetDescription>}
        </SheetHeader>
        <div className="min-h-0 flex-1 overflow-y-auto px-5 pb-2">{children}</div>
        {footer ? <SheetFooter className="flex-row justify-end">{footer}</SheetFooter> : null}
      </SheetContent>
    </Sheet>
  );
}
