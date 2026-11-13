"use client";

import { memo, useEffect, useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import { Pause, Play } from "lucide-react";
import { AnimatePresence, motion } from "motion/react";
import { cn } from "cn";

import { useNote, useNotesController } from "@/lib/store";
import { TRANSITION } from "@/lib/theme/motion";

export interface AudioPlayerProps {
  noteId: string;
  attachmentId: string;
  /**
   * "card": compact, and the clip is only fetched once play is pressed, so a
   * grid of audio notes downloads nothing until asked.
   * "editor": preloads so the length shows at once.
   */
  variant: "card" | "editor";
}

/** "m:ss". */
export function formatClock(seconds: number): string {
  const total = Number.isFinite(seconds) && seconds > 0 ? Math.round(seconds) : 0;
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
}

/** Firefox reports Infinity for MediaRecorder WebM clips; `seekable` carries the real end. */
function durationOf(audio: HTMLAudioElement): number {
  let duration = audio.duration;
  if (!Number.isFinite(duration) || duration <= 0) {
    const ranges = audio.seekable;
    if (ranges.length > 0) {
      duration = ranges.end(ranges.length - 1);
    }
  }
  return Number.isFinite(duration) && duration > 0 ? duration : 0;
}

/**
 * The inline player: play/pause, a seekable waveform and elapsed / total time
 * (`audio_player_view.dart`, `audio_player_web.dart`). Backed by a detached
 * HTMLAudioElement.
 */
export const AudioPlayer = memo(function AudioPlayer({ noteId, attachmentId, variant }: AudioPlayerProps) {
  const notes = useNotesController();
  const note = useNote(noteId);
  const attachment = note?.attachments.find((a) => a.id === attachmentId) ?? null;
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const [playing, setPlaying] = useState(false);
  const [position, setPosition] = useState(0);
  const [duration, setDuration] = useState(0);
  const url = attachment ? notes.fileUrl(attachment) : null;

  const ensureAudio = (): HTMLAudioElement | null => {
    if (audioRef.current || !url) {
      return audioRef.current;
    }
    const audio = new Audio();
    audio.preload = "auto";
    // Listeners before src: a cached clip can load its metadata quickly enough to miss them.
    const update = (): void => setDuration(durationOf(audio));
    for (const event of ["loadedmetadata", "durationchange", "progress", "canplay", "canplaythrough"]) {
      audio.addEventListener(event, update);
    }
    audio.addEventListener("timeupdate", () => setPosition(audio.currentTime));
    audio.addEventListener("pause", () => setPlaying(false));
    audio.addEventListener("play", () => setPlaying(true));
    audio.addEventListener("ended", () => {
      setPlaying(false);
      setPosition(0);
    });
    audio.src = url;
    audio.load();
    audioRef.current = audio;
    return audio;
  };

  useEffect(() => {
    if (variant === "editor") {
      ensureAudio();
    }
    return () => {
      const audio = audioRef.current;
      if (audio) {
        audio.pause();
        audio.removeAttribute("src");
        audio.load();
        audioRef.current = null;
      }
    };
    // The element is built once per clip; a rotated signed URL needs no reload.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [attachmentId, variant]);

  // While playing, follow the clock every frame so the playhead sweeps rather
  // than stepping at each timeupdate.
  useEffect(() => {
    if (!playing) {
      return;
    }
    let frame = requestAnimationFrame(function tick() {
      const audio = audioRef.current;
      if (audio) {
        setPosition(audio.currentTime);
      }
      frame = requestAnimationFrame(tick);
    });
    return () => cancelAnimationFrame(frame);
  }, [playing]);

  const toggle = (): void => {
    const audio = ensureAudio();
    if (!audio) {
      return;
    }
    if (audio.paused) {
      void audio.play().catch(() => setPlaying(false));
      setPlaying(true);
    } else {
      audio.pause();
    }
  };

  const seek = (seconds: number): void => {
    const audio = ensureAudio();
    if (!audio) {
      return;
    }
    audio.currentTime = seconds;
    setPosition(seconds);
  };

  const compact = variant === "card";
  return (
    <div
      className={cn("flex items-center gap-2 rounded-md bg-on-surface/6 px-2", compact ? "py-1" : "py-1.5")}
      onClick={(event) => event.stopPropagation()}
      // Playing and seeking never start a card drag or open the note.
      onPointerDown={(event) => event.stopPropagation()}
      onMouseDown={(event) => event.stopPropagation()}
      onTouchStart={(event) => event.stopPropagation()}
    >
      <button
        type="button"
        aria-label={playing ? "Pause" : "Play"}
        disabled={!url}
        onClick={toggle}
        className={cn(
          "inline-flex shrink-0 items-center justify-center rounded-md bg-primary-container text-on-primary-container transition-[filter] duration-150 ease-standard outline-none hover:brightness-95 focus-visible:ring-[3px] focus-visible:ring-ring/50 disabled:opacity-50",
          compact ? "size-8" : "size-9",
        )}
      >
        <AnimatePresence initial={false} mode="popLayout">
          <motion.span
            key={playing ? "pause" : "play"}
            className="inline-flex"
            initial={{ scale: 0.6, opacity: 0 }}
            animate={{ scale: 1, opacity: 1 }}
            exit={{ scale: 0.6, opacity: 0 }}
            transition={TRANSITION.fast}
          >
            {playing ? <Pause aria-hidden className="size-4 fill-current" /> : <Play aria-hidden className="size-4 fill-current" />}
          </motion.span>
        </AnimatePresence>
      </button>
      <AudioWaveform position={position} duration={duration} onSeek={duration > 0 ? seek : undefined} height={compact ? 28 : 34} />
      <span className="shrink-0 pr-1 text-2xs text-on-surface-variant tabular-nums">
        {formatClock(position)} / {formatClock(duration)}
      </span>
    </div>
  );
});

const BAR_WIDTH = 3;
const BAR_GAP = 2.5;
const MIN_BAR = 6;

/**
 * A calm, stable waveform drawn from a few low-frequency waves rather than by
 * decoding the clip; the filled part is the real playback position
 * (`audio_waveform.dart`). The fill is clipped, so it sweeps rather than
 * flipping bar by bar.
 */
function AudioWaveform({
  position,
  duration,
  onSeek,
  height,
}: {
  position: number;
  duration: number;
  onSeek?: (seconds: number) => void;
  height: number;
}) {
  const ref = useRef<HTMLDivElement | null>(null);
  const [width, setWidth] = useState(0);
  useEffect(() => {
    const element = ref.current;
    if (!element || typeof ResizeObserver === "undefined") {
      return;
    }
    const observer = new ResizeObserver(([entry]) => setWidth(entry?.contentRect.width ?? 0));
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  const progress = duration > 0 ? Math.min(1, Math.max(0, position / duration)) : 0;
  const count = Math.max(1, Math.floor(width / (BAR_WIDTH + BAR_GAP)));
  const bars = Array.from({ length: count }, (_, i) => {
    const x = i / Math.max(1, count - 1);
    const shape = 0.24 + 0.76 * Math.min(1, Math.max(0, (Math.sin(x * 19) + Math.sin(x * 43 + 1.7) * 0.45 + Math.sin(x * 7 + 0.8) * 0.3 + 1.75) / 3.5));
    return MIN_BAR + shape * (height - 8);
  });

  const seekAt = (event: ReactPointerEvent<HTMLDivElement>): void => {
    if (!onSeek || width === 0) {
      return;
    }
    const rect = event.currentTarget.getBoundingClientRect();
    onSeek(duration * Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width)));
  };

  const row = (className: string) => (
    <div className={cn("absolute inset-0 flex items-center", className)} style={{ gap: BAR_GAP }}>
      {bars.map((h, i) => (
        <span key={i} className="shrink-0 rounded-full bg-current" style={{ width: BAR_WIDTH, height: h }} />
      ))}
    </div>
  );

  return (
    <div
      ref={ref}
      role="slider"
      aria-label="Audio playback position"
      aria-valuemin={0}
      aria-valuemax={Math.round(duration)}
      aria-valuenow={Math.round(position)}
      aria-valuetext={duration > 0 ? `${Math.round(position)} of ${Math.round(duration)} seconds` : "Audio is loading"}
      tabIndex={onSeek ? 0 : -1}
      className={cn("relative min-w-0 flex-1 touch-none outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50", onSeek && "cursor-pointer")}
      style={{ height }}
      onPointerDown={(event) => {
        event.currentTarget.setPointerCapture(event.pointerId);
        seekAt(event);
      }}
      onPointerMove={(event) => {
        if (event.buttons > 0) {
          seekAt(event);
        }
      }}
      onKeyDown={(event) => {
        if (!onSeek) {
          return;
        }
        const step = event.key === "ArrowRight" ? 5 : event.key === "ArrowLeft" ? -5 : 0;
        if (step !== 0) {
          event.preventDefault();
          onSeek(Math.min(duration, Math.max(0, position + step)));
        }
      }}
    >
      {row("text-on-surface/14")}
      <div
        className="absolute inset-0 text-primary"
        style={{ clipPath: `inset(0 ${100 - progress * 100}% 0 0)` }}
      >
        {row("")}
      </div>
      <span
        aria-hidden
        className="absolute top-1/2 size-3 -translate-x-1/2 -translate-y-1/2 rounded-full border-[2.5px] border-primary bg-surface"
        style={{ left: `${progress * 100}%` }}
      />
    </div>
  );
}
