// Note background patterns (`widgets/note_pattern.dart`, `NotePattern`).
//
// Each pattern is one SVG tile, built once and memoized as a data URI. It is
// used as a CSS mask over a fill of --pattern-ink, so the ink follows the
// theme and accent with no new image, and a card pays for one styled element
// rather than a tree of shapes.

import type { CSSProperties } from "react";

import { MOTIF_GLYPHS, type GlyphNode } from "./motif-glyphs";

export type NotePatternId =
  | "none" | "dots" | "grid" | "lines" | "diagonal" | "checks"
  | "airplanes" | "cars" | "notes" | "ideas" | "hearts" | "stars" | "coffee"
  | "leaves" | "weather" | "music" | "paws" | "space" | "sea" | "food";

/** Every pattern in picker order, with its label. Wire value is the id. */
export const NOTE_PATTERNS: readonly { id: NotePatternId; label: string }[] = [
  { id: "none", label: "Plain" },
  { id: "dots", label: "Dots" },
  { id: "grid", label: "Grid" },
  { id: "lines", label: "Lines" },
  { id: "diagonal", label: "Diagonal" },
  { id: "checks", label: "Checks" },
  { id: "airplanes", label: "Airplanes" },
  { id: "cars", label: "Cars" },
  { id: "notes", label: "Notes" },
  { id: "ideas", label: "Ideas" },
  { id: "hearts", label: "Hearts" },
  { id: "stars", label: "Stars" },
  { id: "coffee", label: "Coffee" },
  { id: "leaves", label: "Leaves" },
  { id: "weather", label: "Weather" },
  { id: "music", label: "Music" },
  { id: "paws", label: "Paws" },
  { id: "space", label: "Space" },
  { id: "sea", label: "Sea" },
  { id: "food", label: "Food" },
];

/** An unknown wire value (from a newer client) draws plain. */
export function notePatternFromWire(value: string | null | undefined): NotePatternId {
  return NOTE_PATTERNS.find((p) => p.id === value)?.id ?? "none";
}

// Spacing follows a line of body text, so ruled lines and grid cells sit at a
// handwriting scale.
const CELL = 20;
const RULED = 26;
const DOT_RADIUS = 1.3;
const DIAGONAL_STEP = CELL / 1.5;
const CHECK_ALPHA = 0.6;

// Filled glyphs carry more ink than a hairline, so motifs draw lighter.
const MOTIF_INK_SCALE = 0.8;

interface Motif {
  glyphs: readonly string[];
  /** Base rotation in degrees. */
  tilt: number;
  /** Random rotation either side of tilt, in degrees. */
  sway: number;
  seed: number;
}

// Flutter's flight icon points up and is tilted 45 degrees; lucide's plane
// already points up and right, so it keeps a tilt of 0.
const MOTIFS: Readonly<Partial<Record<NotePatternId, Motif>>> = {
  airplanes: { glyphs: ["plane"], tilt: 0, sway: 8, seed: 3 },
  cars: { glyphs: ["car", "van"], tilt: 0, sway: 6, seed: 5 },
  notes: { glyphs: ["note", "pin", "pencil"], tilt: 0, sway: 20, seed: 7 },
  ideas: { glyphs: ["bulb", "sparkles"], tilt: 0, sway: 18, seed: 11 },
  hearts: { glyphs: ["heart"], tilt: 0, sway: 22, seed: 13 },
  stars: { glyphs: ["star", "sparkles"], tilt: 0, sway: 30, seed: 17 },
  coffee: { glyphs: ["coffee", "cookie"], tilt: 0, sway: 15, seed: 19 },
  leaves: { glyphs: ["leaf", "flower", "sprout"], tilt: 0, sway: 35, seed: 23 },
  weather: { glyphs: ["sun", "cloud", "drop"], tilt: 0, sway: 10, seed: 29 },
  music: { glyphs: ["note_music", "headphones"], tilt: 0, sway: 15, seed: 31 },
  paws: { glyphs: ["paw"], tilt: 0, sway: 30, seed: 37 },
  space: { glyphs: ["rocket", "globe", "star"], tilt: 0, sway: 20, seed: 41 },
  sea: { glyphs: ["sailboat", "anchor", "waves"], tilt: 0, sway: 10, seed: 43 },
  food: { glyphs: ["pizza", "icecream", "cake"], tilt: 0, sway: 20, seed: 47 },
};

const MOTIF_CELL = 36;
const CELLS_PER_TILE = 4;
const MOTIF_TILE = MOTIF_CELL * CELLS_PER_TILE;
const GLYPH_SIZE = 15;
const GLYPH_GRID = 24;
const JITTER = 4;
const MIN_SCALE = 0.85;
const SCALE_RANGE = 0.3;
// Half a glyph's diagonal at full scale: past this from an edge it wraps.
const GLYPH_REACH = 13;

/** Whether a pattern is a scatter of pictures rather than a texture. */
export function isMotif(pattern: NotePatternId): boolean {
  return pattern in MOTIFS;
}

/** The picture standing for a motif in a picker; null for textures. */
export function motifGlyph(pattern: NotePatternId): readonly GlyphNode[] | null {
  const name = MOTIFS[pattern]?.glyphs[0];
  return name ? (MOTIF_GLYPHS[name] ?? null) : null;
}

