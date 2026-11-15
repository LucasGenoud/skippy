// Small colour helpers shared by the theme: hex parsing, HSL, blending and
// contrast. They follow Flutter's Color/HSLColor arithmetic so a value
// computed here matches theme.dart.

import type { Rgb } from "./hct";

const HEX_LENGTH = 6;
const BYTE_MAX = 255;
const HEX_RADIX = 16;
const SRGB_LINEAR_THRESHOLD = 0.03928;

export interface Hsl {
  h: number;
  s: number;
  l: number;
}

/** Parses "#RRGGBB" (the # is optional); null when it is not that. */
export function hexToRgb(hex: string | null | undefined): Rgb | null {
  if (!hex) {
    return null;
  }
  const cleaned = hex.replace("#", "").trim();
  if (cleaned.length !== HEX_LENGTH || !/^[0-9a-fA-F]+$/.test(cleaned)) {
    return null;
  }
  const value = parseInt(cleaned, HEX_RADIX);
  return [(value >> 16) & BYTE_MAX, (value >> 8) & BYTE_MAX, value & BYTE_MAX];
}

function byteHex(value: number): string {
  return Math.min(BYTE_MAX, Math.max(0, Math.round(value))).toString(HEX_RADIX).padStart(2, "0");
}

/** "#RRGGBB", upper case, as the settings document stores colours. */
export function rgbToHex(rgb: Rgb): string {
  return `#${byteHex(rgb[0])}${byteHex(rgb[1])}${byteHex(rgb[2])}`.toUpperCase();
}

/** "#RRGGBBAA" for a colour with a fractional alpha. */
export function rgbaHex(rgb: Rgb, alpha: number): string {
  return `${rgbToHex(rgb)}${byteHex(alpha * BYTE_MAX)}`.toUpperCase();
}

export function rgbToHsl(rgb: Rgb): Hsl {
  const r = rgb[0] / BYTE_MAX;
  const g = rgb[1] / BYTE_MAX;
  const b = rgb[2] / BYTE_MAX;
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const delta = max - min;
  const hexagon = 60;
  let h = 0;
  if (delta !== 0) {
    if (max === r) {
      h = hexagon * (((g - b) / delta) % 6);
    } else if (max === g) {
      h = hexagon * ((b - r) / delta + 2);
    } else {
      h = hexagon * ((r - g) / delta + 4);
    }
  }
  h = ((h % 360) + 360) % 360;
  const l = (max + min) / 2;
  const s = l === 1 ? 0 : Math.min(1, Math.max(0, delta / (1 - Math.abs(2 * l - 1))));
  return { h, s: Number.isNaN(s) ? 0 : s, l };
}

export function hslToRgb({ h, s, l }: Hsl): Rgb {
  const chroma = (1 - Math.abs(2 * l - 1)) * s;
  const secondary = chroma * (1 - Math.abs(((h / 60) % 2) - 1));
  const match = l - chroma / 2;
  const sector = Math.floor(h / 60) % 6;
  const table: readonly (readonly [number, number, number])[] = [
    [chroma, secondary, 0],
    [secondary, chroma, 0],
    [0, chroma, secondary],
    [0, secondary, chroma],
    [secondary, 0, chroma],
    [chroma, 0, secondary],
  ];
  const [r, g, b] = table[sector] ?? [0, 0, 0];
  return [
    Math.round((r + match) * BYTE_MAX),
    Math.round((g + match) * BYTE_MAX),
    Math.round((b + match) * BYTE_MAX),
  ];
}

/** `foreground` at `alpha` over an opaque `background`, rounded per channel. */
export function alphaBlend(foreground: Rgb, alpha: number, background: Rgb): Rgb {
  const mix = (f: number, b: number): number => Math.round(alpha * f + (1 - alpha) * b);
  return [mix(foreground[0], background[0]), mix(foreground[1], background[1]), mix(foreground[2], background[2])];
}

/** WCAG relative luminance, with the 0.03928 threshold Flutter uses. */
export function luminance(rgb: Rgb): number {
  const channel = (value: number): number => {
    const c = value / BYTE_MAX;
    return c <= SRGB_LINEAR_THRESHOLD ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * channel(rgb[0]) + 0.7152 * channel(rgb[1]) + 0.0722 * channel(rgb[2]);
}

export function contrastRatio(a: Rgb, b: Rgb): number {
  const l1 = luminance(a);
  const l2 = luminance(b);
  return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
}

const DARK_FILL_THRESHOLD = 0.15;

/** Whether a fill wants white text, by Flutter's `estimateBrightnessForColor` rule. */
export function isDarkColor(rgb: Rgb): boolean {
  const relative = luminance(rgb) + 0.05;
  return relative * relative <= DARK_FILL_THRESHOLD;
}
