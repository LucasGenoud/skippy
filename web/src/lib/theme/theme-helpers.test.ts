import { afterEach, describe, expect, it, vi } from "vitest";

import { applyTheme, DEFAULT_ACCENT } from "./accent";
import { appFont, loadFont } from "./fonts";
import { labelIconFor, labelStyle, DEFAULT_LABEL_ICON, LABEL_ICONS } from "./label-style";
import { cssEase, EASE, transitionFor, TRANSITION } from "./motion";
import { DEFAULT_PALETTE, noteBackground, noteColor, paletteEntryFromJson } from "./palette";
import { NOTE_PATTERNS, notePatternFromWire, patternStyle, motifGlyph, isMotif } from "./patterns";

describe("palette", () => {
  it("resolves a key per brightness, with legacy keys from the defaults", () => {
    expect(noteColor("red", "light")).toBe("#F28B82");
    expect(noteColor("red", "dark")).toBe("#5C2B29");
    const custom = [{ key: "mint", name: "Mint", light: "#AAFFCC", dark: "#113322" }];
    expect(noteColor("mint", "dark", custom)).toBe("#113322");
    expect(noteColor("blue", "light", custom)).toBe("#AECBFA");
  });

  it("draws default and unknown keys on the surface", () => {
    expect(noteColor("default", "light")).toBeNull();
    expect(noteColor("ultraviolet", "light")).toBeNull();
    expect(noteBackground(null, "dark")).toBe("var(--surface)");
  });

  it("reads settings entries like PaletteEntry.fromJson", () => {
    expect(paletteEntryFromJson({ key: "k", name: " ", light: "#abcdef", dark: "#000000" })).toEqual({
      key: "k",
      name: "k",
      light: "#ABCDEF",
      dark: "#000000",
    });
    expect(paletteEntryFromJson({ key: "k", light: "#abc", dark: "#000000" })).toBeNull();
    expect(DEFAULT_PALETTE).toHaveLength(7);
  });
});

describe("label style", () => {
  it("tints a coloured chip and falls back to the muted text colour", () => {
    expect(labelStyle("#1a73e8")).toEqual({
      color: "#1A73E8",
      backgroundColor: "#1A73E824",
      borderColor: "#1A73E88C",
    });
    expect(labelStyle(null).color).toBe("var(--on-surface-variant)");
    expect(labelStyle("bad").backgroundColor).toBeUndefined();
  });

  it("maps every curated key and defaults the rest", () => {
    expect(Object.keys(LABEL_ICONS)).toHaveLength(31);
    expect(labelIconFor("nope")).toBe(DEFAULT_LABEL_ICON);
    expect(labelIconFor(null)).toBe(DEFAULT_LABEL_ICON);
  });
});

describe("patterns", () => {
  it("covers every NotePattern wire value", () => {
    expect(NOTE_PATTERNS.map((p) => p.id)).toHaveLength(20);
    expect(notePatternFromWire("grid")).toBe("grid");
    expect(notePatternFromWire("future")).toBe("none");
  });

  it("memoizes one mask per pattern and none for plain", () => {
    expect(patternStyle("none")).toBeNull();
    for (const { id } of NOTE_PATTERNS.slice(1)) {
      const style = patternStyle(id);
      expect(style?.maskImage, id).toMatch(/^url\("data:image\/svg\+xml,/);
      expect(patternStyle(id)).toBe(style);
    }
  });

  it("draws motifs lighter and gives each a picker glyph", () => {
    expect(isMotif("hearts")).toBe(true);
    expect(patternStyle("hearts")?.opacity).toBe(0.8);
    expect(patternStyle("dots")?.opacity).toBeUndefined();
    expect(motifGlyph("sea")?.length).toBeGreaterThan(0);
    expect(motifGlyph("dots")).toBeNull();
  });
});

describe("motion", () => {
  it("ports the Dart tokens", () => {
    expect(cssEase(EASE.emphasized)).toBe("cubic-bezier(0.2, 0, 0, 1)");
    expect(TRANSITION.base).toEqual({ duration: 0.24, ease: [0.2, 0, 0, 1] });
    expect(transitionFor(TRANSITION.base, true)).toEqual({ duration: 0 });
    expect(transitionFor(TRANSITION.fast, false)).toBe(TRANSITION.fast);
  });
});

describe("fonts", () => {
  afterEach(() => {
    document.documentElement.removeAttribute("style");
    vi.unstubAllGlobals();
  });

  it("reads unknown ids as the system font", () => {
    expect(appFont("comic").id).toBe("system");
    expect(appFont("jetBrainsMono").family).toBe("JetBrainsMono");
  });

  it("switches --font-app only once the family has loaded", async () => {
    const load = vi.fn(() => Promise.resolve([{} as FontFace]));
    Object.defineProperty(document, "fonts", { value: { load }, configurable: true });
    await expect(loadFont("lora")).resolves.toBe(true);
    expect(load).toHaveBeenCalledTimes(4);
    expect(document.documentElement.style.getPropertyValue("--font-app")).toContain('"Lora"');
  });

  it("keeps the current face when a family fails to load", async () => {
    Object.defineProperty(document, "fonts", { value: { load: () => Promise.reject(new Error("x")) }, configurable: true });
    await expect(loadFont("nunito")).resolves.toBe(false);
    expect(document.documentElement.style.getPropertyValue("--font-app")).toBe("");
  });
});

describe("applyTheme", () => {
  it("injects a non-default accent and toggles dark", () => {
    applyTheme("#1a73e8", "dark");
    const style = document.getElementById("skippy-theme");
    expect(style?.textContent).toContain("html.dark {");
    expect(style?.textContent).toContain("--primary-container: #1A73E8;");
    expect(document.documentElement.classList.contains("dark")).toBe(true);

    applyTheme(DEFAULT_ACCENT, "light");
    expect(style?.textContent).toBe("");
    expect(document.documentElement.classList.contains("dark")).toBe(false);
  });

  it("follows the system setting", () => {
    vi.stubGlobal("matchMedia", (query: string) => ({
      matches: query.includes("dark"),
      addEventListener: () => {},
      removeEventListener: () => {},
    }));
    applyTheme(DEFAULT_ACCENT, "system");
    expect(document.documentElement.classList.contains("dark")).toBe(true);
    applyTheme(DEFAULT_ACCENT, "light");
  });
});
