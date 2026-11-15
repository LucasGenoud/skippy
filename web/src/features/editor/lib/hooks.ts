"use client";

import { useSyncExternalStore } from "react";

// Small browser reads the editor needs, as subscriptions rather than renders
// that poll.

export { useBrightness } from "@/lib/theme/use-brightness";

/** Whether [query] matches, kept current. */
export function useMediaQuery(query: string): boolean {
  return useSyncExternalStore(
    (onChange) => {
      const list = window.matchMedia(query);
      list.addEventListener("change", onChange);
      return () => list.removeEventListener("change", onChange);
    },
    () => window.matchMedia(query).matches,
    () => false,
  );
}

/** Same breakpoint as Flutter's `kWideBreakpoint`: wide screens get a centred dialog. */
export const WIDE_QUERY = "(min-width: 600px)";

/** Whether this is a Mac-style keyboard, for shortcut hints. */
export function isApplePlatform(): boolean {
  return typeof navigator !== "undefined" && /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
}
