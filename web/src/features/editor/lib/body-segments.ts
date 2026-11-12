import { findNoteLinks, linkTitleEnd, linkTitleStart } from "@/lib/state/note-links";
import { findUrls } from "@/lib/util/linkify";

// What the body field paints under its text (`highlighted_text_field.dart`).
// The field is a plain textarea over a mirror that draws the same characters
// in colour, so every style here must keep each glyph's advance: colour,
// underline and background always; weight and slant only in markdown, whose
// source is monospace (JetBrains Mono keeps one advance across weights).
//
//     textarea   transparent text, real caret and selection
//     mirror     the same text, split into these segments

export type BodyStyle =
  | "url"
  | "linkSyntax"
  | "linkTitle"
  | "marker"
  | "bold"
  | "italic"
  | "strike"
  | "code"
  | "heading"
  | "mdLinkLabel"
  | "mdLinkUrl"
  | "match"
  | "current";

export interface BodySegment {
  readonly text: string;
  readonly styles: readonly BodyStyle[];
}

interface StyleRange {
  readonly start: number;
  readonly end: number;
  readonly style: BodyStyle;
}

export interface TextRange {
  readonly start: number;
  readonly end: number;
}

/** Every case-insensitive occurrence of [query], left to right, never overlapping. */
export function findMatches(text: string, query: string): TextRange[] {
  const needle = query.trim().toLowerCase();
  if (!needle) {
    return [];
  }
  const haystack = text.toLowerCase();
  const out: TextRange[] = [];
  let from = 0;
  for (;;) {
    const at = haystack.indexOf(needle, from);
    if (at < 0) {
      return out;
    }
    out.push({ start: at, end: at + needle.length });
    from = at + needle.length;
  }
}

function addPattern(ranges: StyleRange[], text: string, pattern: RegExp, style: BodyStyle, group = 0): void {
  for (const match of text.matchAll(pattern)) {
    const whole = match[0];
    const part = match[group];
    if (part === undefined || part.length === 0) {
      continue;
    }
    const offset = group === 0 ? 0 : whole.indexOf(part);
    const start = match.index + offset;
    ranges.push({ start, end: start + part.length, style });
  }
}

function markdownRanges(text: string): StyleRange[] {
  const ranges: StyleRange[] = [];
  for (const match of text.matchAll(/^(#{1,6})([ \t]+)(.*)$/gm)) {
    const markerEnd = match.index + (match[1]?.length ?? 0) + (match[2]?.length ?? 0);
    ranges.push({ start: match.index, end: markerEnd, style: "marker" });
    const lineEnd = match.index + match[0].length;
    if (markerEnd < lineEnd) {
      ranges.push({ start: markerEnd, end: lineEnd, style: "heading" });
    }
  }
  addPattern(ranges, text, /^\s*(?:[-+*]|\d+\.|>|-\s*\[[ xX]\])\s+/gm, "marker");
  addPattern(ranges, text, /\*\*([^\n*]+)\*\*/g, "marker");
  addPattern(ranges, text, /\*\*([^\n*]+)\*\*/g, "bold", 1);
  addPattern(ranges, text, /__([^\n_]+)__/g, "marker");
  addPattern(ranges, text, /__([^\n_]+)__/g, "bold", 1);
  addPattern(ranges, text, /~~([^\n~]+)~~/g, "strike", 1);
  addPattern(ranges, text, /`([^`\n]+)`/g, "code", 1);
  addPattern(ranges, text, /(?<!\*)\*([^*\n]+)\*(?!\*)/g, "italic", 1);
  addPattern(ranges, text, /(?<!_)_([^_\n]+)_(?!_)/g, "italic", 1);
  for (const match of text.matchAll(/\[([^\]\n]+)\]\(([^)\n]+)\)/g)) {
    const label = match[1] ?? "";
    const url = match[2] ?? "";
    const labelStart = match.index + 1;
    const urlStart = labelStart + label.length + 2;
    ranges.push({ start: labelStart, end: labelStart + label.length, style: "mdLinkLabel" });
    ranges.push({ start: urlStart, end: urlStart + url.length, style: "mdLinkUrl" });
  }
  return ranges;
}

/**
 * The body cut into runs of one style set. [markdown] adds the markdown
 * structure; [matches] are find-in-note hits, [current] the one navigated to.
 */
export function bodySegments(
  text: string,
  options: { markdown: boolean; matches?: readonly TextRange[]; current?: number },
): BodySegment[] {
  const ranges: StyleRange[] = options.markdown ? markdownRanges(text) : [];
  for (const url of findUrls(text)) {
    ranges.push({ start: url.start, end: url.end, style: "url" });
  }
  // Last among the structural ranges: a link's id stays faded whatever else matched it.
  for (const link of findNoteLinks(text)) {
    ranges.push({ start: link.start, end: linkTitleStart(link), style: "linkSyntax" });
    ranges.push({ start: linkTitleStart(link), end: linkTitleEnd(link), style: "linkTitle" });
    ranges.push({ start: linkTitleEnd(link), end: link.end, style: "linkSyntax" });
  }
  (options.matches ?? []).forEach((m, i) => {
    ranges.push({ start: m.start, end: m.end, style: i === options.current ? "current" : "match" });
  });
  if (ranges.length === 0 || text.length === 0) {
    return [{ text, styles: [] }];
  }

  const points = new Set<number>([0, text.length]);
  for (const r of ranges) {
    points.add(Math.max(0, Math.min(r.start, text.length)));
    points.add(Math.max(0, Math.min(r.end, text.length)));
  }
  const sorted = [...points].sort((a, b) => a - b);
  const out: BodySegment[] = [];
  for (let i = 0; i < sorted.length - 1; i++) {
    const start = sorted[i] ?? 0;
    const end = sorted[i + 1] ?? 0;
    if (start === end) {
      continue;
    }
    const styles: BodyStyle[] = [];
    for (const r of ranges) {
      if (r.start <= start && r.end >= end && !styles.includes(r.style)) {
        styles.push(r.style);
      }
    }
    const previous = out[out.length - 1];
    if (previous && sameStyles(previous.styles, styles)) {
      out[out.length - 1] = { text: previous.text + text.slice(start, end), styles };
    } else {
      out.push({ text: text.slice(start, end), styles });
    }
  }
  return out;
}

function sameStyles(a: readonly BodyStyle[], b: readonly BodyStyle[]): boolean {
  return a.length === b.length && a.every((s) => b.includes(s));
}
