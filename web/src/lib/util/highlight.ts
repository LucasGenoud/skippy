// Search-match highlighting as plain segments. Ported from `util/highlight.dart`.

export interface HighlightSegment {
  readonly text: string;
  readonly match: boolean;
}

/**
 * [text] split so every case-insensitive occurrence of [query] is its own
 * segment. One plain segment when there is no query or no match.
 */
export function highlightSegments(text: string, query: string): HighlightSegment[] {
  const q = query.trim().toLowerCase();
  if (!q) {
    return [{ text, match: false }];
  }
  const out: HighlightSegment[] = [];
  const lower = text.toLowerCase();
  let start = 0;
  while (start < text.length) {
    const idx = lower.indexOf(q, start);
    if (idx < 0) {
      out.push({ text: text.slice(start), match: false });
      break;
    }
    if (idx > start) {
      out.push({ text: text.slice(start, idx), match: false });
    }
    out.push({ text: text.slice(idx, idx + q.length), match: true });
    start = idx + q.length;
  }
  return out.length === 0 ? [{ text, match: false }] : out;
}
