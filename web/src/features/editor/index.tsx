"use client";

import { lazy, Suspense } from "react";

// The editor feature's entry points. The history screen is its own chunk:
// it is rarely opened, so the editor never pays for it.

export { NoteEditor } from "./note-editor";
export { RecordingSheet } from "./recording-sheet";

const LazyHistory = lazy(() => import("./history-screen"));

export function HistoryScreen({ noteId, onClose }: { noteId: string; onClose(): void }) {
  return (
    <Suspense fallback={null}>
      <LazyHistory noteId={noteId} onClose={onClose} />
    </Suspense>
  );
}
