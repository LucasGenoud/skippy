// URL detection inside plain text. Ported from `util/linkify.dart`; the span
// building is left to the components, this only finds and classifies runs.

import { highlightSegments } from "./highlight";

/** A URL inside a run of text. [url] is launchable (`www.` gets https). */
export interface UrlMatch {
  readonly start: number;
  /** Exclusive. */
  readonly end: number;
  readonly url: string;
}

const URL_PATTERN = /((https?:\/\/)|(www\.))[^\s<>]+/gi;

// Sentence punctuation and quotes that are almost never part of a URL.
const TRAILING_TRIM = ".,;:!?'\"<>«»";

const OPENER: Record<string, string> = { ")": "(", "]": "[", "}": "{" };

function count(s: string, ch: string): number {
  return s.split(ch).length - 1;
}

/** Every URL in [text], trailing punctuation and unbalanced closers trimmed. */
export function findUrls(text: string): UrlMatch[] {
  const out: UrlMatch[] = [];
  for (const m of text.matchAll(URL_PATTERN)) {
    const start = m.index;
    let end = start + m[0].length;
    while (end > start + 1) {
      const ch = text[end - 1] ?? "";
      if (TRAILING_TRIM.includes(ch)) {
        end--;
        continue;
      }
      const opener = OPENER[ch];
      if (opener) {
        const slice = text.slice(start, end);
        if (count(slice, ch) > count(slice, opener)) {
          end--;
          continue;
        }
      }
      break;
    }
    const raw = text.slice(start, end);
    const url = raw.toLowerCase().startsWith("www.") ? `https://${raw}` : raw;
    out.push({ start, end, url });
  }
  return out;
}

/** One run of text: plain, a search match, or a link. */
export type LinkedSegment =
  | { readonly kind: "text"; readonly text: string; readonly match: boolean }
  | { readonly kind: "link"; readonly text: string; readonly url: string };

/** [text] split into links and plain runs, plain runs tinted by [query]. */
export function linkedSegments(text: string, query: string): LinkedSegment[] {
  const urls = findUrls(text);
  const plain = (t: string): LinkedSegment[] =>
    highlightSegments(t, query).map((s) => ({ kind: "text", text: s.text, match: s.match }));
  if (urls.length === 0) {
    return plain(text);
  }
  const out: LinkedSegment[] = [];
  let cursor = 0;
  for (const u of urls) {
    if (u.start > cursor) {
      out.push(...plain(text.slice(cursor, u.start)));
    }
    out.push({ kind: "link", text: text.slice(u.start, u.end), url: u.url });
    cursor = u.end;
  }
  if (cursor < text.length) {
    out.push(...plain(text.slice(cursor)));
  }
  return out;
}

/**
 * The href to open for a link from untrusted content (note markdown, chat
 * output), or null: only http/https may launch. A bare `www.` is upgraded.
 */
export function safeLinkHref(url: string): string | null {
  let href = url.trim();
  if (href.toLowerCase().startsWith("www.")) {
    href = `https://${href}`;
  }
  try {
    const parsed = new URL(href);
    return parsed.protocol === "http:" || parsed.protocol === "https:" ? parsed.toString() : null;
  } catch {
    return null;
  }
}
