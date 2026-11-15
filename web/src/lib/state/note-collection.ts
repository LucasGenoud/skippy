import { generalCollectionId } from "@/lib/models/workspace";
import { hasReminder, isNoteOwnedBy, nextReminderAt, type Label, type Note } from "@/lib/models/note";
import { parseSearchQuery, queryMatches, searchContext, stateOverride, type SearchQuery, type StateOverride } from "@/lib/util/search-query";

// Selects, searches, sorts and groups notes for the home screen. Ported from
// `state/note_collection.dart`; pure so the view rules stay independent of the
// store's persistence and sync.

/** Notes/board render a collection; labels and smart views narrow it. */
export type NoteView = "notes" | "board" | "reminders" | "archive" | "trash" | "label" | "smart";

export type SortMode = "custom" | "edited" | "newest" | "oldest";

export const SORT_MODES: readonly SortMode[] = ["custom", "edited", "newest", "oldest"];

export function sortModeFrom(value: string | null | undefined): SortMode {
  return (SORT_MODES as readonly string[]).includes(value ?? "") ? (value as SortMode) : "custom";
}

/** Which view is open; a pointer, so editing a label or smart view applies live. */
export interface ViewSelection {
  readonly view: NoteView;
  readonly labelId?: string | null;
  readonly savedViewId?: string | null;
}

export function selectionsEqual(a: ViewSelection, b: ViewSelection): boolean {
  return a.view === b.view && (a.labelId ?? null) === (b.labelId ?? null) && (a.savedViewId ?? null) === (b.savedViewId ?? null);
}

/**
 * Which workspace's notes a view shows. A note shared directly from a
 * workspace the user is not in surfaces in their default workspace.
 */
export interface WorkspaceScope {
  /** The open workspace, or null to show everything. */
  readonly workspaceId: string | null;
  readonly collectionId?: string | null;
  /** Whether [workspaceId] is the default, which also collects foreign notes. */
  readonly isDefault: boolean;
  /** Workspaces the user belongs to. */
  readonly known: ReadonlySet<string>;
}

/** No filtering. */
export const ALL_SCOPE: WorkspaceScope = { workspaceId: null, collectionId: null, isDefault: false, known: new Set() };

/** Whether content filed in workspace [id] shows in [scope]. */
export function scopeContainsWorkspace(scope: WorkspaceScope, id: string): boolean {
  if (scope.workspaceId === null) {
    return true;
  }
  if (id === scope.workspaceId) {
    return true;
  }
  return scope.isDefault && !scope.known.has(id);
}

export function scopeContains(scope: WorkspaceScope, note: Note): boolean {
  if (!scopeContainsWorkspace(scope, note.workspaceId)) {
    return false;
  }
  const collectionId = scope.collectionId ?? null;
  return (
    collectionId === null ||
    note.collectionId === collectionId ||
    (note.collectionId === null && collectionId === generalCollectionId(note.workspaceId)) ||
    (scope.isDefault && !scope.known.has(note.workspaceId))
  );
}

export interface NoteSections {
  readonly pinned: readonly Note[];
  readonly others: readonly Note[];
}

export interface SelectNotesInput {
  readonly notes: Iterable<Note>;
  readonly labels: Iterable<Label>;
  readonly selection: ViewSelection;
  readonly query: string;
  readonly sortMode: SortMode;
  readonly currentUserId: string | null;
  readonly scope?: WorkspaceScope;
}

export function selectNotes(input: SelectNotesInput): NoteSections {
  const visible = filterNotes({ ...input, query: parseSearchQuery(input.query) });
  if (input.selection.view === "reminders") {
    // Soonest first, of either kind.
    visible.sort((a, b) => (nextReminderAt(a)?.getTime() ?? 0) - (nextReminderAt(b)?.getTime() ?? 0));
    return { pinned: [], others: visible };
  }
  sortNotes(visible, input.sortMode);
  const view = input.selection.view;
  const splitPins = view === "notes" || view === "label" || view === "smart";
  if (!splitPins) {
    return { pinned: [], others: visible };
  }
  return { pinned: visible.filter((n) => n.pinned), others: visible.filter((n) => !n.pinned) };
}

export interface FilterNotesInput {
  readonly notes: Iterable<Note>;
  readonly labels: Iterable<Label>;
  readonly selection: ViewSelection;
  /** Already parsed, so the semantic path can pass `filtersOnly`. */
  readonly query: SearchQuery;
  readonly currentUserId: string | null;
  readonly scope?: WorkspaceScope;
}

/** Which notes belong in [selection] under [query], in arrival order. */
export function filterNotes(input: FilterNotesInput): Note[] {
  const scope = input.scope ?? ALL_SCOPE;
  const context = searchContext(input.labels);
  // An explicit `is:archived`/`is:trashed` replaces the view's state filter.
  const override = stateOverride(input.query);
  const out: Note[] = [];
  for (const note of input.notes) {
    if (
      scopeContains(scope, note) &&
      isInView(note, input.selection, input.currentUserId, override, scope.known.has(note.workspaceId)) &&
      queryMatches(input.query, note, context)
    ) {
      out.push(note);
    }
  }
  return out;
}

function isInView(note: Note, selection: ViewSelection, currentUserId: string | null, override: StateOverride | null, workspaceMember: boolean): boolean {
  const view = selection.view;
  const defers = view === "notes" || view === "board" || view === "label" || view === "smart";
  if (defers && override !== null) {
    // Collaborators never see a trashed note, so an override cannot reveal one.
    const passesState =
      override === "trashed"
        ? note.trashed && (isNoteOwnedBy(note, currentUserId) || workspaceMember)
        : note.archived && !note.trashed;
    if (!passesState) {
      return false;
    }
    return view !== "label" || note.labelIds.includes(selection.labelId ?? "");
  }
  switch (view) {
    case "notes":
    case "smart":
    case "board":
      return !note.archived && !note.trashed;
    case "reminders":
      return hasReminder(note) && !note.trashed;
    case "archive":
      return note.archived && !note.trashed;
    case "trash":
      return note.trashed && (isNoteOwnedBy(note, currentUserId) || workspaceMember);
    case "label":
      return !note.trashed && note.labelIds.includes(selection.labelId ?? "");
  }
}

function sortNotes(notes: Note[], mode: SortMode): void {
  switch (mode) {
    case "custom":
      // The store keeps its source order position-sorted.
      return;
    case "edited":
      notes.sort((a, b) => b.updatedAt.getTime() - a.updatedAt.getTime());
      return;
    case "newest":
      notes.sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());
      return;
    case "oldest":
      notes.sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime());
      return;
  }
}
