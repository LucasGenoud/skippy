import { generalCollectionId, type NoteCollection, type SavedView, type Workspace } from "@/lib/models/workspace";
import { hasReminder, type Label, type Note, type Stage } from "@/lib/models/note";
import { buildBoard, type Board } from "@/lib/state/board-layout";
import { filterNotes, scopeContains, scopeContainsWorkspace, selectNotes, sortModeFrom, type NoteSections, type SortMode, type ViewSelection, type WorkspaceScope } from "@/lib/state/note-collection";
import { scheduledReminders, type ReminderOccurrence } from "@/lib/state/reminder-agenda";
import { filtersOnly, parseSearchQuery, queryMatches, queryText, searchContext } from "@/lib/util/search-query";
import type { NotesState } from "./notes-store";
import { isWorkspaceWide, selectionForDestination, type UiState } from "./ui-store";

// Pure derivations over the stores' states, shared by the hooks. Each takes
// the states it reads, so it can be memoized against their identities.

/** Note ids of a grid view, pinned first. */
export interface SectionIds {
  readonly pinned: readonly string[];
  readonly others: readonly string[];
}

export function workspaceOf(notes: NotesState, id: string | null | undefined): Workspace | null {
  return notes.workspaces.find((w) => w.id === id) ?? null;
}

export function defaultWorkspaceOf(notes: NotesState): Workspace | null {
  return notes.workspaces.find((w) => w.isDefault) ?? notes.workspaces[0] ?? null;
}

export function activeWorkspaceOf(notes: NotesState, ui: UiState): Workspace | null {
  return workspaceOf(notes, ui.activeWorkspaceId);
}

export function activeCollectionOf(notes: NotesState, ui: UiState): NoteCollection | null {
  const workspace = activeWorkspaceOf(notes, ui);
  if (!workspace) {
    return null;
  }
  const chosen = ui.collectionChoices[workspace.id];
  return workspace.collections.find((c) => c.id === chosen) ?? workspace.collections[0] ?? null;
}

/** How [workspaceId] narrows what this device holds (default workspace catches foreign notes). */
export function scopeOf(notes: NotesState, workspaceId: string | null, collectionId: string | null = null): WorkspaceScope {
  return {
    workspaceId,
    collectionId,
    isDefault: workspaceId !== null && workspaceId === defaultWorkspaceOf(notes)?.id,
    known: new Set(notes.workspaces.map((w) => w.id)),
  };
}

export function labelsOf(notes: NotesState, workspaceId: string | null): Label[] {
  const scope = scopeOf(notes, workspaceId);
  return notes.labels.filter((l) => scopeContainsWorkspace(scope, l.workspaceId));
}

/** Columns of [collection], left to right. */
export function stagesOfCollection(notes: NotesState, workspaceId: string | null, collectionId: string | null): Stage[] {
  const scope = scopeOf(notes, workspaceId);
  return notes.stages.filter((s) => scopeContainsWorkspace(scope, s.workspaceId) && (s.collectionId ?? generalCollectionId(s.workspaceId)) === collectionId);
}

export function savedViewOf(notes: NotesState, ui: UiState, id: string): SavedView | null {
  return activeWorkspaceOf(notes, ui)?.savedViews.find((v) => v.id === id) ?? null;
}

/** The layout the active collection draws in: a local override, else the shared one. */
export function activeLayoutOf(notes: NotesState, ui: UiState): string {
  const collection = activeCollectionOf(notes, ui);
  if (!collection) {
    return "masonry";
  }
  return ui.layoutOverrides[collection.id] ?? collection.layout;
}

/** A temporary sort for the collection, else its saved sort. */
export function activeSortOf(notes: NotesState, ui: UiState): SortMode {
  const collection = activeCollectionOf(notes, ui);
  if (!collection) {
    return "custom";
  }
  return ui.sortOverrides[collection.id] ?? sortModeFrom(collection.sort);
}

export function viewSelectionOf(notes: NotesState, ui: UiState): ViewSelection {
  return selectionForDestination(ui.destination, activeLayoutOf(notes, ui));
}

/**
 * What actually filters the view: a smart view's saved query, or a label's
 * `label:"Name"`, with whatever is typed appended (terms AND together).
 */
export function effectiveQueryOf(notes: NotesState, ui: UiState): string {
  const destination = ui.destination;
  let saved: string | null = null;
  if (typeof destination !== "string") {
    if ("label" in destination) {
      const label = notes.labels.find((l) => l.id === destination.label);
      saved = label ? `label:"${label.name}"` : null;
    } else {
      saved = savedViewOf(notes, ui, destination.smartView)?.query ?? null;
    }
  }
  if (!saved) {
    return ui.query;
  }
  return ui.query.trim() === "" ? saved : `${saved} ${ui.query}`;
}

/** Text for match highlighting: the free words of the effective query. */
export function highlightQueryOf(notes: NotesState, ui: UiState): string {
  return queryText(parseSearchQuery(effectiveQueryOf(notes, ui)));
}

/** Every note in store order with editor card overrides applied. */
export function displayNotesOf(notes: NotesState): Note[] {
  const out: Note[] = [];
  for (const id of notes.order) {
    if (id in notes.editingCards) {
      const card = notes.editingCards[id];
      if (card) {
        out.push(card);
      }
      continue;
    }
    const note = notes.notes[id];
    if (note) {
      out.push(note);
    }
  }
  return out;
}

