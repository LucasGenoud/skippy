"use client";

import { useEffect, useRef, useState } from "react";
import { CircleAlert, Mic, Square } from "lucide-react";
import { showAppSnack } from "@/components/common/snack";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { useNotesController, useSettings } from "@/lib/store";

// A focused recording modal for an audio note (`RecordingSheet`): a live level
// meter and a running timer. Stop saves the clip as a new note; Cancel or
// dismissing throws it away. Transcription is asked for only when the server
// offers it; recording never depends on it.

const BAR_COUNT = 32;
const TICK_MS = 200;
const PREFERRED_MIME = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4", "audio/ogg"];

function pickMime(): string | undefined {
  if (typeof MediaRecorder === "undefined") {
    return undefined;
  }
  return PREFERRED_MIME.find((m) => MediaRecorder.isTypeSupported(m));
}

/** "1:05" from milliseconds. */
export function formatElapsed(ms: number): string {
  const total = Math.floor(ms / 1000);
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  return `${minutes}:${String(seconds).padStart(2, "0")}`;
}

export function RecordingDialog({ open, onOpenChange, labelIds }: { open: boolean; onOpenChange(open: boolean): void; labelIds: readonly string[] }) {
  const notes = useNotesController();
  const transcription = useSettings((s) => s.audioTranscriptionCapable);
  const [error, setError] = useState<string | null>(null);
  const [elapsed, setElapsed] = useState(0);
  const [levels, setLevels] = useState<number[]>(() => Array.from({ length: BAR_COUNT }, () => 0));
  const recorder = useRef<MediaRecorder | null>(null);
  const chunks = useRef<Blob[]>([]);
  const keep = useRef(false);

  useEffect(() => {
    if (!open) {
      return;
    }
    let stream: MediaStream | null = null;
    let context: AudioContext | null = null;
    let frame = 0;
    let ticker = 0;
    let cancelled = false;

    const start = async (): Promise<void> => {
      if (typeof navigator.mediaDevices?.getUserMedia !== "function" || typeof MediaRecorder === "undefined") {
        setError("Audio recording isn't supported in this browser.");
        return;
      }
      try {
        stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      } catch {
        setError("Couldn't access the microphone. Check your microphone permissions and try again.");
        return;
      }
      if (cancelled) {
        stream.getTracks().forEach((t) => t.stop());
        return;
      }
      const mime = pickMime();
      const rec = new MediaRecorder(stream, mime ? { mimeType: mime } : undefined);
      recorder.current = rec;
      chunks.current = [];
      rec.ondataavailable = (e) => {
        if (e.data.size > 0) {
          chunks.current.push(e.data);
        }
      };
      rec.onstop = () => {
        if (!keep.current) {
          return;
        }
        const type = rec.mimeType || mime || "audio/webm";
        const blob = new Blob(chunks.current, { type });
        void notes.createAudioNote(blob, type, { labelIds, transcription: transcription ? "available" : "unavailable" }).then((id) => {
          if (id === null) {
            showAppSnack("Couldn't save the recording", { kind: "danger", icon: CircleAlert });
          }
        });
      };
      rec.start();
      const began = performance.now();
      ticker = window.setInterval(() => setElapsed(performance.now() - began), TICK_MS);

      context = new AudioContext();
      const analyser = context.createAnalyser();
      analyser.fftSize = 256;
      context.createMediaStreamSource(stream).connect(analyser);
      const data = new Uint8Array(analyser.frequencyBinCount);
      let last = 0;
      const sample = (now: number): void => {
        frame = requestAnimationFrame(sample);
        if (now - last < 80) {
          return;
        }
        last = now;
        analyser.getByteTimeDomainData(data);
        let peak = 0;
        for (const v of data) {
          peak = Math.max(peak, Math.abs(v - 128) / 128);
        }
        setLevels((prev) => [...prev.slice(1), Math.min(1, peak * 1.8)]);
      };
      frame = requestAnimationFrame(sample);
    };
    void start();

    return () => {
      cancelled = true;
      cancelAnimationFrame(frame);
      window.clearInterval(ticker);
      if (recorder.current && recorder.current.state !== "inactive") {
        recorder.current.stop();
      }
      recorder.current = null;
      stream?.getTracks().forEach((t) => t.stop());
      void context?.close();
    };
  }, [open, notes, labelIds, transcription]);

  const stop = (): void => {
    keep.current = true;
    recorder.current?.stop();
    onOpenChange(false);
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-[360px]" showCloseButton={false}>
        <DialogHeader>
          <DialogTitle>{error ? "Can't record" : "Recording"}</DialogTitle>
          <DialogDescription>{error ?? "Speak, then stop to save the clip as a note."}</DialogDescription>
        </DialogHeader>
        {error ? null : (
          <div className="flex flex-col items-center gap-4 py-2">
            <span className="inline-flex size-14 items-center justify-center rounded-full bg-error-container text-on-error-container">
              <Mic className="size-6 animate-pulse" />
            </span>
            <div aria-hidden className="flex h-10 w-full items-center justify-center gap-[3px]">
              {levels.map((level, i) => (
                <span
                  key={i}
                  className="h-full w-1 origin-center rounded-xs bg-primary transition-transform duration-150 ease-standard"
                  style={{ transform: `scaleY(${Math.max(0.06, level)})` }}
                />
              ))}
            </div>
            <span className="font-mono text-sm text-on-surface-variant tabular-nums" aria-live="off">
              {formatElapsed(elapsed)}
            </span>
          </div>
        )}
        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            {error ? "Close" : "Cancel"}
          </Button>
          {error ? null : (
            <Button onClick={stop}>
              <Square />
              Stop and save
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
