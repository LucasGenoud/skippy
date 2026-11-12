"use client";

import { useEffect } from "react";
import { applyTheme, DEFAULT_ACCENT } from "@/lib/theme/accent";
import { loadFont } from "@/lib/theme/fonts";
import type { AppFont, ThemeMode } from "@/lib/store/settings-store";

// Applies the appearance settings through the design layer: accent and mode
// (applyTheme sets the variables and the `dark` class, following the system
// live for "system"), and the typeface (loadFont, once its faces are fetched).

/** Read by the inline script in layout.tsx so the next load paints in this scheme. */
const SCHEME_KEY = "skippy_scheme";

function rememberScheme(mode: ThemeMode): void {
  try {
    if (mode === "system") {
      window.localStorage.removeItem(SCHEME_KEY);
    } else {
      window.localStorage.setItem(SCHEME_KEY, mode);
    }
  } catch {
    // Storage blocked: the next load follows the system until settings load.
  }
}

export function ThemeSync({ accent = DEFAULT_ACCENT, mode, font = "system" }: { accent?: string; mode: ThemeMode; font?: AppFont }) {
  useEffect(() => {
    applyTheme(accent, mode);
    rememberScheme(mode);
  }, [accent, mode]);

  useEffect(() => {
    void loadFont(font);
  }, [font]);

  return null;
}
