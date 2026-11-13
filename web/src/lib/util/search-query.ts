import { isAudioAttachment, isChecklist, isImageAttachment, isNoteShared, hasReminder, NOTE_KINDS, type Label, type Note } from "@/lib/models/note";
import { findUrls } from "./linkify";

// Parsing for the search box, where `label:work is:pinned milk` narrows by
// structure as well as by text. Ported from `util/search_query.dart`: the same
// parse drives filtering, match highlighting, and smart views.

/**
 * The `field:` prefixes the box understands. Unknown prefixes stay free text
 * (`https://x` must not parse as the field `https`). Every field has a
 * spelling that excludes: `hasnot:link` is `-has:link`.
 */
export const FILTER_FIELDS = {
  label: { keywords: ["label", "tag"], negated: ["notlabel", "nottag"] },
  state: { keywords: ["is"], negated: ["isnot"] },
  has: { keywords: ["has"], negated: ["hasnot"] },
  color: { keywords: ["color", "colour"], negated: ["notcolor", "notcolour"] },
  kind: { keywords: ["kind", "type"], negated: ["notkind", "nottype"] },
} as const;
export type FilterField = keyof typeof FILTER_FIELDS;

const FIELD_ORDER: readonly FilterField[] = ["label", "state", "has", "color", "kind"];

/** The canonical spelling of [field] for a filter that does or does not negate. */
export function filterKeyword(field: FilterField, negated: boolean): string {
  const spec = FILTER_FIELDS[field];
  return negated ? spec.negated[0] : spec.keywords[0];
}

function resolveKeyword(word: string): { field: FilterField; negated: boolean } | null {
  for (const field of FIELD_ORDER) {
    const spec = FILTER_FIELDS[field];
    if ((spec.keywords as readonly string[]).includes(word)) {
      return { field, negated: false };
    }
    if ((spec.negated as readonly string[]).includes(word)) {
      return { field, negated: true };
    }
  }
  return null;
}

/** Values `is:` accepts. Anything else matches nothing. */
export const STATE_VALUES = ["pinned", "archived", "trashed", "shared", "done", "open"] as const;

/** Values `has:` accepts. */
export const HAS_VALUES = ["reminder", "attachment", "image", "audio", "link", "label"] as const;

/** One `field:value` term. Equality is about meaning, not spelling. */
export interface SearchFilter {
  readonly field: FilterField;
  /** Lowercased, quotes stripped. */
  readonly value: string;
  readonly negated: boolean;
}

export function filtersEqual(a: SearchFilter | null, b: SearchFilter | null): boolean {
  if (a === null || b === null) {
    return a === b;
  }
  return a.field === b.field && a.value === b.value && a.negated === b.negated;
}

/** The canonical spelling: `hasnot:link`. */
export function filterToString(filter: SearchFilter): string {
  return `${filterKeyword(filter.field, filter.negated)}:${filter.value}`;
}

/** One run of free text; quoted runs keep their spaces. */
export interface SearchTerm {
  readonly text: string;
  readonly negated: boolean;
}

/** Which note state an explicit `is:` filter asks a view to reveal. */
export type StateOverride = "archived" | "trashed";

/** A parsed query. Every term and filter must match (ANDed). */
export interface SearchQuery {
  readonly terms: readonly SearchTerm[];
  readonly filters: readonly SearchFilter[];
}

export const EMPTY_QUERY: SearchQuery = { terms: [], filters: [] };

export const isQueryEmpty = (q: SearchQuery): boolean => q.terms.length === 0 && q.filters.length === 0;

/** The positive free text alone, for match highlighting. */
export function queryText(q: SearchQuery): string {
  return q.terms
    .filter((t) => !t.negated)
    .map((t) => t.text)
    .join(" ");
}

/** The state an explicit positive `is:` asks for, when a view would hide it. */
export function stateOverride(q: SearchQuery): StateOverride | null {
  let archived = false;
  for (const f of q.filters) {
    if (f.field !== "state" || f.negated) {
      continue;
    }
    if (f.value === "trashed") {
      return "trashed";
    }
    if (f.value === "archived") {
      archived = true;
    }
  }
  return archived ? "archived" : null;
}

/** The structural filters alone, for the semantic path. */
export function filtersOnly(q: SearchQuery): SearchQuery {
  return { terms: [], filters: q.filters };
}

