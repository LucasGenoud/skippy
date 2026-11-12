"use client";

import { createContext, useContext, type ReactNode } from "react";
import type { Api } from "@/lib/api/client";
import { hasReminder, type Label, type Note, type Stage } from "@/lib/models/note";
import type { NoteCollection, SavedView, Workspace, WorkspaceAi } from "@/lib/models/workspace";
import { NO_WORKSPACE_AI } from "@/lib/models/workspace";
import type { Board } from "@/lib/state/board-layout";
import { availabilityEqual, noteAvailability, type NoteAvailability } from "@/lib/state/note-availability";
import type { SortMode, ViewSelection } from "@/lib/state/note-collection";
import type { ReminderOccurrence } from "@/lib/state/reminder-agenda";
import type { SyncIssue } from "@/lib/state/sync-issue";
import { computeWorkspaceStats, type WorkspaceStats } from "@/lib/util/workspace-stats";
import type { AuthState, AuthStore } from "./auth-store";
import type { LinkPreviewCache } from "./link-preview-cache";
import type { NotesState, NotesStore, SyncStatus } from "./notes-store";
import {
  activeCollectionOf,
  activeLayoutOf,
  activeSortOf,
  activeWorkspaceOf,
  boardOf,
  boardsEqual,
  composeLabelIdsOf,
  effectiveQueryOf,
  highlightQueryOf,
  idsEqual,
  labelsOf,
  listIdentityEqual,
  occurrencesEqual,
  remindersOf,
  sectionIds,
  sectionIdsEqual,
  sectionsOf,
  semanticActiveOf,
  stagesOfCollection,
  viewSelectionOf,
  workspaceOf,
  type SectionIds,
} from "./selectors";
import type { Session } from "./session";
import { semanticSearchAvailable, type SettingsState, type SettingsStore } from "./settings-store";
import type { UiController, UiState } from "./ui-store";
import { useStorePairSelector, useStoreSelector } from "./use-store";

// React access to the stores: providers, controller hooks (for actions and
// imperative queries), and narrow selector hooks that re-render only when
// their slice changes.

const AuthContext = createContext<AuthStore | null>(null);
const SessionContext = createContext<Session | null>(null);

export function AuthProvider({ auth, children }: { auth: AuthStore; children: ReactNode }) {
  return <AuthContext.Provider value={auth}>{children}</AuthContext.Provider>;
}

export function SessionProvider({ session, children }: { session: Session; children: ReactNode }) {
  return <SessionContext.Provider value={session}>{children}</SessionContext.Provider>;
}

// -- controllers ----------------------------------------------------------------

export function useAuthController(): AuthStore {
  const auth = useContext(AuthContext);
  if (!auth) {
    throw new Error("useAuthController outside AuthProvider");
  }
  return auth;
}

export function useSession(): Session {
  const session = useContext(SessionContext);
  if (!session) {
    throw new Error("useSession outside SessionProvider (signed-in screens only)");
  }
  return session;
}

/** The session if one exists (signed in), else null. */
export function useOptionalSession(): Session | null {
  return useContext(SessionContext);
}

export const useNotesController = (): NotesStore => useSession().notes;
export const useSettingsController = (): SettingsStore => useSession().settings;
export const useUiController = (): UiController => useSession().ui;
export const useLinkPreviews = (): LinkPreviewCache => useSession().linkPreviews;
export const useApi = (): Api => useSession().api;

// -- generic selectors ----------------------------------------------------------

export function useAuth<R>(selector: (s: AuthState) => R, isEqual?: (a: R, b: R) => boolean): R {
  return useStoreSelector(useAuthController().store, selector, isEqual);
}

export function useNotesSelector<R>(selector: (s: NotesState) => R, isEqual?: (a: R, b: R) => boolean, deps: readonly unknown[] = []): R {
  return useStoreSelector(useNotesController().store, selector, isEqual, deps);
}

export function useSettings<R>(selector: (s: SettingsState) => R, isEqual?: (a: R, b: R) => boolean): R {
  return useStoreSelector(useSettingsController().store, selector, isEqual);
}

