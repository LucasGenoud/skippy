// Microphone capture with the browser's MediaRecorder, plus a live input
// level for the recording UI (`audio_recorder_web.dart`).

/** Containers in order of preference: Chrome/Firefox give webm/opus, Safari mp4. */
const MIME_CANDIDATES = ["audio/webm;codecs=opus", "audio/webm", "audio/ogg;codecs=opus", "audio/mp4"];
const FALLBACK_MIME = "audio/webm";
const METER_INTERVAL_MS = 55;
const FFT_SIZE = 256;
/** Average magnitude (0..255) mapped to a lively but bounded 0..1. */
const LEVEL_DIVISOR = 160;

export function audioRecordingSupported(): boolean {
  return typeof window !== "undefined" && typeof window.MediaRecorder !== "undefined" && Boolean(navigator.mediaDevices?.getUserMedia);
}

export function pickRecordingMime(isSupported: (mime: string) => boolean): string {
  return MIME_CANDIDATES.find((candidate) => isSupported(candidate)) ?? "";
}

/** The average of [data] as a 0..1 level. */
export function levelOf(data: ArrayLike<number>): number {
  if (data.length === 0) {
    return 0;
  }
  let sum = 0;
  for (let i = 0; i < data.length; i++) {
    sum += data[i] ?? 0;
  }
  return Math.min(1, Math.max(0, sum / data.length / LEVEL_DIVISOR));
}

export interface RecordedClip {
  readonly blob: Blob;
  readonly mime: string;
}

export class AudioRecorder {
  private stream: MediaStream | null = null;
  private recorder: MediaRecorder | null = null;
  private chunks: Blob[] = [];
  private mime = "";
  private audio: AudioContext | null = null;
  private meter: ReturnType<typeof setInterval> | null = null;

  constructor(private readonly onLevel: (level: number) => void) {}

  /** Asks for the microphone and starts. Rejects when permission is refused. */
  async start(): Promise<void> {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    this.stream = stream;
    this.mime = pickRecordingMime((m) => MediaRecorder.isTypeSupported(m));
    this.chunks = [];
    const recorder = this.mime ? new MediaRecorder(stream, { mimeType: this.mime }) : new MediaRecorder(stream);
    recorder.ondataavailable = (event) => {
      if (event.data.size > 0) {
        this.chunks.push(event.data);
      }
    };
    this.recorder = recorder;
    this.startMeter(stream);
    recorder.start();
  }

  private startMeter(stream: MediaStream): void {
    try {
      const context = new AudioContext();
      const analyser = context.createAnalyser();
      analyser.fftSize = FFT_SIZE;
      context.createMediaStreamSource(stream).connect(analyser);
      const buffer = new Uint8Array(analyser.frequencyBinCount);
      this.audio = context;
      this.meter = setInterval(() => {
        analyser.getByteFrequencyData(buffer);
        this.onLevel(levelOf(buffer));
      }, METER_INTERVAL_MS);
    } catch {
      // The meter is best effort; the sheet animates regardless.
    }
  }

  /** Stops and resolves with the encoded clip. */
  stop(): Promise<RecordedClip> {
    this.stopMeter();
    const mime = this.mime || FALLBACK_MIME;
    const recorder = this.recorder;
    return new Promise((resolve) => {
      const finish = (): void => {
        const blob = new Blob(this.chunks, { type: mime });
        this.dispose();
        resolve({ blob, mime });
      };
      if (recorder && recorder.state !== "inactive") {
        recorder.onstop = finish;
        recorder.stop();
      } else {
        finish();
      }
    });
  }

  private stopMeter(): void {
    if (this.meter !== null) {
      clearInterval(this.meter);
      this.meter = null;
    }
  }

  /** Releases the microphone. Safe to call more than once. */
  dispose(): void {
    this.stopMeter();
    if (this.recorder && this.recorder.state !== "inactive") {
      this.recorder.onstop = null;
      this.recorder.stop();
    }
    this.recorder = null;
    this.stream?.getTracks().forEach((track) => track.stop());
    this.stream = null;
    void this.audio?.close().catch(() => undefined);
    this.audio = null;
  }
}
