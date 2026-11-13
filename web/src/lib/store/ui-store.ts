import { createStore, type StoreApi } from "zustand/vanilla";
import type { CollectionLayout } from "@/lib/models/workspace";
import { destinationsEqual, type Destination } from "@/lib/state/notes-cache-doc";
import type { SortMode, ViewSelection } from "@/lib/state/note-collection";
import { EMPTY_QUERY, parseSearchQuery, queryText, type SearchQuery } from "@/lib/util/search-query";

// Navigation and transient UI state shared across features: which workspace,
// collection and destination are open, the search box, local layout and sort
// choices, the multi-selection, and a search-focus signal. Ported from the
// state `HomeScreen` kept plus the navigation half of `NotesStore`.
//
// The notes store reads and writes the workspace/collection fields (it owns
// their persistence and reconciliation); features use the actions below.

export type { Destination };

export interface SemanticState {
  /** Ranked note ids for the current query, or null when not ranking. */
  readonly ids: readonly string[] | null;
  /** A ranking request is on its way. */
  readonly busy: boolean;
  /** False once the server answered 503 (semantic search disabled). */
  readonly available: boolean;
}

export interface UiState {
  readonly activeWorkspaceId: string | null;
  /** Workspace id to the collection last open in it. */
  readonly collectionChoices: Readonly<Record<string, string>>;
  /** Workspace id to the destination last used in it. */
  readonly lastWorkspaceViews: Readonly<Record<string, Destination>>;
  readonly destination: Destination;
  /** The search box, exactly as typed. */
  readonly query: string;
  /** [query] parsed. */
  readonly parsedQuery: SearchQuery;
  /** Collection id to a layout chosen on this device, over the shared one. */
  readonly layoutOverrides: Readonly<Record<string, CollectionLayout>>;
  /** Collection id to a temporary sort; the collection's own sort otherwise. */
  readonly sortOverrides: Readonly<Record<string, SortMode>>;
  /** Selected note ids; selection mode is on while this is non-empty. */
  readonly selectedIds: readonly string[];
  /** Increments each time something asks the search box to take focus. */
  readonly searchFocusRequest: number;
  readonly semantic: SemanticState;
  /** Wide-screen sidebar visibility. */
  readonly sidebarOpen: boolean;
}

export const INITIAL_UI_STATE: UiState = {
  activeWorkspaceId: null,
  collectionChoices: {},
  lastWorkspaceViews: {},
  destination: "notes",
  query: "",
  parsedQuery: EMPTY_QUERY,
  layoutOverrides: {},
  sortOverrides: {},
  selectedIds: [],
  searchFocusRequest: 0,
  semantic: { ids: null, busy: false, available: true },
  sidebarOpen: true,
};

/** The view selection a destination means, given the collection's layout. */
export function selectionForDestination(destination: Destination, layout: string | null | undefined): ViewSelection {
  if (typeof destination === "string") {
    if (destination === "notes") {
      return { view: layout === "board" ? "board" : "notes" };
    }
    return { view: destination };
  }
  if ("label" in destination) {
    return { view: "label", labelId: destination.label };
  }
  return { view: "smart", savedViewId: destination.smartView };
}

/** Whether a destination spans the workspace (archive, trash, reminders) rather than a collection. */
export function isWorkspaceWide(destination: Destination): boolean {
  return destination === "archive" || destination === "trash" || destination === "reminders";
}

/** What the ui controller needs from the rest of the session. */
export interface UiDependencies {
  /** Ranked ids for [query] in the open workspace; rejects with ApiError 503 when disabled. */
  semanticSearch(query: string): Promise<string[]>;
  /** Whether the user wants ranking and the server offers it. */
  semanticWanted(): boolean;
  /** Remember [destination] for the open workspace (persisted by the notes store). */
  rememberDestination(destination: Destination): void;
  /** Effective query for the current destination (smart view or label prefix). */
  effectiveQuery(): string;
  /** Tell the user something (semantic search turned out to be disabled). */
  notify?(message: string): void;
}

const SEMANTIC_DEBOUNCE_MS = 350;
const HTTP_SERVICE_UNAVAILABLE = 503;

export class UiController {
  readonly store: StoreApi<UiState>;
  private deps: UiDependencies | null = null;
  private semanticTimer: ReturnType<typeof setTimeout> | null = null;
  private disposed = false;

  constructor(initial: Partial<UiState> = {}) {
    this.store = createStore<UiState>(() => ({ ...INITIAL_UI_STATE, ...initial }));
  }

  /** Wired once the session's other stores exist. */
  connect(deps: UiDependencies): void {
    this.deps = deps;
  }

  get state(): UiState {
    return this.store.getState();
  }

  private set(partial: Partial<UiState>): void {
    if (!this.disposed) {
      this.store.setState(partial);
    }
  }

  /** Open a destination: clears the search and the selection, remembers it per workspace. */
  selectDestination(destination: Destination): void {
    this.deps?.rememberDestination(destination);
    this.set({ destination, query: "", parsedQuery: EMPTY_QUERY, selectedIds: [], semantic: { ...this.state.semantic, ids: null, busy: false } });
  }

