import { filterToString, parseSearchQuery, unknownFilters } from "@/lib/util/search-query";

// Validation for the sidebar's editable lists (`LabelEditorDialog._validate`,
// `SavedViewDialog._save`). The server refuses duplicate names, so catch them
// before the request.

interface Named {
  readonly id: string;
  readonly name: string;
}

function clashes(name: string, existing: readonly Named[], selfId: string | null): boolean {
  const lower = name.toLowerCase();
  return existing.some((x) => x.id !== selfId && x.name.toLowerCase() === lower);
}

/** The label name's problem, or null when it is valid. */
export function labelNameProblem(name: string, labels: readonly Named[], selfId: string | null): string | null {
  if (name === "") {
    return "Enter a name";
  }
  return clashes(name, labels, selfId) ? `A label named "${name}" already exists` : null;
}

export function smartViewNameProblem(name: string, views: readonly Named[], selfId: string | null): string | null {
  if (name === "") {
    return "Enter a name";
  }
  return clashes(name, views, selfId) ? `A smart view named "${name}" already exists` : null;
}

/**
 * An empty query would pin a view that repeats the grid, and one made only of
 * unusable operators can never match, so neither is worth saving.
 */
export function smartViewQueryProblem(query: string): string | null {
  if (query === "") {
    return "Enter a search";
  }
  const unknown = unknownFilters(parseSearchQuery(query));
  return unknown.length === 0 ? null : `No such filter: ${unknown.map(filterToString).join(", ")}`;
}
