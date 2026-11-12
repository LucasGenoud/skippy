"use client";

import { useSyncExternalStore } from "react";
import type { Brightness } from "@/lib/theme/accent";

// The brightness the app is painted in. `applyTheme` toggles the `dark` class
// on <html>, so that class is the source of truth, signed in or not.

function subscribe(onChange: () => void): () => void {
  if (typeof MutationObserver === "undefined") {
    return () => {};
  }
  const observer = new MutationObserver(onChange);
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
  return () => observer.disconnect();
}

const current = (): Brightness => (document.documentElement.classList.contains("dark") ? "dark" : "light");
const serverSnapshot = (): Brightness => "light";

export function useBrightness(): Brightness {
  return useSyncExternalStore(subscribe, current, serverSnapshot);
}