  /**
   * Show [destination] without the side effects of a user choice (used when a
   * workspace switch reopens its remembered view, or a deleted label falls back).
   */
  showDestination(destination: Destination): void {
    if (destinationsEqual(destination, this.state.destination)) {
      return;
    }
    this.set({ destination, selectedIds: [] });
  }

  setQuery(query: string): void {
    this.set({ query, parsedQuery: parseSearchQuery(query) });
    this.scheduleSemantic();
  }

  clearQuery(): void {
    this.setQuery("");
  }

  /** Ask the search box to take focus (the `/` shortcut, the filters sheet). */
  requestSearchFocus(): void {
    this.set({ searchFocusRequest: this.state.searchFocusRequest + 1 });
  }

  /** Override [collectionId]'s layout on this device; null returns to the shared one. */
  setLayoutOverride(collectionId: string, layout: CollectionLayout | null): void {
    const next = { ...this.state.layoutOverrides };
    if (layout === null) {
      delete next[collectionId];
    } else {
      next[collectionId] = layout;
    }
    this.set({ layoutOverrides: next });
  }

  /** A temporary sort for [collectionId] (the sort menu); not saved to the collection. */
  setSortOverride(collectionId: string, mode: SortMode): void {
    this.set({ sortOverrides: { ...this.state.sortOverrides, [collectionId]: mode } });
  }

  /** Drop a temporary sort, so the collection's saved one applies again. */
  clearSortOverride(collectionId: string): void {
    if (!(collectionId in this.state.sortOverrides)) {
      return;
    }
    const next = { ...this.state.sortOverrides };
    delete next[collectionId];
    this.set({ sortOverrides: next });
  }

  // -- selection --------------------------------------------------------------

  /** Add or remove one note; deselecting the last one leaves selection mode. */
  setSelected(id: string, selected: boolean): void {
    const current = this.state.selectedIds;
    const has = current.includes(id);
    if (selected === has) {
      return;
    }
    this.set({ selectedIds: selected ? [...current, id] : current.filter((x) => x !== id) });
  }

  toggleSelected(id: string): void {
    this.setSelected(id, !this.state.selectedIds.includes(id));
  }

  /** Select every id in [ids], or deselect them all when they already are. */
  toggleSelectAll(ids: readonly string[]): void {
    const current = new Set(this.state.selectedIds);
    if (ids.length > 0 && ids.every((id) => current.has(id))) {
      this.set({ selectedIds: this.state.selectedIds.filter((id) => !ids.includes(id)) });
      return;
    }
    for (const id of ids) {
      current.add(id);
    }
    this.set({ selectedIds: [...current] });
  }

  clearSelection(): void {
    if (this.state.selectedIds.length > 0) {
      this.set({ selectedIds: [] });
    }
  }

  setSidebarOpen(open: boolean): void {
    this.set({ sidebarOpen: open });
  }

  toggleSidebar(): void {
    this.set({ sidebarOpen: !this.state.sidebarOpen });
  }

  // -- semantic ranking -------------------------------------------------------

  /** The words of the effective query, which is what the embedder ranks. */
  private semanticText(): string {
    return queryText(parseSearchQuery(this.deps?.effectiveQuery() ?? this.state.query)).trim();
  }

  /**
   * Re-rank after the query or the ranking toggle changed. Shows the busy
   * state at once; only the fetch for the query still in the box settles it.
   */
  scheduleSemantic(): void {
    if (this.semanticTimer !== null) {
      clearTimeout(this.semanticTimer);
      this.semanticTimer = null;
    }
    const deps = this.deps;
    const semantic = this.state.semantic;
    if (!deps || !deps.semanticWanted() || !semantic.available || this.semanticText() === "") {
      if (semantic.ids !== null || semantic.busy) {
        this.set({ semantic: { ...semantic, ids: null, busy: false } });
      }
      return;
    }
    this.set({ semantic: { ...semantic, busy: true } });
    this.semanticTimer = setTimeout(() => {
      this.semanticTimer = null;
      void this.runSemantic(deps);
    }, SEMANTIC_DEBOUNCE_MS);
  }

  private async runSemantic(deps: UiDependencies): Promise<void> {
    const query = this.semanticText();
    try {
      const ids = await deps.semanticSearch(query);
      if (this.semanticText() !== query) {
        return;
      }
      this.set({ semantic: { ...this.state.semantic, ids } });
    } catch (error) {
      const status = (error as { statusCode?: unknown }).statusCode;
      if (status === HTTP_SERVICE_UNAVAILABLE) {
        this.set({ semantic: { ids: null, busy: false, available: false } });
        deps.notify?.("Semantic search is not enabled on this server");
      }
      // A network hiccup keeps whatever results we had.
    } finally {
      if (this.semanticText() === query) {
        this.set({ semantic: { ...this.state.semantic, busy: false } });
      }
    }
  }

  dispose(): void {
    this.disposed = true;
    if (this.semanticTimer !== null) {
      clearTimeout(this.semanticTimer);
    }
  }
}
