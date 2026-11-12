"use client";

import { useSyncExternalStore } from "react";
import type { Brightness } from "@/lib/theme/accent";

// Window-size and theme answers the shell branches on. Each hook notifies only
// when its answer flips, so a window drag rebuilds nothing between breakpoints
// (`ScreenWidth.isAtLeast`).

/** Where the sidebar docks beside the content (`kWideBreakpoint`). */
export const WIDE_MIN_WIDTH = 600;

/** Where the top bar names the view instead of collapsing into one search pill. */
export const TITLED_BAR_MIN_WIDTH = 650;

function subscribeMedia(query: string) {
  return (onChange: () => void): (() => void) => {
    const list = window.matchMedia(query);
    list.addEventListener("change", onChange);
    return () => list.removeEventListener("change", onChange);
  };
}

const subscribers = new Map<string, (onChange: () => void) => () => void>();

function subscriberFor(query: string): (onChange: () => void) => () => void {
  let found = subscribers.get(query);
  if (!found) {
    found = subscribeMedia(query);
    subscribers.set(query, found);
  }
  return found;
}

function matches(query: string): boolean {
  return typeof window !== "undefined" && typeof window.matchMedia === "function" && window.matchMedia(query).matches;
}

/** Whether the window is at least [px] wide. Defaults to wide where media queries are missing (tests). */
export function useMinWidth(px: number): boolean {
  const query = `(min-width: ${px}px)`;
  return useSyncExternalStore(
    (onChange) => (typeof window.matchMedia === "function" ? subscriberFor(query)(onChange) : () => undefined),
    () => (typeof window.matchMedia === "function" ? matches(query) : true),
    () => true,
  );
}

export const useWide = (): boolean => useMinWidth(WIDE_MIN_WIDTH);
export const useTitledBar = (): boolean => useMinWidth(TITLED_BAR_MIN_WIDTH);

export { useBrightness } from "@/lib/theme/use-brightness";

/** "Cmd" or "Ctrl" for this machine. */
export function usePlatformName(): string {
  return useSyncExternalStore(
    () => () => undefined,
    () => navigator.platform || navigator.userAgent,
    () => "",
  );
}