/** Operators the parser recognized but cannot satisfy. */
export function unknownFilters(q: SearchQuery): SearchFilter[] {
  return q.filters.filter((f) => {
    switch (f.field) {
      case "state":
        return !(STATE_VALUES as readonly string[]).includes(f.value);
      case "has":
        return !(HAS_VALUES as readonly string[]).includes(f.value);
      case "kind":
        return !(NOTE_KINDS as readonly string[]).includes(f.value);
      default:
        return false;
    }
  });
}

/** Workspace facts a query needs beyond the note itself. */
export interface SearchContext {
  readonly labelsById: ReadonlyMap<string, Label>;
  /** Lowercased name to every id carrying it (names repeat across workspaces). */
  readonly labelIdsByName: ReadonlyMap<string, ReadonlySet<string>>;
}

export function searchContext(labels: Iterable<Label>): SearchContext {
  const byId = new Map<string, Label>();
  const byName = new Map<string, Set<string>>();
  for (const label of labels) {
    byId.set(label.id, label);
    const key = label.name.toLowerCase();
    const set = byName.get(key) ?? new Set<string>();
    set.add(label.id);
    byName.set(key, set);
  }
  return { labelsById: byId, labelIdsByName: byName };
}

export function queryMatches(q: SearchQuery, note: Note, context: SearchContext): boolean {
  for (const term of q.terms) {
    if (containsText(note, term.text, context) === term.negated) {
      return false;
    }
  }
  for (const filter of q.filters) {
    if (matchesFilter(note, filter, context) === filter.negated) {
      return false;
    }
  }
  return true;
}

/** One whitespace-separated run of the raw query, with its offsets. */
export interface QueryToken {
  readonly start: number;
  /** Exclusive. */
  readonly end: number;
  /** The source slice, quotes and all. */
  readonly raw: string;
  /** The filter this token expresses, or null for free text. */
  readonly filter: SearchFilter | null;
}

/** Split on whitespace, except inside double quotes, keeping offsets. */
export function tokenizeSearchQuery(input: string): QueryToken[] {
  const out: QueryToken[] = [];
  let start = -1;
  let quoted = false;
  const flush = (end: number): void => {
    if (start < 0) {
      return;
    }
    const raw = input.slice(start, end);
    out.push({ start, end, raw, filter: filterOf(raw) });
    start = -1;
  };
  for (let i = 0; i < input.length; i++) {
    const ch = input[i];
    if (ch === '"') {
      quoted = !quoted;
      if (start < 0) {
        start = i;
      }
      continue;
    }
    if (!quoted && (ch === " " || ch === "\t" || ch === "\n")) {
      flush(i);
      continue;
    }
    if (start < 0) {
      start = i;
    }
  }
  flush(input.length);
  return out;
}

const unquote = (raw: string): string => raw.replaceAll('"', "");

/** The `field:value` a raw token expresses, or null when it is free text. */
function filterOf(raw: string): SearchFilter | null {
  let body = unquote(raw);
  let negated = false;
  // A lone `-` is text.
  if (body.length > 1 && body.startsWith("-")) {
    negated = true;
    body = body.slice(1);
  }
  const colon = body.indexOf(":");
  if (colon <= 0) {
    return null;
  }
  const resolved = resolveKeyword(body.slice(0, colon).toLowerCase());
  const value = body
    .slice(colon + 1)
    .trim()
    .toLowerCase();
  if (!resolved || !value) {
    return null;
  }
  // The dash and the negative spelling cancel: `-hasnot:link` is `has:link`.
  return { field: resolved.field, value, negated: negated !== resolved.negated };
}

export function parseSearchQuery(input: string): SearchQuery {
  const terms: SearchTerm[] = [];
  const filters: SearchFilter[] = [];
  for (const token of tokenizeSearchQuery(input)) {
    if (token.filter) {
      filters.push(token.filter);
      continue;
    }
    let body = unquote(token.raw);
    let negated = false;
    if (body.length > 1 && body.startsWith("-")) {
      negated = true;
      body = body.slice(1);
    }
    const text = body.trim().toLowerCase();
    if (text) {
      terms.push({ text, negated });
    }
  }
  return { terms, filters };
}

/** Whether [query] already carries the filter [token] stands for. */
export function searchQueryHas(query: string, token: string): boolean {
  const target = filterOf(token);
  if (!target) {
    return false;
  }
  return tokenizeSearchQuery(query).some((t) => filtersEqual(t.filter, target));
}

