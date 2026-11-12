"use client";

import { useSyncExternalStore } from "react";
import type { Brightness } from "@/lib/theme/accent";

// The brightness the app is drawn in right now: `applyTheme` toggles the
// `dark` class on <html>, so that class is the source of truth.

function subscribe(onChange: () => void): () => void {
  const observer = new MutationObserver(onChange);
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
  return () => observer.disconnect();
}

const current = (): Brightness => (document.documentElement.classList.contains("dark") ? "dark" : "light");

export function useBrightness(): Brightness {
  return useSyncExternalStore(subscribe, current, () => "light");
}
