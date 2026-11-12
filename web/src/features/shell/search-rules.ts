import { negateSearchFilter, searchQueryHas, tokenizeSearchQuery } from "@/lib/util/search-query";

// The search box's painting and the filter sheet's vocabulary
// (`search_query_controller.dart`, `search_filters_sheet.dart`).

export type SegmentKind = "text" | "filter" | "excluded";

export interface QuerySegment {
  readonly text: string;
  readonly kind: SegmentKind;
}

/**
 * [query] cut into runs, the `label:`/`is:` operators marked so the box can
 * tint them, and filters that exclude marked apart from those that find.
 */
export function querySegments(query: string): QuerySegment[] {
  const out: QuerySegment[] = [];
  let cursor = 0;
  for (const token of tokenizeSearchQuery(query)) {
    if (!token.filter) {
      continue;
    }
    if (token.start > cursor) {
      out.push({ text: query.slice(cursor, token.start), kind: "text" });
    }
    out.push({ text: token.raw, kind: token.filter.negated ? "excluded" : "filter" });
    cursor = token.end;
  }
  if (cursor < query.length) {
    out.push({ text: query.slice(cursor), kind: "text" });
  }
  return out;
}

/** `label:name`, quoted when the name has a space, which keeps it one value. */
export function quotedToken(field: string, value: string): string {
  return value.includes(" ") ? `${field}:"${value}"` : `${field}:${value}`;
}

export interface FilterGroup {
  readonly title: string;
  /** Positive tokens only; each one's negative is derived. */
  readonly tokens: readonly string[];
}

/** The sheet's groups; labels first, and only the open workspace's. */
export function filterGroups(labelNames: readonly string[]): FilterGroup[] {
  const groups: FilterGroup[] = [];
  if (labelNames.length > 0) {
    groups.push({ title: "Labels", tokens: labelNames.map((name) => quotedToken("label", name)) });
  }
  groups.push(
    { title: "State", tokens: ["is:pinned", "is:archived", "is:trashed", "is:shared", "is:open", "is:done"] },
    { title: "Contents", tokens: ["has:reminder", "has:attachment", "has:image", "has:audio", "has:link", "has:label"] },
    { title: "Kind", tokens: ["kind:text", "kind:checklist", "kind:markdown", "kind:audio"] },
    { title: "Color", tokens: ["color:red", "color:yellow", "color:green", "color:blue"] },
  );
  return groups;
}

/** What one chip currently asks of the search. A tap cycles off, match, exclude. */
export type ChipState = "off" | "matching" | "excluding";

export function chipState(query: string, token: string): ChipState {
  if (searchQueryHas(query, token)) {
    return "matching";
  }
  return searchQueryHas(query, negateSearchFilter(token)) ? "excluding" : "off";
}

/** The chip's text: the token it stands for, in its negative spelling while excluding. */
export function chipText(state: ChipState, token: string): string {
  return state === "excluding" ? negateSearchFilter(token) : token;
}

export function chipHint(state: ChipState, token: string): string {
  switch (state) {
    case "off":
      return `Match ${token}`;
    case "matching":
      return "Exclude instead";
    case "excluding":
      return "Clear";
  }
}
