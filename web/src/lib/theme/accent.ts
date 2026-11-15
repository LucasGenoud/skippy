// The app's colour system, ported from app/lib/theme.dart.
//
// THE DEPTH MODEL. Three layers, and every surface in the app is one of them:
//
//   canvas  (--canvas, Flutter surfaceDim)  the ground; the page background only
//   surface (--surface)                     rises off it: cards, top bar, sidebar,
//                                           dialogs, menus, toasts
//   trough  (--trough, boardColumnColor)    recesses into it: board columns
//
// Neutrals are a zinc-like grey scale carrying the accent's HSL hue at a low
// saturation, so amber gives stone, blue gives slate, and changing the accent
// retints every surface. Their lightness steps are this client's own (the
// Flutter port used Material's tonal palettes); the accent roles below still
// come from those palettes. The accent
// has two roles: `primary` (Material's tone 40/80 of it, readable as text and
// icons on a surface) and `primaryContainer` (the accent itself, as a fill),
// with `onPrimaryContainer` picked for legibility on it.

import { prefersReducedMotion } from "./motion";
import { alphaBlend, contrastRatio, hexToRgb, hslToRgb, rgbaHex, rgbToHex, rgbToHsl, type Hsl } from "./color";
import { hctHue, hctToRgb, type Rgb } from "./hct";

export type Brightness = "light" | "dark";
export type ThemeMode = Brightness | "system";

/** Amber, the out-of-the-box accent (`kDefaultAccent`). */
export const DEFAULT_ACCENT = "#FBBC04";

/** The preset row in Settings (`kAccentPresets`), default first. */
export const ACCENT_PRESETS: readonly { hex: string; name: string }[] = [
  { hex: DEFAULT_ACCENT, name: "Amber" },
  { hex: "#FF7043", name: "Deep orange" },
  { hex: "#EA4335", name: "Red" },
  { hex: "#D81B60", name: "Pink" },
  { hex: "#9334E6", name: "Purple" },
  { hex: "#3F51B5", name: "Indigo" },
  { hex: "#1A73E8", name: "Blue" },
  { hex: "#00897B", name: "Teal" },
  { hex: "#188038", name: "Green" },
  { hex: "#5F6368", name: "Slate" },
];

/** The wider board in the custom-accent dialog. */
export const ACCENT_BOARD: readonly string[] = [
  "#FBBC04", "#F9AB00", "#FF7043", "#EA4335", "#D81B60", "#9334E6", "#7C4DFF", "#3F51B5",
  "#1A73E8", "#039BE5", "#00897B", "#188038", "#7CB342", "#8D6E63", "#5F6368",
];

const WHITE: Rgb = [255, 255, 255];
const INK: Rgb = [0x1b, 0x1a, 0x16];
const SHADOW_INK: Rgb = [0x0d, 0x10, 0x1a];

// How much accent a wash carries over the surface (selected row, active chip).
const WASH_ALPHA = { light: 0.34, dark: 0.3 } as const;

// Saturation of the neutrals, and the seed saturation under which the HSL hue
// is noise (a grey seed would otherwise tint the app pink).
const NEUTRAL_TINT = { light: 0.06, dark: 0.05 } as const;
const MIN_TINTABLE_SATURATION = 0.06;

// Lightness of each neutral role, [light, dark]: a zinc scale, where the
// canvas sits a step under white surfaces and edges are one quiet line.
const NEUTRAL_LIGHTNESS = {
  canvas: [0.975, 0.045],
  surface: [1, 0.1],
  surfaceBright: [1, 0.17],
  surfaceContainerLowest: [1, 0.03],
  surfaceContainerLow: [0.982, 0.11],
  surfaceContainer: [0.962, 0.13],
  surfaceContainerHigh: [0.945, 0.15],
  surfaceContainerHighest: [0.915, 0.17],
  trough: [0.945, 0.07],
  troughBorder: [0.905, 0.095],
  onSurface: [0.06, 0.96],
  onSurfaceVariant: [0.4, 0.66],
  outline: [0.66, 0.44],
  outlineVariant: [0.9, 0.18],
} as const;
type NeutralRole = keyof typeof NEUTRAL_LIGHTNESS;

// White wins unless ink is clearly the more legible text on the accent.
const INK_PREFERENCE = 1.2;

// Material's tonal-spot palettes: chroma per palette, and the tone each role
// takes at standard contrast, [light, dark]. These tones already satisfy every
// contrast curve at level 0, so no adjustment applies.
const CHROMA = { primary: 36, secondary: 16, tertiary: 24, neutral: 6, neutralVariant: 8, error: 84 } as const;
const ERROR_HUE = 25;
const TERTIARY_HUE_SHIFT = 60;

