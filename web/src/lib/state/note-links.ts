import type { Note } from "@/lib/models/note";
import { noteDisplayTitle } from "./display-title";

// Links between notes, written into a note's text as `[[id|Title]]`. The id
// is what a link follows; the title shows where the live title is unknown.
// Ported from `state/note_links.dart`.
//
//     see [[3f2c…-…|Groceries]] for the list
//         └──┬───┘ └───┬───┘
//          hidden    shown

/** Scheme of the markdown hrefs [markdownNoteLinks] writes. */
export const NOTE_LINK_SCHEME = "skippy-note";

const UUID_LENGTH = 36;
const MAX_TITLE_LENGTH = 80;
const MAX_QUERY_LENGTH = 60;
const DEFAULT_CANDIDATES = 6;

const linkPattern = (): RegExp => /\[\[([0-9a-fA-F-]{36})\|([^[\]\n]*)\]\]/g;
const OPEN_LINK_PATTERN = new RegExp(`\\[\\[([^\\[\\]\\n|]{0,${MAX_QUERY_LENGTH}})$`);
const TITLE_UNSAFE = /[[\]|\r\n]/g;
const SPACES = /\s+/g;

export interface NoteLink {
  /** Bounds of the whole token. */
  readonly start: number;
  readonly end: number;
  readonly noteId: string;
  readonly title: string;
}

/** Bounds of the visible title inside the token. */
export const linkTitleStart = (link: NoteLink): number => link.start + 3 + UUID_LENGTH;
export const linkTitleEnd = (link: NoteLink): number => link.end - 2;

export function findNoteLinks(text: string): NoteLink[] {
  return Array.from(text.matchAll(linkPattern()), (m) => ({
    start: m.index,
    end: m.index + m[0].length,
    noteId: m[1] ?? "",
    title: m[2] ?? "",
  }));
}

/** The token linking to [noteId]; characters that would end it become spaces. */
export function noteLinkToken(noteId: string, title: string): string {
  let clean = title.replace(TITLE_UNSAFE, " ").replace(SPACES, " ").trim();
  if (clean.length > MAX_TITLE_LENGTH) {
    clean = clean.slice(0, MAX_TITLE_LENGTH).trim();
  }
  if (!clean) {
    clean = "Untitled note";
  }
  return `[[${noteId}|${clean}]]`;
}

/** What a link to [note] is called. */
export const noteLinkTitle = (note: Note): string => noteDisplayTitle(note);

type TitleFor = (id: string) => string | null | undefined;

/** [text] with each link shown as its title. */
export function plainNoteLinks(text: string, titleFor?: TitleFor): string {
  return text.replace(linkPattern(), (_m, id: string, title: string) => titleFor?.(id) ?? title);
}

/** [text] with each link as a markdown link [noteIdFromHref] can follow. */
export function markdownNoteLinks(text: string, titleFor?: TitleFor): string {
  return text.replace(linkPattern(), (_m, id: string, title: string) => `[${titleFor?.(id) ?? title}](${NOTE_LINK_SCHEME}:${id})`);
}

export function noteIdFromHref(href: string): string | null {
  const prefix = `${NOTE_LINK_SCHEME}:`;
  return href.startsWith(prefix) ? href.slice(prefix.length) : null;
}

/** [text] with links to the keys of [ids] pointing at their values instead. */
export function remapNoteLinks(text: string, ids: Readonly<Record<string, string>>): string {
  return text.replace(linkPattern(), (whole, id: string, title: string) => {
    const target = ids[id];
    return target === undefined ? whole : `[[${target}|${title}]]`;
  });
}

/** While a link is being typed (`[[gro|` with the caret at `|`), the text after `[[`. */
export function openLinkQuery(text: string, caret: number): string | null {
  if (caret < 0 || caret > text.length) {
    return null;
  }
  return OPEN_LINK_PATTERN.exec(text.slice(0, caret))?.[1] ?? null;
}

const byEditedDesc = (a: Note, b: Note): number => b.updatedAt.getTime() - a.updatedAt.getTime();

/** Notes whose text links to [noteId], most recently edited first. */
export function backlinksTo(noteId: string, notes: Iterable<Note>): Note[] {
  const needle = `[[${noteId}|`;
  const out: Note[] = [];
  for (const note of notes) {
    if (!note.trashed && note.id !== noteId && note.content.includes(needle)) {
      out.push(note);
    }
  }
  return out.sort(byEditedDesc);
}

/** Notes a link typed as `[[query` could point at, most recently edited first. */
export function linkCandidates(notes: Iterable<Note>, query: string, excludeId?: string | null, limit = DEFAULT_CANDIDATES): Note[] {
  const needle = query.trim().toLowerCase();
  const matches: Note[] = [];
  for (const note of notes) {
    if (note.trashed || note.id === excludeId) {
      continue;
    }
    if (!needle || note.title.toLowerCase().includes(needle) || note.content.toLowerCase().includes(needle)) {
      matches.push(note);
    }
  }
  return matches.sort(byEditedDesc).slice(0, limit);
}

/** A caret that landed inside a link moves to the edge it was heading for. */
export function snapOutOfLinks(text: string, offset: number, previous: number): number {
  for (const link of findNoteLinks(text)) {
    if (offset <= link.start || offset >= link.end) {
      continue;
    }
    if (offset > previous) {
      return link.end;
    }
    if (offset < previous) {
      return link.start;
    }
    return offset - link.start < link.end - offset ? link.start : link.end;
  }
  return offset;
}

export interface TextEdit {
  readonly text: string;
  /** Collapsed caret offset after the edit. */
  readonly caret: number;
}

/**
 * An edit that removes part of a link removes the whole link, so a backspace
 * after one deletes it instead of exposing its id. Returns null when the edit
 * should go through unchanged (the `NoteLinkFormatter` rule, for inputs).
 */
export function widenLinkDeletion(before: string, after: string): TextEdit | null {
  if (after.length >= before.length || !before.includes("[[")) {
    return null;
  }
  const shorter = after.length;
  let prefix = 0;
  while (prefix < shorter && before[prefix] === after[prefix]) {
    prefix++;
  }
  let suffix = 0;
  while (suffix < shorter - prefix && before[before.length - 1 - suffix] === after[after.length - 1 - suffix]) {
    suffix++;
  }
  let start = prefix;
  let end = before.length - suffix;
  const inserted = after.slice(prefix, after.length - suffix);
  let widened = false;
  for (const link of findNoteLinks(before)) {
    const overlaps = start < link.end && end > link.start;
    const partial = start > link.start || end < link.end;
    if (!overlaps || !partial) {
      continue;
    }
    start = Math.min(start, link.start);
    end = Math.max(end, link.end);
    widened = true;
  }
  if (!widened) {
    return null;
  }
  return { text: before.slice(0, start) + inserted + before.slice(end), caret: start + inserted.length };
}
