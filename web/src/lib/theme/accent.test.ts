import { readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { DEFAULT_ACCENT, themeColors, themeVariables, type Brightness, type ThemeColors } from "./accent";
import { hexToRgb } from "./color";
import oracle from "./fixtures/flutter-theme.json";

// The fixture is the real Flutter buildTheme() output for each seed, dumped by
// a throwaway flutter_test against app/lib/theme.dart.
type OracleEntry = Record<string, string>;
const entries = Object.entries(oracle as Record<string, OracleEntry>);

// Oracle key -> ThemeColors key, where they differ.
const RENAMED: Record<string, keyof ThemeColors> = {
  secondary: "secondaryTone",
  onInverseSurface: "inverseOnSurface",
};
// The neutrals are this client's own zinc scale (NEUTRAL_LIGHTNESS), so only
// the accent-derived roles still follow Flutter.
const SKIPPED = new Set([
  "scaffold",
  "canvas",
  "surface",
  "surfaceBright",
  "surfaceContainerLowest",
  "surfaceContainerLow",
  "surfaceContainer",
  "surfaceContainerHigh",
  "surfaceContainerHighest",
  "trough",
  "troughBorder",
  "onSurface",
  "onSurfaceVariant",
  "outline",
  "outlineVariant",
  "hairline",
  "hover",
  "pressed",
  "scrollbarThumb",
  "codeFill",
  "patternInk",
  "onSecondaryContainer",
  "secondaryContainer",
  "excluded",
]);

// Flutter blends washes in floating point and rounds once at the end; this
// port does the same, but a channel may land one unit apart at a .5 boundary.
const BLENDED = new Set(["secondaryContainer", "excluded"]);

function channelDistance(a: string, b: string): number {
  const ra = hexToRgb(a.slice(0, 7));
  const rb = hexToRgb(b.slice(0, 7));
  if (!ra || !rb) {
    return Infinity;
  }
  return Math.max(...ra.map((v, i) => Math.abs(v - (rb[i] ?? 0))));
}

describe("themeColors' accent roles match Flutter's buildTheme", () => {
  for (const [key, expected] of entries) {
    const [seed = "", brightness = "light"] = key.split("/");
    it(key, () => {
      const actual = themeColors(seed, brightness as Brightness);
      for (const [role, value] of Object.entries(expected)) {
        if (SKIPPED.has(role)) {
          continue;
        }
        const name = RENAMED[role] ?? (role as keyof ThemeColors);
        const got = actual[name];
        if (BLENDED.has(role)) {
          expect(channelDistance(got, value), `${role}: ${got} vs ${value}`).toBeLessThanOrEqual(1);
          continue;
        }
        expect(got, role).toBe(value);
      }
    });
  }
});

describe("themeColors", () => {
  it("falls back to the default accent for a malformed hex", () => {
    expect(themeColors("nope", "light")).toEqual(themeColors(DEFAULT_ACCENT, "light"));
  });

  it("leaves a grey seed's neutrals untinted", () => {
    const { canvas } = themeColors("#9E9E9E", "light");
    const rgb = hexToRgb(canvas);
    expect(rgb?.[0]).toBe(rgb?.[1]);
    expect(rgb?.[1]).toBe(rgb?.[2]);
  });
});

describe("globals.css", () => {
  const css = readFileSync(path.resolve(import.meta.dirname, "../../app/globals.css"), "utf8");

  function declared(selector: string): Record<string, string> {
    const start = css.indexOf(`${selector} {\n  --canvas`);
    expect(start, `${selector} block`).toBeGreaterThanOrEqual(0);
    const body = css.slice(start, css.indexOf("}", start));
    const vars: Record<string, string> = {};
    for (const match of body.matchAll(/(--[\w-]+):\s*([^;]+);/g)) {
      vars[match[1] ?? ""] = (match[2] ?? "").trim();
    }
    return vars;
  }

  it("holds the default accent's variables in both brightnesses", () => {
    expect(declared(":root")).toEqual(themeVariables(DEFAULT_ACCENT, "light"));
    expect(declared(".dark")).toEqual(themeVariables(DEFAULT_ACCENT, "dark"));
  });
});
