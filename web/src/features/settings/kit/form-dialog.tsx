"use client";

import { useRef, type ReactNode } from "react";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { cn } from "@/lib/utils";

const WIDTHS = {
  compact: "sm:max-w-[360px]",
  default: "sm:max-w-[420px]",
  wide: "sm:max-w-[520px]",
} as const;

export type FormDialogWidth = keyof typeof WIDTHS;

/**
 * A settings form (`FormDialog`): a centred dialog on wide screens, the whole
 * viewport on phones, where a floating box with several fields fights the
 * keyboard. The body scrolls; the title and the actions stay put. While
 * `busy`, nothing outside the form closes it.
 */
export function FormDialog({
  open,
  onOpenChange,
  title,
  description,
  children,
  footer,
  width = "default",
  busy = false,
  onSubmit,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: ReactNode;
  description?: ReactNode;
  children: ReactNode;
  footer: ReactNode;
  width?: FormDialogWidth;
  busy?: boolean;
  /** Enter in a single-line field submits (the form's default button). */
  onSubmit?: () => void;
}) {
  const submitRef = useRef<HTMLButtonElement>(null);
  return (
    <Dialog open={open} onOpenChange={(next) => (busy && !next ? undefined : onOpenChange(next))}>
      <DialogContent
        showCloseButton={!busy}
        onInteractOutside={(event) => busy && event.preventDefault()}
        onEscapeKeyDown={(event) => busy && event.preventDefault()}
        className={cn(
          "grid-rows-[auto_minmax(0,1fr)_auto] overflow-hidden",
          "max-sm:top-0 max-sm:left-0 max-sm:h-dvh max-sm:max-h-dvh max-sm:w-full max-sm:max-w-full max-sm:translate-x-0 max-sm:translate-y-0 max-sm:rounded-none max-sm:border-0",
          WIDTHS[width],
        )}
      >
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          {description ? <DialogDescription>{description}</DialogDescription> : <DialogDescription className="sr-only">{title}</DialogDescription>}
        </DialogHeader>
        <form
          className="-mx-5 min-h-0 overflow-y-auto px-5 py-0.5"
          onSubmit={(event) => {
            event.preventDefault();
            // Only Enter submits: a button in the body that forgot type="button" must not.
            const submitter = (event.nativeEvent as SubmitEvent).submitter;
            if (submitter && submitter !== submitRef.current) {
              return;
            }
            onSubmit?.();
          }}
        >
          {/* First in the form, so it is the default button Enter presses. */}
          <button ref={submitRef} type="submit" className="sr-only" aria-hidden tabIndex={-1} />
          {children}
        </form>
        <DialogFooter>{footer}</DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/** A subdued heading over grouped controls inside a form. */
export function FormSectionLabel({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cn("text-xs font-medium text-on-surface-variant", className)}>{children}</div>;
}

/** A labelled field: label, control, and a helper line under it. */
export function Field({
  label,
  htmlFor,
  helper,
  error,
  trailing,
  children,
  className,
}: {
  label: ReactNode;
  htmlFor: string;
  helper?: ReactNode;
  error?: string | null;
  trailing?: ReactNode;
  children: ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("flex flex-col gap-1.5", className)}>
      <div className="flex items-center gap-2">
        <label htmlFor={htmlFor} className="flex-1 text-xs font-medium text-on-surface-variant">
          {label}
        </label>
        {trailing}
      </div>
      {children}
      {error ? (
        <p role="alert" className="text-xs text-error">
          {error}
        </p>
      ) : helper ? (
        <p className="text-xs text-on-surface-variant">{helper}</p>
      ) : null}
    </div>
  );
}