type PaletteName = keyof typeof CHROMA;
const ROLE_TONES: Readonly<Record<string, readonly [PaletteName, number, number]>> = {
  primary: ["primary", 40, 80],
  onPrimary: ["primary", 100, 20],
  secondaryTone: ["secondary", 40, 80],
  tertiary: ["tertiary", 40, 80],
  error: ["error", 40, 80],
  onError: ["error", 100, 20],
  errorContainer: ["error", 90, 30],
  onErrorContainer: ["error", 30, 90],
  inverseSurface: ["neutral", 20, 90],
  inverseOnSurface: ["neutral", 95, 20],
};

/** Every colour the theme derives from one accent, as "#RRGGBB" or "#RRGGBBAA". */
export interface ThemeColors {
  canvas: string;
  surface: string;
  surfaceBright: string;
  surfaceContainerLowest: string;
  surfaceContainerLow: string;
  surfaceContainer: string;
  surfaceContainerHigh: string;
  surfaceContainerHighest: string;
  trough: string;
  troughBorder: string;
  onSurface: string;
  onSurfaceVariant: string;
  outline: string;
  outlineVariant: string;
  hairline: string;
  primary: string;
  onPrimary: string;
  primaryContainer: string;
  onPrimaryContainer: string;
  secondaryTone: string;
  tertiary: string;
  secondaryContainer: string;
  onSecondaryContainer: string;
  error: string;
  onError: string;
  errorContainer: string;
  onErrorContainer: string;
  inverseSurface: string;
  inverseOnSurface: string;
  excluded: string;
  codeFill: string;
  patternInk: string;
  hover: string;
  pressed: string;
  scrollbarThumb: string;
}

function withLightness(hsl: Hsl, lightness: number): Rgb {
  return hslToRgb({ ...hsl, l: Math.min(1, Math.max(0, lightness)) });
}

function onAccent(fill: Rgb): Rgb {
  return contrastRatio(INK, fill) > contrastRatio(WHITE, fill) * INK_PREFERENCE ? INK : WHITE;
}

/** The accent's RGB, or the default's for anything that is not "#RRGGBB". */
function seedOf(accentHex: string): Rgb {
  return hexToRgb(accentHex) ?? (hexToRgb(DEFAULT_ACCENT) as Rgb);
}

function schemeRoles(seed: Rgb, brightness: Brightness): Record<string, Rgb> {
  const hue = hctHue(seed);
  const hues: Record<PaletteName, number> = {
    primary: hue,
    secondary: hue,
    tertiary: (hue + TERTIARY_HUE_SHIFT) % 360,
    neutral: hue,
    neutralVariant: hue,
    error: ERROR_HUE,
  };
  const roles: Record<string, Rgb> = {};
  for (const [role, [palette, lightTone, darkTone]] of Object.entries(ROLE_TONES)) {
    roles[role] = hctToRgb(hues[palette], CHROMA[palette], brightness === "light" ? lightTone : darkTone);
  }
  return roles;
}

const colorCache = new Map<string, ThemeColors>();