/** Whether semantic ranking applies to the current view. */
export function semanticActiveOf(notes: NotesState, ui: UiState, rankingWanted: boolean): boolean {
  const view = viewSelectionOf(notes, ui).view;
  return rankingWanted && ui.semantic.available && queryText(parseSearchQuery(effectiveQueryOf(notes, ui))).trim() !== "" && (view === "notes" || view === "board");
}

/** The grid's sections for the current navigation state. */
export function sectionsOf(notes: NotesState, ui: UiState, currentUserId: string | null, rankingWanted: boolean): NoteSections {
  const selection = viewSelectionOf(notes, ui);
  const workspaceId = ui.activeWorkspaceId;
  const collection = activeCollectionOf(notes, ui);
  const scope = isWorkspaceWide(ui.destination) ? scopeOf(notes, workspaceId) : scopeOf(notes, workspaceId, collection?.id ?? null);
  const query = effectiveQueryOf(notes, ui);
  const ranked = ui.semantic.ids;
  if (ranked !== null && semanticActiveOf(notes, ui, rankingWanted)) {
    // The server's ranking is the order; the query's filters still apply.
    const byId = new Map(displayNotesOf(notes).map((n) => [n.id, n]));
    const rankedNotes = ranked.map((id) => byId.get(id)).filter((n): n is Note => n !== undefined);
    return {
      pinned: [],
      others: filterNotes({ notes: rankedNotes, labels: notes.labels, selection, query: filtersOnly(parseSearchQuery(query)), currentUserId, scope }),
    };
  }
  return selectNotes({
    notes: displayNotesOf(notes),
    labels: notes.labels,
    selection,
    query,
    sortMode: activeSortOf(notes, ui),
    currentUserId,
    scope,
  });
}

export function sectionIds(sections: NoteSections): SectionIds {
  return { pinned: sections.pinned.map((n) => n.id), others: sections.others.map((n) => n.id) };
}

/** The active collection's board for the current query (and ranking). */
export function boardOf(notes: NotesState, ui: UiState, rankingWanted: boolean, showAllUnassigned: boolean): Board {
  const collection = activeCollectionOf(notes, ui);
  const ranked = semanticActiveOf(notes, ui, rankingWanted) ? ui.semantic.ids : null;
  return buildBoard({
    notes: displayNotesOf(notes),
    stages: stagesOfCollection(notes, ui.activeWorkspaceId, collection?.id ?? null),
    scope: scopeOf(notes, ui.activeWorkspaceId, collection?.id ?? null),
    query: effectiveQueryOf(notes, ui),
    labels: labelsOf(notes, ui.activeWorkspaceId),
    sortMode: activeSortOf(notes, ui),
    showAllUnassigned,
    rankedIds: ranked === null ? null : new Set(ranked),
  });
}

/** Stored reminders of the open workspace matching the search, soonest first. */
export function remindersOf(notes: NotesState, ui: UiState): ReminderOccurrence[] {
  const scope = scopeOf(notes, ui.activeWorkspaceId);
  const query = parseSearchQuery(effectiveQueryOf(notes, ui));
  const context = searchContext(labelsOf(notes, ui.activeWorkspaceId));
  const visible = displayNotesOf(notes).filter((n) => scopeContains(scope, n) && !n.trashed && queryMatches(query, n, context));
  return scheduledReminders(visible);
}

/** Notes with any reminder in the open workspace (for counts and badges). */
export function reminderCountOf(notes: NotesState, ui: UiState): number {
  const scope = scopeOf(notes, ui.activeWorkspaceId);
  return displayNotesOf(notes).filter((n) => scopeContains(scope, n) && !n.trashed && hasReminder(n)).length;
}

/** Labels a note composed right now starts with: the label being viewed, so it stays in view. */
export function composeLabelIdsOf(ui: UiState): readonly string[] {
  const destination = ui.destination;
  return typeof destination !== "string" && "label" in destination ? [destination.label] : [];
}

// -- equality -----------------------------------------------------------------

export function idsEqual(a: readonly string[], b: readonly string[]): boolean {
  return a === b || (a.length === b.length && a.every((id, i) => id === b[i]));
}

export function sectionIdsEqual(a: SectionIds, b: SectionIds): boolean {
  return idsEqual(a.pinned, b.pinned) && idsEqual(a.others, b.others);
}

/** Same columns (by stage identity) holding the same note objects. */
export function boardsEqual(a: Board, b: Board): boolean {
  if (a.columns.length !== b.columns.length) {
    return false;
  }
  return a.columns.every((col, i) => {
    const other = b.columns[i];
    return (
      other !== undefined &&
      col.stage === other.stage &&
      col.totalCount === other.totalCount &&
      col.notes.length === other.notes.length &&
      col.notes.every((n, j) => n === other.notes[j])
    );
  });
}

export function listIdentityEqual<T>(a: readonly T[], b: readonly T[]): boolean {
  return a === b || (a.length === b.length && a.every((x, i) => x === b[i]));
}

/** Occurrence lists equal when each entry has the same note, item, time and flags. */
export function occurrencesEqual(a: readonly ReminderOccurrence[], b: readonly ReminderOccurrence[]): boolean {
  return (
    a.length === b.length &&
    a.every((x, i) => {
      const y = b[i];
      return y !== undefined && x.note === y.note && x.item === y.item && x.at.getTime() === y.at.getTime() && x.repeat === y.repeat && x.projected === y.projected;
    })
  );
}