/** Rewrite the one token meaning [target]; append [replacement] when absent. */
function rewriteFilter(query: string, target: SearchFilter | null, replacement: string | null): string {
  if (!target) {
    return query;
  }
  const kept: string[] = [];
  let found = false;
  for (const t of tokenizeSearchQuery(query)) {
    if (!found && filtersEqual(t.filter, target)) {
      found = true;
      if (replacement !== null) {
        kept.push(replacement);
      }
      continue;
    }
    kept.push(t.raw);
  }
  if (!found && replacement !== null) {
    kept.push(replacement);
  }
  return kept.join(" ");
}

/** Add [token] to [query], or take it out when already there. */
export function toggleSearchFilter(query: string, token: string): string {
  return rewriteFilter(query, filterOf(token), searchQueryHas(query, token) ? null : token);
}

/** The same filter with its meaning flipped, keeping the value as written. */
export function negateSearchFilter(token: string): string {
  let rest = token;
  let dashed = false;
  if (rest.length > 1 && rest.startsWith("-")) {
    dashed = true;
    rest = rest.slice(1);
  }
  const colon = rest.indexOf(":");
  if (colon <= 0) {
    return token;
  }
  const resolved = resolveKeyword(rest.slice(0, colon).toLowerCase());
  if (!resolved) {
    return token;
  }
  const negated = dashed !== resolved.negated;
  return `${filterKeyword(resolved.field, !negated)}:${rest.slice(colon + 1)}`;
}

/** Step [token] through absent, matching, excluding, absent again. */
export function cycleSearchFilter(query: string, token: string): string {
  const matching = filterOf(token);
  if (!matching) {
    return query;
  }
  const excluding = negateSearchFilter(token);
  if (searchQueryHas(query, token)) {
    return rewriteFilter(query, matching, excluding);
  }
  if (searchQueryHas(query, excluding)) {
    return rewriteFilter(query, filterOf(excluding), null);
  }
  return rewriteFilter(query, matching, token);
}

function containsText(note: Note, needle: string, context: SearchContext): boolean {
  if (note.title.toLowerCase().includes(needle)) {
    return true;
  }
  if (note.content.toLowerCase().includes(needle)) {
    return true;
  }
  if (note.items.some((item) => item.text.toLowerCase().includes(needle))) {
    return true;
  }
  // Words the server read out of an attached picture count as the note's own.
  if (note.attachments.some((a) => a.ocrText.toLowerCase().includes(needle))) {
    return true;
  }
  return note.labelIds.some((id) => context.labelsById.get(id)?.name.toLowerCase().includes(needle) ?? false);
}

function matchesFilter(note: Note, filter: SearchFilter, context: SearchContext): boolean {
  switch (filter.field) {
    case "label":
      return matchesLabel(note, filter.value, context);
    case "state":
      return matchesState(note, filter.value);
    case "has":
      return matchesHas(note, filter.value);
    case "color":
      return note.color.toLowerCase() === filter.value;
    case "kind":
      return note.kind === filter.value;
  }
}

function matchesLabel(note: Note, value: string, context: SearchContext): boolean {
  if (value === "none") {
    return note.labelIds.length === 0;
  }
  if (value === "any") {
    return note.labelIds.length > 0;
  }
  const ids = context.labelIdsByName.get(value);
  if (!ids) {
    return false;
  }
  return note.labelIds.some((id) => ids.has(id));
}

function matchesState(note: Note, value: string): boolean {
  switch (value) {
    case "pinned":
      return note.pinned;
    case "archived":
      return note.archived;
    case "trashed":
      return note.trashed;
    case "shared":
      return isNoteShared(note);
    // Done only once it has items and none are pending.
    case "done":
      return isChecklist(note) && note.items.length > 0 && note.items.every((i) => i.done);
    case "open":
      return note.items.some((i) => !i.done);
    default:
      return false;
  }
}

function matchesHas(note: Note, value: string): boolean {
  switch (value) {
    case "reminder":
      return hasReminder(note);
    case "attachment":
      return note.attachments.length > 0;
    case "image":
      return note.attachments.some(isImageAttachment);
    case "audio":
      return note.attachments.some(isAudioAttachment);
    case "label":
      return note.labelIds.length > 0;
    case "link":
      return findUrls(note.content).length > 0 || findUrls(note.title).length > 0;
    default:
      return false;
  }
}
