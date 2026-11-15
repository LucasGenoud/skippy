"use client";

import { useEffect, useState } from "react";
import { CircleAlert } from "lucide-react";
import { cn } from "cn";

import { Button } from "@/components/ui/button";

/**
 * Transcription normally takes seconds. A note stuck pending (the Whisper
 * service died mid-job) must not keep animating forever on a grid card.
 */
const ANIMATION_CAP_MS = 2 * 60 * 1000;
const BARS = [0, 1, 2, 3];

/**
 * "Transcribing…" for an audio note whose transcript is on its way: a
 * bouncing equaliser beside shimmering placeholder lines
 * (`transcribing_indicator.dart`). Pure CSS animation, capped in time.
 */
export function TranscribingIndicator({ compact = false }: { compact?: boolean }) {
  const [animating, setAnimating] = useState(true);
  useEffect(() => {
    const timer = setTimeout(() => setAnimating(false), ANIMATION_CAP_MS);
    return () => clearTimeout(timer);
  }, []);
  const widths = compact ? ["100%", "60%"] : ["100%", "92%", "50%"];
  const state = animating ? "running" : "paused";
  return (
    <div role="status" aria-label="Transcribing" className="flex flex-col gap-2">
      <div className="flex items-center gap-2.5">
        <span aria-hidden className={cn("flex items-center gap-[3px]", compact ? "h-3.5" : "h-[18px]")}>
          {BARS.map((bar) => (
            <span
              key={bar}
              className="h-full w-[3.5px] origin-center rounded-[2px] bg-primary motion-safe:animate-[skippy-eq_1.4s_ease-in-out_infinite]"
              style={{ animationDelay: `${-bar * 0.35}s`, animationPlayState: state }}
            />
          ))}
        </span>
        <span className="text-xs font-medium text-on-surface-variant">Transcribing…</span>
      </div>
      <div aria-hidden className={cn("flex flex-col", compact ? "gap-[9px]" : "gap-[9px] pt-1")}>
        {widths.map((width) => (
          <span
            key={width}
            className="h-2.5 rounded-[4px] bg-on-surface/9 motion-safe:animate-[skippy-shimmer_1.4s_ease-in-out_infinite]"
            style={{ width, animationPlayState: state, backgroundImage: SHIMMER, backgroundSize: "300% 100%" }}
          />
        ))}
      </div>
      <style>{KEYFRAMES}</style>
    </div>
  );
}

const SHIMMER = "linear-gradient(90deg, transparent 30%, color-mix(in srgb, var(--on-surface) 11%, transparent) 50%, transparent 70%)";

// Scoped keyframes: the bars bob out of phase, the shimmer sweeps past both edges.
const KEYFRAMES = `
@keyframes skippy-eq { 0%, 100% { transform: scaleY(0.3); } 50% { transform: scaleY(1); } }
@keyframes skippy-shimmer { 0% { background-position: 100% 0; } 100% { background-position: -50% 0; } }
`;

/** Shown when transcription failed, with an optional Retry. */
export function TranscriptFailed({ compact = false, onRetry }: { compact?: boolean; onRetry?: () => void }) {
  return (
    <div className="flex items-center gap-2">
      <CircleAlert aria-hidden className={cn("shrink-0 text-error", compact ? "size-4" : "size-[18px]")} />
      <span className="flex-1 text-xs text-on-surface-variant">Couldn&apos;t transcribe this recording</span>
      {onRetry ? (
        <Button variant="ghost" size="xs" onClick={onRetry}>
          Retry
        </Button>
      ) : null}
    </div>
  );
}
