"use client";

import { useSyncExternalStore } from "react";

/** Wide enough for the settings index and a page side by side. */
export const SPLIT_QUERY = "(min-width: 840px)";

/** Whether [query] matches, following the window live. */
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

/** The same answer outside React (an event handler). */
export function mediaMatches(query: string): boolean {
  return typeof window !== "undefined" && window.matchMedia(query).matches;
}
