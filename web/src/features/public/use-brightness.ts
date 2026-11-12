import { useSyncExternalStore } from "react";
import type { Brightness } from "@/lib/theme/accent";

// The scheme the page is drawn in, read from the `dark` class `applyTheme`
// sets on <html>. The public page has no settings store to ask.

function subscribe(onChange: () => void): () => void {
  const observer = new MutationObserver(onChange);
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
  return () => observer.disconnect();
}

const current = (): Brightness => (document.documentElement.classList.contains("dark") ? "dark" : "light");

export function useBrightness(): Brightness {
  return useSyncExternalStore(subscribe, current, () => "light");
}
