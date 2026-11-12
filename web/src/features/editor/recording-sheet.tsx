"use client";

import { useEffect, useRef, useState } from "react";
import { Mic, MicOff, Square } from "lucide-react";
import { motion, useReducedMotion } from "motion/react";

import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { AudioRecorder, audioRecordingSupported, type RecordedClip } from "./audio-recorder";

// The recording surface (`recording_sheet.dart`): a mic that swells with your
// voice, a scrolling waveform and a timer. Stop hands back the clip; Cancel,
// Escape or a tap outside throw it away and release the microphone.
//
// For the quick-add bar (NOTES): `<RecordingSheet open onOpenChange
// onRecorded={(clip) => notes.createAudioNote(clip.blob, clip.mime, ...)} />`.

const BAR_COUNT = 40;
const TICK_MS = 200;
const SMOOTHING = 0.55;
const RIPPLES = 3;

function clock(ms: number): string {
  const seconds = Math.floor(ms / 1000);
  return `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
}

export function RecordingSheet({
  open,
  onOpenChange,
  onRecorded,
}: {
  open: boolean;
  onOpenChange(open: boolean): void;
  onRecorded(clip: RecordedClip): void;
}) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent showCloseButton={false} className="sm:max-w-[420px]">
        {open ? <Recording onCancel={() => onOpenChange(false)} onDone={(clip) => { onOpenChange(false); onRecorded(clip); }} /> : null}
      </DialogContent>
    </Dialog>
  );
}

function Recording({ onCancel, onDone }: { onCancel(): void; onDone(clip: RecordedClip): void }) {
  const reduced = useReducedMotion();
  const [levels, setLevels] = useState<number[]>(() => Array.from({ length: BAR_COUNT }, () => 0));
  const [level, setLevel] = useState(0);
  const [ready, setReady] = useState(false);
  const [stopping, setStopping] = useState(false);
  const [error, setError] = useState<string | null>(() => (audioRecordingSupported() ? null : "Audio recording isn't supported in this browser."));
  const [elapsed, setElapsed] = useState(0);
  const recorder = useRef<AudioRecorder | null>(null);

  useEffect(() => {
    if (!audioRecordingSupported()) {
      return;
    }
    let live = true;
    let started = 0;
    let ticker: ReturnType<typeof setInterval> | null = null;
    const rec = new AudioRecorder((amp) => {
      if (!live) {
        return;
      }
      setLevel((l) => l * SMOOTHING + amp * (1 - SMOOTHING));
      setLevels((all) => [...all.slice(1), amp]);
    });
    recorder.current = rec;
    rec.start().then(
      () => {
        if (!live) {
          rec.dispose();
          return;
        }
        started = Date.now();
        ticker = setInterval(() => setElapsed(Date.now() - started), TICK_MS);
        setReady(true);
      },
      () => {
        if (live) {
          setError("Couldn't access the microphone. Check your microphone permissions and try again.");
        }
      },
    );
    return () => {
      live = false;
      if (ticker !== null) {
        clearInterval(ticker);
      }
      rec.dispose();
    };
  }, []);

  const stop = async (): Promise<void> => {
    const rec = recorder.current;
    if (!rec || stopping) {
      return;
    }
    setStopping(true);
    const clip = await rec.stop();
    if (clip.blob.size === 0) {
      onCancel();
      return;
    }
    onDone(clip);
  };

  if (error) {
    return (
      <div className="flex flex-col items-center gap-4 pt-2 text-center">
        <MicOff aria-hidden className="size-10 text-error" />
        <DialogTitle className="sr-only">Recording</DialogTitle>
        <DialogDescription className="text-sm text-on-surface">{error}</DialogDescription>
        <Button onClick={onCancel}>Close</Button>
      </div>
    );
  }

  const live = ready ? level : 0;
  return (
    <div className="flex flex-col items-center">
      <div className="flex items-center gap-2">
        <motion.span
          aria-hidden
          className="size-2.5 rounded-full bg-error"
          animate={ready && !reduced ? { opacity: [0.3, 1, 0.3] } : { opacity: 0.3 }}
          transition={{ duration: 1.8, repeat: Infinity, ease: "easeInOut" }}
        />
        <DialogTitle>{ready ? "Recording" : "Waiting for microphone…"}</DialogTitle>
      </div>
      <DialogDescription className="sr-only">Speak, then press Stop to save the recording as a note.</DialogDescription>
      <div className="relative flex h-44 w-full items-center justify-center">
        {reduced
          ? null
          : Array.from({ length: RIPPLES }, (_, i) => (
              <motion.span
                key={i}
                aria-hidden
                className="absolute size-24 rounded-full bg-primary"
                animate={{ scale: [1, 2.1 + live], opacity: [0.3, 0] }}
                transition={{ duration: 1.8, repeat: Infinity, delay: (i * 1.8) / RIPPLES, ease: "easeOut" }}
              />
            ))}
        <span
          className="relative flex items-center justify-center rounded-full bg-primary-container text-on-primary-container shadow-raised transition-[width,height] duration-150 ease-standard"
          style={{ width: 88 + live * 18, height: 88 + live * 18 }}
        >
          <Mic aria-hidden className="size-10" />
        </span>
      </div>
      <div aria-hidden className="flex h-12 items-center justify-center gap-[3px]">
        {levels.map((l, i) => (
          <span key={i} className="w-[3px] rounded-xs bg-primary/75 transition-[height] duration-150 ease-standard" style={{ height: Math.min(46, Math.max(4, 4 + l * 42)) }} />
        ))}
      </div>
      <p className="pt-3 text-2xl font-semibold text-on-surface-variant tabular-nums" aria-live="off">
        {clock(elapsed)}
      </p>
      <div className="grid w-full grid-cols-2 gap-3 pt-5">
        <Button variant="outline" size="lg" disabled={stopping} onClick={onCancel}>
          Cancel
        </Button>
        <Button size="lg" disabled={!ready || stopping} onClick={() => void stop()}>
          {stopping ? <span aria-hidden className="size-4 animate-spin rounded-full border-2 border-current/30 border-t-current" /> : <Square />}
          {stopping ? "Saving…" : "Stop"}
        </Button>
      </div>
    </div>
  );
}
