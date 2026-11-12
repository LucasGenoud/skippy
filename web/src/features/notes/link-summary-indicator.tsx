"use client";

import { X } from "lucide-react";
import { cn } from "cn";

/** A quiet progress cue for the server's automatic link summary (`link_summary_indicator.dart`). */
export function LinkSummaryIndicator({ compact = false, onCancel }: { compact?: boolean; onCancel?: () => void }) {
  return (
    <div role="status" aria-label="Summarizing link" className="flex min-w-0 items-center gap-2 text-xs text-on-surface-variant">
      <Spinner className={compact ? "size-3.5" : "size-4"} />
      <span className="min-w-0 truncate">Summarizing link…</span>
      {onCancel ? (
        <button
          type="button"
          aria-label="Stop summarizing"
          title="Stop summarizing"
          className={cn(
            "inline-flex shrink-0 items-center justify-center rounded-md transition-colors duration-150 ease-standard outline-none hover:bg-hover focus-visible:ring-[3px] focus-visible:ring-ring/50",
            compact ? "size-7" : "size-8",
          )}
          onClick={(event) => {
            event.stopPropagation();
            onCancel();
          }}
        >
          <X aria-hidden className={compact ? "size-4" : "size-[18px]"} />
        </button>
      ) : null}
    </div>
  );
}

/** An accent ring spinning, the one progress glyph the notes feature uses. */
export function Spinner({ className }: { className?: string }) {
  return (
    <span
      aria-hidden
      className={cn("inline-block shrink-0 animate-spin rounded-full border-2 border-primary/25 border-t-primary", className)}
    />
  );
}