/** The full colour set for an accent and brightness (`buildTheme`). Memoized. */
export function themeColors(accentHex: string, brightness: Brightness): ThemeColors {
  const seed = seedOf(accentHex);
  const key = `${rgbToHex(seed)}/${brightness}`;
  const cached = colorCache.get(key);
  if (cached) {
    return cached;
  }

  const light = brightness === "light";
  const seedHsl = rgbToHsl(seed);
  const tint = seedHsl.s < MIN_TINTABLE_SATURATION ? 0 : NEUTRAL_TINT[brightness];
  const neutral = (name: NeutralRole): Rgb =>
    withLightness({ h: seedHsl.h, s: tint, l: 0 }, NEUTRAL_LIGHTNESS[name][light ? 0 : 1]);

  const surface = neutral("surface");
  const roles = schemeRoles(seed, brightness);
  const role = (name: string): Rgb => roles[name] ?? WHITE;
  const onSurface = neutral("onSurface");
  const washAlpha = WASH_ALPHA[brightness];

  const colors: ThemeColors = {
    canvas: rgbToHex(neutral("canvas")),
    surface: rgbToHex(surface),
    surfaceBright: rgbToHex(neutral("surfaceBright")),
    surfaceContainerLowest: rgbToHex(neutral("surfaceContainerLowest")),
    surfaceContainerLow: rgbToHex(neutral("surfaceContainerLow")),
    surfaceContainer: rgbToHex(neutral("surfaceContainer")),
    surfaceContainerHigh: rgbToHex(neutral("surfaceContainerHigh")),
    surfaceContainerHighest: rgbToHex(neutral("surfaceContainerHighest")),
    trough: rgbToHex(neutral("trough")),
    troughBorder: rgbToHex(neutral("troughBorder")),
    onSurface: rgbToHex(onSurface),
    onSurfaceVariant: rgbToHex(neutral("onSurfaceVariant")),
    outline: rgbToHex(neutral("outline")),
    outlineVariant: rgbToHex(neutral("outlineVariant")),
    hairline: rgbToHex(neutral("outlineVariant")),
    primary: rgbToHex(role("primary")),
    onPrimary: rgbToHex(role("onPrimary")),
    primaryContainer: rgbToHex(seed),
    onPrimaryContainer: rgbToHex(onAccent(seed)),
    secondaryTone: rgbToHex(role("secondaryTone")),
    tertiary: rgbToHex(role("tertiary")),
    secondaryContainer: rgbToHex(alphaBlend(seed, washAlpha, surface)),
    onSecondaryContainer: rgbToHex(onSurface),
    error: rgbToHex(role("error")),
    onError: rgbToHex(role("onError")),
    errorContainer: rgbToHex(role("errorContainer")),
    onErrorContainer: rgbToHex(role("onErrorContainer")),
    inverseSurface: rgbToHex(role("inverseSurface")),
    inverseOnSurface: rgbToHex(role("inverseOnSurface")),
    excluded: rgbToHex(alphaBlend(role("error"), washAlpha, surface)),
    codeFill: rgbaHex(onSurface, light ? 0.06 : 0.09),
    patternInk: rgbaHex(onSurface, light ? 0.09 : 0.12),
    hover: rgbaHex(onSurface, light ? 0.045 : 0.06),
    pressed: rgbaHex(onSurface, light ? 0.08 : 0.1),
    scrollbarThumb: rgbaHex(onSurface, 0.16),
  };
  colorCache.set(key, colors);
  return colors;
}

// ---------------------------------------------------------------------------
// Shadows (`cardShadow`). Flutter's blur radius r is a Gaussian of sigma
// 0.57735r + 0.5; a CSS blur b is one of sigma b/2.

const BLUR_SIGMA_SCALE = 0.57735;
const BLUR_SIGMA_OFFSET = 0.5;

interface ShadowLayer {
  y: number;
  blur: number;
  spread: number;
  alpha: Record<Brightness, number>;
}

function cssBlur(flutterRadius: number): number {
  return Math.round(2 * (flutterRadius * BLUR_SIGMA_SCALE + BLUR_SIGMA_OFFSET) * 10) / 10;
}

function shadowCss(layers: readonly ShadowLayer[], brightness: Brightness): string {
  return layers
    .map((l) => `0 ${l.y}px ${cssBlur(l.blur)}px ${l.spread}px ${rgbaHex(SHADOW_INK, l.alpha[brightness])}`)
    .join(", ");
}

// Barely there at rest (the card's edge does the work), a soft lift on hover.
const RESTING: readonly ShadowLayer[] = [
  { y: 1, blur: 1, spread: 0, alpha: { light: 0.04, dark: 0.3 } },
  { y: 4, blur: 10, spread: -6, alpha: { light: 0.06, dark: 0.3 } },
];
const RAISED: readonly ShadowLayer[] = [
  { y: 8, blur: 20, spread: -8, alpha: { light: 0.12, dark: 0.48 } },
  { y: 1, blur: 3, spread: -1, alpha: { light: 0.06, dark: 0.32 } },
];
// Dialogs float over a scrim, so they take the raised pair plus a long drop.
const DIALOG: readonly ShadowLayer[] = [
  ...RAISED,
  { y: 20, blur: 40, spread: -12, alpha: { light: 0.18, dark: 0.5 } },
];

// Syntax colours for code blocks (`codeSyntaxColors`), fixed per brightness.
const SYNTAX = {
  keyword: { light: "#8E3FB5", dark: "#D7A2F0" },
  string: { light: "#2F7D32", dark: "#9CD69A" },
  number: { light: "#B35A00", dark: "#F2B572" },
  type: { light: "#0B6E99", dark: "#7FCBEB" },
  call: { light: "#3A55B5", dark: "#A6B8F5" },
} as const;

// Snack icon chips without a scheme slot (`_chipColors`).
const SNACK = {
  successBg: { light: "#D5EFDD", dark: "#163521" },
  successFg: { light: "#0E5A2B", dark: "#9BE0AE" },
  warningBg: { light: "#FBE9C7", dark: "#3A2E12" },
  warningFg: { light: "#7A5300", dark: "#F3C778" },
} as const;

