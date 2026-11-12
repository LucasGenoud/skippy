"use client";

import { useEffect } from "react";
import type { Session } from "@/lib/store/session";

// Background and foreground for a browser tab: hiding flushes debounced edits
// and snapshots the cache; showing again re-pulls (the socket may have died).
// The web counterpart of `BackgroundGuard` in `main.dart`.
export function SessionLifecycle({ session }: { session: Session }) {
  useEffect(() => {
    const onVisibility = (): void => {
      if (document.visibilityState === "hidden") {
        session.notes.flushForBackground();
        return;
      }
      void session.resume();
    };
    const onPageHide = (): void => session.notes.flushForBackground();
    document.addEventListener("visibilitychange", onVisibility);
    window.addEventListener("pagehide", onPageHide);
    return () => {
      document.removeEventListener("visibilitychange", onVisibility);
      window.removeEventListener("pagehide", onPageHide);
    };
  }, [session]);
  return null;
}