export function useUi<R>(selector: (s: UiState) => R, isEqual?: (a: R, b: R) => boolean): R {
  return useStoreSelector(useUiController().store, selector, isEqual);
}

/** A selector over notes and ui together (most navigation-aware reads). */
export function useNav<R>(selector: (notes: NotesState, ui: UiState) => R, isEqual?: (a: R, b: R) => boolean, deps: readonly unknown[] = []): R {
  const session = useSession();
  return useStorePairSelector(session.notes.store, session.ui.store, selector, isEqual, deps);
}

// -- notes ----------------------------------------------------------------------

/** One note by id (the stored copy); null when absent. */
export function useNote(id: string | null | undefined): Note | null {
  return useNotesSelector((s) => (id ? (s.notes[id] ?? null) : null), Object.is, [id]);
}

/** One note as its card shows it (an open editor freezes its card); null when hidden or absent. */
export function useDisplayNote(id: string): Note | null {
  return useNotesSelector((s) => (id in s.editingCards ? (s.editingCards[id] ?? null) : (s.notes[id] ?? null)), Object.is, [id]);
}

/** Pinned and other note ids for the current destination, search, sort and ranking. */
export function useVisibleNoteIds(): SectionIds {
  const session = useSession();
  const ranking = useSettings((s) => semanticSearchAvailable(s) && s.semanticRanking);
  return useStorePairSelector(
    session.notes.store,
    session.ui.store,
    (notes, ui) => sectionIds(sectionsOf(notes, ui, session.userId, ranking)),
    sectionIdsEqual,
    [ranking],
  );
}

/** The active collection's board for the current search. */
export function useBoard(showAllUnassigned = false): Board {
  const ranking = useSettings((s) => semanticSearchAvailable(s) && s.semanticRanking);
  return useNav((notes, ui) => boardOf(notes, ui, ranking, showAllUnassigned), boardsEqual, [ranking, showAllUnassigned]);
}

/** Stored reminders in the open workspace matching the search, soonest first. */
export function useReminderOccurrences(): ReminderOccurrence[] {
  return useNav(remindersOf, occurrencesEqual);
}

/** Ids of every note in the open workspace that carries a reminder. */
export function useReminderNoteIds(): readonly string[] {
  return useNav((notes, ui) => remindersOf(notes, ui).map((o) => o.note.id).filter((id, i, all) => all.indexOf(id) === i), idsEqual);
}

/** Whether the note has any reminder (for a card's bell). */
export function useHasReminder(id: string): boolean {
  return useNotesSelector((s) => {
    const note = s.notes[id];
    return note ? hasReminder(note) : false;
  }, Object.is, [id]);
}

export function useIsDraft(id: string): boolean {
  return useNotesSelector((s) => id in s.drafts, Object.is, [id]);
}

export function useIsRewriting(id: string): boolean {
  return useNotesSelector((s) => id in s.rewriting, Object.is, [id]);
}

/** Ids of notes linking to [id], most recently edited first. */
export function useBacklinkIds(id: string): readonly string[] {
  const notes = useNotesController();
  return useNotesSelector(() => notes.backlinks(id).map((n) => n.id), idsEqual, [id]);
}

/** Which actions [id] offers; a null id is the editor's unsaved draft. */
export function useNoteAvailability(id: string | null): NoteAvailability {
  const notes = useNotesController();
  return useNotesSelector(() => noteAvailability(notes, id === null ? null : notes.noteById(id)), availabilityEqual, [id]);
}

// -- taxonomy and workspaces ------------------------------------------------------

export function useWorkspaces(): readonly Workspace[] {
  return useNotesSelector((s) => s.workspaces);
}

export function useWorkspace(id: string | null | undefined): Workspace | null {
  return useNotesSelector((s) => workspaceOf(s, id), Object.is, [id]);
}

export function useActiveWorkspace(): Workspace | null {
  return useNav(activeWorkspaceOf);
}

export function useActiveCollection(): NoteCollection | null {
  return useNav(activeCollectionOf);
}

export function useCollections(): readonly NoteCollection[] {
  return useNav((notes, ui) => activeWorkspaceOf(notes, ui)?.collections ?? EMPTY);
}

