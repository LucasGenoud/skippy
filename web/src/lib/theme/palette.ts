// Note colours (`PaletteEntry`, `kDefaultPalette`, `SettingsStore.resolveColor`).
// A note stores a palette key; the user's palette in settings maps keys to a
// light and a dark fill. "default" is the plain surface.

import type { Brightness } from "./accent";
import { hexToRgb, rgbToHex } from "./color";

export interface PaletteEntry {
  key: string;
  name: string;
  /** "#RRGGBB" */
  light: string;
  /** "#RRGGBB" */
  dark: string;
}

/** The key of an uncoloured note, drawn on the plain surface. */
export const DEFAULT_NOTE_COLOR = "default";

/** The palette every account starts from and can reset to. */
export const DEFAULT_PALETTE: readonly PaletteEntry[] = [
  { key: "red", name: "Red", light: "#F28B82", dark: "#5C2B29" },
  { key: "orange", name: "Orange", light: "#FBBC04", dark: "#614A19" },
  { key: "yellow", name: "Yellow", light: "#FFF475", dark: "#635D19" },
  { key: "green", name: "Green", light: "#CCFF90", dark: "#345920" },
  { key: "teal", name: "Teal", light: "#A7FFEB", dark: "#16504B" },
  { key: "blue", name: "Blue", light: "#AECBFA", dark: "#2D555E" },
  { key: "gray", name: "Gray", light: "#E8EAED", dark: "#3C3F43" },
];

// The web client draws the stock palette softer than the Keep colours it is
// stored as: pale tints in light mode, muted ones in dark. Only an entry still
// holding its stock colour is swapped, so a colour the user picked is drawn as
// picked, and the settings document (shared with the other clients) is never
// rewritten.
const SOFT_FILLS: Readonly<Record<string, { light: string; dark: string }>> = {
  red: { light: "#FAD2CF", dark: "#3D2423" },
  orange: { light: "#FBDDBA", dark: "#3D2C1C" },
  yellow: { light: "#FAEAA8", dark: "#39321A" },
  green: { light: "#D2EDC6", dark: "#213322" },
  teal: { light: "#C2E9E2", dark: "#1A3331" },
  blue: { light: "#CCDFF8", dark: "#1D2B3D" },
  gray: { light: "#E5E4E1", dark: "#2A2927" },
};

/** The fill to draw for a palette entry's colour in a brightness. */
export function displayFill(key: string, hex: string, brightness: Brightness): string {
  const stock = DEFAULT_PALETTE.find((e) => e.key === key);
  const soft = SOFT_FILLS[key];
  if (!stock || !soft || stock[brightness].toUpperCase() !== hex.toUpperCase()) {
    return hex;
  }
  return soft[brightness];
}

/** "#RRGGBB" normalized to upper case, or null when it is not one. */
export function normalizeHex(hex: string | null | undefined): string | null {
  const rgb = hexToRgb(hex);
  return rgb ? rgbToHex(rgb) : null;
}

/** A palette entry from settings JSON, or null when it is unusable. */
export function paletteEntryFromJson(json: unknown): PaletteEntry | null {
  if (typeof json !== "object" || json === null) {
    return null;
  }
  const record = json as Record<string, unknown>;
  const key = typeof record.key === "string" ? record.key : "";
  const light = normalizeHex(typeof record.light === "string" ? record.light : null);
  const dark = normalizeHex(typeof record.dark === "string" ? record.dark : null);
  if (!key || !light || !dark) {
    return null;
  }
  const name = typeof record.name === "string" && record.name.trim() ? record.name.trim() : key;
  return { key, name, light, dark };
}

/**
 * A note colour key's fill, or null for the plain surface. Keys missing from
 * the user's palette still resolve from the defaults; unknown keys are plain.
 */
export function noteColor(
  key: string | null | undefined,
  brightness: Brightness,
  palette: readonly PaletteEntry[] = DEFAULT_PALETTE,
): string | null {
  if (!key || key === DEFAULT_NOTE_COLOR) {
    return null;
  }
  const entry = palette.find((e) => e.key === key) ?? DEFAULT_PALETTE.find((e) => e.key === key);
  if (!entry) {
    return null;
  }
  return displayFill(key, brightness === "light" ? entry.light : entry.dark, brightness);
}

/** The CSS background for a note: its fill, or the surface token. */
export function noteBackground(
  key: string | null | undefined,
  brightness: Brightness,
  palette: readonly PaletteEntry[] = DEFAULT_PALETTE,
): string {
  return noteColor(key, brightness, palette) ?? "var(--surface)";
}
