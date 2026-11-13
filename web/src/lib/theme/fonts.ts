// The selectable typefaces (`util/app_fonts.dart`). Ids are the Dart enum
// names the settings document stores under "font".
//
// globals.css declares every family with @font-face (font-display: swap), and
// a browser downloads a face only once text uses it, so nobody pays for a
// family they never picked. loadFont() fetches all four weights first and only
// then switches --font-app, so text reflows once, into the finished face.

export type AppFontId = "system" | "inter" | "nunito" | "lora" | "jetBrainsMono";

export interface AppFont {
  id: AppFontId;
  label: string;
  /** The @font-face family, or null for the platform's own UI font. */
  family: string | null;
}

export const APP_FONTS: readonly AppFont[] = [
  { id: "system", label: "System default", family: null },
  { id: "inter", label: "Inter", family: "Inter" },
  { id: "nunito", label: "Nunito", family: "Nunito" },
  { id: "lora", label: "Lora", family: "Lora" },
  { id: "jetBrainsMono", label: "JetBrains Mono", family: "JetBrainsMono" },
];

/** The face globals.css starts in, before settings have loaded. */
export const DEFAULT_UI_FONT: AppFontId = "inter";

/** The face for code and monospace text. */
export const MONO_FAMILY = "JetBrainsMono";

// One file per weight the interface draws in.
const WEIGHTS = [400, 500, 600, 700] as const;
const SYSTEM_STACK = "var(--font-system)";
const FONT_VARIABLE = "--font-app";

const loading = new Map<AppFontId, Promise<boolean>>();
// The most recent request; a slower earlier load must not overwrite it.
let latest: AppFontId | null = null;

/** The font for a stored id; unknown ids read as the system font. */
export function appFont(id: string | null | undefined): AppFont {
  return APP_FONTS.find((font) => font.id === id) ?? (APP_FONTS[0] as AppFont);
}

/** The CSS font-family value for a font. */
export function fontStack(font: AppFont): string {
  return font.family ? `"${font.family}", ${SYSTEM_STACK}` : SYSTEM_STACK;
}

function fetchFamily(family: string): Promise<boolean> {
  const loads = WEIGHTS.map((weight) => document.fonts.load(`${weight} 1em "${family}"`));
  return Promise.all(loads).then(
    (faces) => faces.every((list) => list.length > 0),
    () => false,
  );
}

/**
 * Loads a family's weights once (later calls share the first attempt) and
 * then sets --font-app on <html>. A family that fails to load leaves the
 * current face in place. Resolves to whether the font is now applied.
 */
export async function loadFont(id: string | null | undefined): Promise<boolean> {
  if (typeof document === "undefined") {
    return false;
  }

  const font = appFont(id);
  const root = document.documentElement;
  latest = font.id;
  if (!font.family) {
    root.style.setProperty(FONT_VARIABLE, SYSTEM_STACK);
    return true;
  }

  let pending = loading.get(font.id);
  if (!pending) {
    pending = fetchFamily(font.family);
    loading.set(font.id, pending);
  }
  const ready = await pending;
  if (!ready) {
    loading.delete(font.id);
    return false;
  }
  if (latest !== font.id) {
    return false;
  }
  root.style.setProperty(FONT_VARIABLE, fontStack(font));
  return true;
}