/** Labels of [workspaceId], or of the open workspace when omitted. */
export function useLabels(workspaceId?: string | null): readonly Label[] {
  return useNav((notes, ui) => labelsOf(notes, workspaceId === undefined ? ui.activeWorkspaceId : workspaceId), listIdentityEqual, [workspaceId]);
}

export function useLabel(id: string | null | undefined): Label | null {
  return useNotesSelector((s) => s.labels.find((l) => l.id === id) ?? null, Object.is, [id]);
}

/** Columns of the active collection, left to right. */
export function useStages(): readonly Stage[] {
  return useNav((notes, ui) => stagesOfCollection(notes, ui.activeWorkspaceId, activeCollectionOf(notes, ui)?.id ?? null), listIdentityEqual);
}

/** Column choices for one note (its own collection's columns). */
export function useStagesForNote(id: string | null): readonly Stage[] {
  const notes = useNotesController();
  return useNotesSelector(() => notes.stagesForNote(id === null ? null : notes.noteById(id)), listIdentityEqual, [id]);
}

export function useSavedViews(): readonly SavedView[] {
  return useNav((notes, ui) => activeWorkspaceOf(notes, ui)?.savedViews ?? EMPTY);
}

/** The AI in workspace [id] (none for a workspace this user is not in). */
export function useAiIn(workspaceId: string | null | undefined): WorkspaceAi {
  return useNotesSelector((s) => workspaceOf(s, workspaceId)?.ai ?? NO_WORKSPACE_AI, Object.is, [workspaceId]);
}

// -- sync -------------------------------------------------------------------------

export function useSyncStatus(): SyncStatus {
  return useNotesSelector((s) => s.syncStatus);
}

export function useSyncIssues(): readonly SyncIssue[] {
  return useNotesSelector((s) => s.syncIssues);
}

/** The first load is still running with nothing cached to show. */
export function useNotesLoading(): boolean {
  return useNotesSelector((s) => s.loading);
}

// -- navigation -------------------------------------------------------------------

/** The view the destination resolves to (notes become board for a board collection). */
export function useViewSelection(): ViewSelection {
  return useNav(viewSelectionOf, (a, b) => a.view === b.view && a.labelId === b.labelId && a.savedViewId === b.savedViewId);
}

/** The active collection's layout: local override, else shared. */
export function useActiveLayout(): string {
  return useNav(activeLayoutOf);
}

export function useActiveSort(): SortMode {
  return useNav(activeSortOf);
}

/** The query that filters the view (smart view or label prefix plus the box). */
export function useEffectiveQuery(): string {
  return useNav(effectiveQueryOf);
}

/** The free words to highlight in cards. */
export function useHighlightQuery(): string {
  return useNav(highlightQueryOf);
}

/** Whether semantic ranking is shaping the current view. */
export function useSemanticActive(): boolean {
  const ranking = useSettings((s) => semanticSearchAvailable(s) && s.semanticRanking);
  return useNav((notes, ui) => semanticActiveOf(notes, ui, ranking), Object.is, [ranking]);
}

/** Labels a note composed now should carry (the open label view's), else none. */
export function useComposeLabelIds(): readonly string[] {
  return useUi(composeLabelIdsOf, idsEqual);
}

/** Everything a workspace holds, counted (the stats screen). Recomputed as notes change. */
export function useWorkspaceStats(workspaceId: string): WorkspaceStats {
  const notes = useNotesController();
  return useNotesSelector(
    () =>
      computeWorkspaceStats({
        notes: notes.notesInWorkspace(workspaceId),
        labels: notes.labelsInWorkspace(workspaceId),
        stages: notes.stagesInWorkspace(workspaceId),
        now: new Date(),
      }),
    Object.is,
    [workspaceId],
  );
}

export function useSelectedIds(): readonly string[] {
  return useUi((s) => s.selectedIds);
}

export function useIsSelected(id: string): boolean {
  const ui = useUiController();
  return useStoreSelector(ui.store, (s) => s.selectedIds.includes(id), Object.is, [id]);
}

const EMPTY: readonly never[] = [];