function kebab(name: string): string {
  return name.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);
}

/**
 * Every CSS custom property the theme sets, for an accent and brightness:
 * `{ "--canvas": "#ECEAE5", ... }`. globals.css holds the default accent's.
 */
export function themeVariables(accentHex: string, brightness: Brightness): Record<string, string> {
  const vars: Record<string, string> = {};
  for (const [name, value] of Object.entries(themeColors(accentHex, brightness))) {
    vars[`--${kebab(name)}`] = value;
  }
  vars["--elevation-resting"] = shadowCss(RESTING, brightness);
  vars["--elevation-raised"] = shadowCss(RAISED, brightness);
  vars["--elevation-dialog"] = shadowCss(DIALOG, brightness);
  for (const [name, value] of Object.entries(SYNTAX)) {
    vars[`--code-${name}`] = value[brightness];
  }
  for (const [name, value] of Object.entries(SNACK)) {
    vars[`--snack-${kebab(name)}`] = value[brightness];
  }
  return vars;
}

function block(selector: string, vars: Record<string, string>): string {
  const body = Object.entries(vars)
    .map(([name, value]) => `  ${name}: ${value};`)
    .join("\n");
  return `${selector} {\n${body}\n}`;
}

/** Selectors for the two blocks: globals.css's, and the runtime override's. */
const STATIC_SELECTORS = { light: ":root", dark: ".dark" } as const;
// One element more specific, so an injected accent beats globals.css however
// the bundler orders the stylesheets; dark still follows light within it.
const RUNTIME_SELECTORS = { light: "html:root", dark: "html.dark" } as const;

/** The light and dark rules for an accent, as globals.css writes them. */
export function themeCss(accentHex: string, selectors: { light: string; dark: string } = STATIC_SELECTORS): string {
  const light = block(selectors.light, themeVariables(accentHex, "light"));
  return `${light}\n\n${block(selectors.dark, themeVariables(accentHex, "dark"))}`;
}

/** The toned `primary` an accent produces, for previewing a custom accent. */
export function accentPreview(accentHex: string, brightness: Brightness): string {
  return themeColors(accentHex, brightness).primary;
}

/**
 * Runs [change] (a theme switch) as one cross-fade of the whole page through
 * the View Transitions API: the browser fades a snapshot of the old colours
 * into the new ones, so no element needs a colour transition of its own.
 * Where the API is missing, or motion is reduced, the change is immediate.
 */
export function fadeTheme(change: () => void): void {
  const start = typeof document === "undefined" ? undefined : document.startViewTransition?.bind(document);
  if (!start || prefersReducedMotion()) {
    change();
    return;
  }
  // A skipped transition (a hidden tab, one already running) rejects all three;
  // the change itself has still been applied, so there is nothing to handle.
  const transition = start(change);
  const ignore = (): void => undefined;
  transition.ready.catch(ignore);
  transition.finished.catch(ignore);
  transition.updateCallbackDone.catch(ignore);
}

const STYLE_ID = "skippy-theme";
const DARK_QUERY = "(prefers-color-scheme: dark)";
let systemQuery: MediaQueryList | null = null;
let systemListener: (() => void) | null = null;

function setDark(dark: boolean): void {
  const root = document.documentElement;
  root.classList.toggle("dark", dark);
  root.style.colorScheme = dark ? "dark" : "light";
}

/**
 * Retints the app for an accent and applies the light/dark mode. The colours go
 * into one injected stylesheet (both brightnesses), so toggling the `dark`
 * class never fights inline styles; "system" follows the OS live.
 */
export function applyTheme(accentHex: string, mode: ThemeMode): void {
  if (typeof document === "undefined") {
    return;
  }

  const normalized = hexToRgb(accentHex) ? accentHex.toUpperCase() : DEFAULT_ACCENT;
  let style = document.getElementById(STYLE_ID);
  if (!style) {
    style = document.createElement("style");
    style.id = STYLE_ID;
    document.head.appendChild(style);
  }
  if (style.dataset.accent !== normalized) {
    style.textContent = normalized === DEFAULT_ACCENT ? "" : themeCss(normalized, RUNTIME_SELECTORS);
    style.dataset.accent = normalized;
  }

  if (systemQuery && systemListener) {
    systemQuery.removeEventListener("change", systemListener);
    systemQuery = null;
    systemListener = null;
  }
  if (mode !== "system") {
    setDark(mode === "dark");
    return;
  }

  const query = window.matchMedia(DARK_QUERY);
  const listener = (): void => setDark(query.matches);
  query.addEventListener("change", listener);
  systemQuery = query;
  systemListener = listener;
  listener();
}