/** A glyph's nodes as SVG markup, on lucide's 24-unit grid. */
export function glyphMarkup(nodes: readonly GlyphNode[]): string {
  return nodes
    .map(([tag, attrs]) => {
      const attributes = Object.entries(attrs)
        .map(([name, value]) => `${name}="${value}"`)
        .join(" ");
      return `<${tag} ${attributes}/>`;
    })
    .join("");
}

// mulberry32: a small seeded generator, so a motif lays out the same way on
// every load.
function seededRandom(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const round = (n: number): number => Math.round(n * 100) / 100;

function motifTile(motif: Motif): string {
  const random = seededRandom(motif.seed);
  const offset = (): number => (random() * 2 - 1) * JITTER;
  const glyphs = motif.glyphs.map((name) => glyphMarkup(MOTIF_GLYPHS[name] ?? []));
  const parts: string[] = [];

  // Odd rows shift half a cell, like bricks; with an even row count the shift
  // still lines up across tile seams.
  for (let row = 0; row < CELLS_PER_TILE; row++) {
    const shift = row % 2 === 1 ? MOTIF_CELL / 2 : 0;
    for (let column = 0; column < CELLS_PER_TILE; column++) {
      const glyph = glyphs[(row * CELLS_PER_TILE + column + row) % glyphs.length] ?? "";
      const x = column * MOTIF_CELL + MOTIF_CELL / 2 + shift + offset();
      const y = row * MOTIF_CELL + MOTIF_CELL / 2 + offset();
      const turn = motif.tilt + (random() * 2 - 1) * motif.sway;
      const scale = ((MIN_SCALE + random() * SCALE_RANGE) * GLYPH_SIZE) / GLYPH_GRID;
      const at = (cx: number): string =>
        `<g transform="translate(${round(cx)} ${round(y)}) rotate(${round(turn)}) scale(${round(scale)}) translate(-12 -12)">${glyph}</g>`;
      parts.push(at(x));
      if (x + GLYPH_REACH > MOTIF_TILE) {
        parts.push(at(x - MOTIF_TILE));
      }
    }
  }
  const body = parts.join("");
  return `<g fill="none" stroke="#000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${body}</g>`;
}

interface Tile {
  width: number;
  height: number;
  body: string;
}

function textureTile(pattern: NotePatternId): Tile | null {
  switch (pattern) {
    case "dots":
      return { width: CELL, height: CELL, body: `<circle cx="${CELL / 2}" cy="${CELL / 2}" r="${DOT_RADIUS}"/>` };
    case "grid":
      return {
        width: CELL,
        height: CELL,
        body: `<rect x="${CELL - 1}" width="1" height="${CELL}"/><rect y="${CELL - 1}" width="${CELL}" height="1"/>`,
      };
    case "lines":
      return { width: CELL, height: RULED, body: `<rect y="${RULED - 1}" width="${CELL}" height="1"/>` };
    case "diagonal": {
      const s = round(DIAGONAL_STEP);
      return {
        width: s,
        height: s,
        body: `<path d="M${-s} 0L${s} ${2 * s}M0 0L${s} ${s}M0 ${-s}L${2 * s} ${s}" stroke="#000" stroke-width="1"/>`,
      };
    }
    case "checks":
      return {
        width: CELL * 2,
        height: CELL * 2,
        body: `<g fill-opacity="${CHECK_ALPHA}"><rect width="${CELL}" height="${CELL}"/><rect x="${CELL}" y="${CELL}" width="${CELL}" height="${CELL}"/></g>`,
      };
    default:
      return null;
  }
}

function tileFor(pattern: NotePatternId): Tile | null {
  const motif = MOTIFS[pattern];
  if (motif) {
    return { width: MOTIF_TILE, height: MOTIF_TILE, body: motifTile(motif) };
  }
  return textureTile(pattern);
}

const styleCache = new Map<NotePatternId, CSSProperties | null>();

/**
 * Inline style for an overlay element that draws `pattern` in --pattern-ink:
 * a mask from one memoized tile, repeated. Null for "none".
 */
export function patternStyle(pattern: NotePatternId): CSSProperties | null {
  const cached = styleCache.get(pattern);
  if (cached !== undefined) {
    return cached;
  }

  const tile = tileFor(pattern);
  if (!tile) {
    styleCache.set(pattern, null);
    return null;
  }
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${tile.width}" height="${tile.height}" viewBox="0 0 ${tile.width} ${tile.height}">${tile.body}</svg>`;
  const image = `url("data:image/svg+xml,${encodeURIComponent(svg)}")`;
  const size = `${tile.width}px ${tile.height}px`;
  const style: CSSProperties = {
    backgroundColor: "var(--pattern-ink)",
    maskImage: image,
    WebkitMaskImage: image,
    maskSize: size,
    WebkitMaskSize: size,
    maskRepeat: "repeat",
    WebkitMaskRepeat: "repeat",
    opacity: isMotif(pattern) ? MOTIF_INK_SCALE : undefined,
  };
  styleCache.set(pattern, style);
  return style;
}
