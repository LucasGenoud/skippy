import { createStore, type StoreApi } from "zustand/vanilla";
import type { Api, UploadBody } from "@/lib/api/client";
import { ApiError } from "@/lib/api/errors";
import {
  hasReminder,
  isNoteOwnedBy,
  itemsToJson,
  makeNote,
  noteCanAutoDiscard,
  noteServerStamp,
  noteToJson,
  parseNote,
  type Attachment,
  type ChecklistItem,
  type DroppedFile,
  type ItemReminder,
  type Label,
  type Note,
  type NoteKind,
  type NotePattern,
  type NoteRewriteTask,
  type NoteVersion,
  type ReminderRepeat,
  type Stage,
} from "@/lib/models";
import {
  aiSwitchesToJson,
  collectionToJson,
  generalCollection,
  generalCollectionId,
  isWorkspaceOwnedBy,
  isWorkspaceShared,
  makeWorkspace,
  NO_WORKSPACE_AI,
  savedViewToJson,
  type AiSwitches,
  type NoteCollection,
  type SavedView,
  type Workspace,
  type WorkspaceAi,
  type WorkspaceCopyContent,
} from "@/lib/models/workspace";
import { BulkImporter } from "@/lib/state/bulk-import";
import { normalizeDepths, setDoneCascading } from "@/lib/state/checklist-tree";
import { backlinksTo, linkCandidates, noteLinkTitle } from "@/lib/state/note-links";
import { convertNoteKind, copyTitle } from "@/lib/state/note-conversion";
import { scopeContains, scopeContainsWorkspace, type WorkspaceScope } from "@/lib/state/note-collection";
import { navigationCacheKey, notesCacheKey, type KeyValueStore, MemoryKeyValueStore } from "@/lib/state/local-cache";
import {
  destinationsEqual,
  EMPTY_CACHE_DOC,
  navigationDocToJson,
  notesCacheDocToJson,
  parseNavigationDoc,
  parseNotesCacheDoc,
  type Destination,
} from "@/lib/state/notes-cache-doc";
import { pendingOp, type PendingOp } from "@/lib/state/pending-operation";
import { PendingOperationExecutor } from "@/lib/state/pending-operation-executor";
import { POSITION_GAP, positionAt, positionBetween } from "@/lib/state/sparse-position";
import {
  STARTER_CHECKLIST_TITLE,
  STARTER_GUIDE_BODY,
  STARTER_GUIDE_TITLE,
  STARTER_WELCOME_TITLE,
  starterChecklistItems,
  starterWelcomeBody,
  type AccountOrigin,
} from "@/lib/state/starter-notes";
import type { SyncIssue } from "@/lib/state/sync-issue";
import { syncFailureDecision } from "@/lib/state/sync-retry-policy";
import { reconcileWorkspaceDeparture } from "@/lib/state/workspace-reconciliation";
import { BackupRestoreError, type BackupBundle, type BackupProgress, type BackupRestoreResult } from "@/lib/util/backup";
import { deepEqual } from "@/lib/util/deep-equal";
import { newId } from "@/lib/util/id";
import type { JsonObject } from "@/lib/util/json";
import type { KeepArchive, KeepImportResult, KeepTrash } from "@/lib/util/keep-import";
import type { UiController } from "./ui-store";
import { WriteBehind } from "./write-behind";

// Optimistic-first note domain: every mutation updates local state at once
// and is synced through a serial, persisted queue that retries on network
// failure. A WebSocket nudge triggers a debounced refetch through the same
// snapshot path as the first load and a manual refresh. Ported from
// `state/notes_store.dart` and its part files.
//
// The controller keeps the working copy (`this.data`) and publishes it to the
// zustand store on notify, which is what lets typing notify on a throttle.

/** Coarse connectivity/sync state for the indicator. */
export type SyncStatus = "synced" | "syncing" | "connecting" | "offline" | "failed";

/** Whether an edit notifies now or on the typing throttle. */
export type EditPace = "discrete" | "typing";

/** Whether finalizing an empty note may discard it. */
export type FinalizeMode = "discardIfEmpty" | "keepEmpty";

/** How an editor card starts: an existing note keeps its card still, a new one hides it. */
export type EditingStart = "existing" | "new";

export interface NotesData {
  /** Every note this device holds, by id. Unchanged notes keep their identity. */
  readonly notes: Readonly<Record<string, Note>>;
  /** Note ids in store order (position-sorted; drafts go first). */
  readonly order: readonly string[];
  /** Card overrides while an editor is open: the note as it was, or null to hide a new draft. */
  readonly editingCards: Readonly<Record<string, Note | null>>;
  readonly labels: readonly Label[];
  readonly stages: readonly Stage[];
  readonly workspaces: readonly Workspace[];
  /** Previously checked item texts per note id. */
  readonly checklistHistory: Readonly<Record<string, readonly string[]>>;
  /** Ids of local drafts not yet sent to the server. */
  readonly drafts: Readonly<Record<string, true>>;
  /** Ids of notes an AI rewrite is running on. */
  readonly rewriting: Readonly<Record<string, true>>;
}

export interface NotesState extends NotesData {
  /** The first load has not resolved (and the cache had nothing to show). */
  readonly loading: boolean;
  /** A manual refresh is re-pulling from the server. */
  readonly refreshing: boolean;
  /** An outage lasting past the grace period; what the UI should say. */
  readonly offline: boolean;
  readonly syncStatus: SyncStatus;
  /** Queued writes plus edits still in their debounce. */
  readonly pendingChanges: number;
  readonly hasPendingWork: boolean;
  readonly syncIssues: readonly SyncIssue[];
  /** Why the offline cache could not be written, or null. */
  readonly cacheFailure: string | null;
  /** A restore or import is running. */
  readonly restoringBackup: boolean;
}

export interface NotesStoreOptions {
  readonly api: Api;
  readonly ui: UiController;
  readonly cache?: KeyValueStore;
  readonly currentUserId: string | null;
  /** The server this store talks to; partitions the cache with the user id. */
  readonly cacheNamespace?: string;
  /** Whether an unscoped legacy cache may be claimed (a restored session only). */
  readonly migrateLegacyCache?: boolean;
  readonly accountOrigin?: AccountOrigin;
  /** Called when the rest of the account may have moved (settings re-pull). */
  readonly onRemoteChange?: () => void;
  /** How long an outage lasts before the UI says so. Tests shorten it. */
  readonly offlineGraceMs?: number;
}

const DEFAULT_OFFLINE_GRACE_MS = 5_000;
const CONNECTION_PROBE_INTERVAL_MS = 2_000;
const LOAD_RETRY_MS = 5_000;
const QUEUE_RETRY_MS = 5_000;
const SAVE_DEBOUNCE_MS = 400;
const NOTIFY_THROTTLE_MS = 200;
const SYNC_RELOAD_DEBOUNCE_MS = 350;
const PERSIST_INTERVAL_MS = 1_000;
const DRAIN_POLL_MS = 50;

type Timer = ReturnType<typeof setTimeout>;

const byPosition = <T extends { position: number }>(a: T, b: T): number => a.position - b.position;

function byLabelPosition(a: Label, b: Label): number {
  const p = a.position - b.position;
  if (p !== 0) {
    return p;
  }
  const an = a.name.toLowerCase();
  const bn = b.name.toLowerCase();
  return an < bn ? -1 : an > bn ? 1 : 0;
}

/** [next] with every element deep-equal to one in [previous] replaced by that one. */
function reconcileList<T extends { id: string }>(previous: readonly T[], next: readonly T[]): readonly T[] {
  const old = new Map(previous.map((item) => [item.id, item]));
  let same = previous.length === next.length;
  const merged = next.map((item, i) => {
    const prior = old.get(item.id);
    const kept = prior !== undefined && deepEqual(prior, item) ? prior : item;
    if (kept !== previous[i]) {
      same = false;
    }
    return kept;
  });
  return same ? previous : merged;
}

/** [note]'s item reminders, keeping only those whose item survives [items] unchecked. */
function prunedItemReminders(note: Note, items: readonly ChecklistItem[]): Readonly<Record<string, ItemReminder>> {
  if (Object.keys(note.itemReminders).length === 0) {
    return note.itemReminders;
  }
  const out: Record<string, ItemReminder> = {};
  for (const item of items) {
    const reminder = note.itemReminders[item.id];
    if (!item.done && reminder) {
      out[item.id] = reminder;
    }
  }
  return out;
}

export class NotesStore {
  readonly store: StoreApi<NotesState>;
  readonly api: Api;
  readonly currentUserId: string | null;
  private readonly ui: UiController;
  private readonly cache: KeyValueStore;
  private readonly cacheNamespace: string;
  private readonly migrateLegacyCache: boolean;
  private readonly accountOrigin: AccountOrigin;
  private readonly onRemoteChange: (() => void) | undefined;
  private readonly offlineGraceMs: number;

  private data: NotesData = {
    notes: {},
    order: [],
    editingCards: {},
    labels: [],
    stages: [],
    workspaces: [],
    checklistHistory: {},
    drafts: {},
    rewriting: {},
  };

  private loading = true;
  private refreshing = false;
  private offline = false;
  private connectionDown = false;
  private connectedOnce = false;
  private restoringBackup = false;
  private cacheFailure: string | null = null;
  private starterNotesHandled = false;
  private hydrated = false;
  private disposed = false;
  private flushing = false;
  private checkingConnection = false;
  private reloadPending = false;
  private localWriteRevision = 0;
  private fetchGeneration = 0;
  private lastPersist = 0;

  private readonly queue: PendingOp[] = [];
  private syncIssues: SyncIssue[] = [];
  private readonly serverUpdatedAt = new Map<string, string>();
  private readonly saveDebounce = new Map<string, Timer>();
  private readonly executor: PendingOperationExecutor;
  private readonly snapshotWriter: WriteBehind;
  private readonly navigationWriter: WriteBehind;

  private retryTimer: Timer | null = null;
  private offlineConfirmTimer: Timer | null = null;
  private syncReloadDebounce: Timer | null = null;
  private connectionProbe: ReturnType<typeof setInterval> | null = null;
  private notifyThrottle: Timer | null = null;
  private unsubscribeEvents: (() => void) | null = null;
  private unsubscribeUi: (() => void) | null = null;
  private removeOnlineListener: (() => void) | null = null;

  constructor(options: NotesStoreOptions) {
    this.api = options.api;
    this.ui = options.ui;
    this.cache = options.cache ?? new MemoryKeyValueStore();
    this.currentUserId = options.currentUserId;
    this.cacheNamespace = options.cacheNamespace ?? "";
    this.migrateLegacyCache = options.migrateLegacyCache ?? false;
    this.accountOrigin = options.accountOrigin ?? "existing";
    this.onRemoteChange = options.onRemoteChange;
    this.offlineGraceMs = options.offlineGraceMs ?? DEFAULT_OFFLINE_GRACE_MS;
    this.executor = new PendingOperationExecutor(this.api, (id) => this.noteById(id), this.serverUpdatedAt);
    this.snapshotWriter = new WriteBehind(() => this.writeSnapshot());
    this.navigationWriter = new WriteBehind(() => this.writeNavigation());
    this.store = createStore<NotesState>(() => this.snapshot());
    // Navigation lives in the ui store; persist it whenever it moves.
    this.unsubscribeUi = this.ui.store.subscribe((next, prev) => {
      if (
        next.activeWorkspaceId !== prev.activeWorkspaceId ||
        next.collectionChoices !== prev.collectionChoices ||
        next.lastWorkspaceViews !== prev.lastWorkspaceViews
      ) {
        this.persistNavigation();
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Publishing

  private snapshot(): NotesState {
    const pendingChanges = this.queue.length + this.saveDebounce.size;
    return {
      ...this.data,
      loading: this.loading,
      refreshing: this.refreshing,
      offline: this.offline,
      syncStatus: this.syncStatus,
      pendingChanges,
      hasPendingWork: this.hasLocalChangesInFlight,
      syncIssues: this.syncIssues,
      cacheFailure: this.cacheFailure,
      restoringBackup: this.restoringBackup,
    };
  }

  /** Publish the working copy to subscribers and persist soon. */
  private notify(): void {
    if (this.disposed) {
      return;
    }
    this.store.setState(this.snapshot(), true);
    this.persistSoon();
  }

  /** Publish without persisting the snapshot (navigation-only changes, cache status). */
  private publish(): void {
    if (this.disposed) {
      return;
    }
    this.store.setState(this.snapshot(), true);
  }

  private get hasLocalChangesInFlight(): boolean {
    return this.queue.length > 0 || Object.keys(this.data.drafts).length > 0 || this.saveDebounce.size > 0 || this.restoringBackup;
  }

  /** Whether there are local edits the server has not acknowledged. */
  get hasPendingWork(): boolean {
    return this.hasLocalChangesInFlight;
  }

  private get connecting(): boolean {
    return !this.connectedOnce || this.connectionDown || this.loading || this.refreshing;
  }

  get syncStatus(): SyncStatus {
    if (this.syncIssues.length > 0 || this.cacheFailure !== null) {
      return "failed";
    }
    if (this.offline) {
      return "offline";
    }
    if (this.connecting) {
      return "connecting";
    }
    if (this.hasLocalChangesInFlight) {
      return "syncing";
    }
    return "synced";
  }

  get state(): NotesState {
    return this.store.getState();
  }

  // ---------------------------------------------------------------------------
  // Working-copy edits (immutable, so unchanged notes keep their identity)

  private putNote(note: Note): void {
    if (!(note.id in this.data.notes)) {
      return;
    }
    this.data = { ...this.data, notes: { ...this.data.notes, [note.id]: note } };
  }

  private insertNote(note: Note, at: "front" | "back"): void {
    const order = this.data.order.filter((id) => id !== note.id);
    this.data = {
      ...this.data,
      notes: { ...this.data.notes, [note.id]: note },
      order: at === "front" ? [note.id, ...order] : [...order, note.id],
    };
  }

  private removeNotes(ids: ReadonlySet<string>): void {
    if (ids.size === 0) {
      return;
    }
    const notes = { ...this.data.notes };
    for (const id of ids) {
      delete notes[id];
    }
    this.data = { ...this.data, notes, order: this.data.order.filter((id) => !ids.has(id)) };
  }

  private setNotesList(list: readonly Note[]): void {
    const notes: Record<string, Note> = {};
    for (const note of list) {
      notes[note.id] = note;
    }
    this.data = { ...this.data, notes, order: list.map((n) => n.id) };
  }

  private sortNotes(): void {
    const notes = this.data.notes;
    const order = [...this.data.order].sort((a, b) => (notes[a]?.position ?? 0) - (notes[b]?.position ?? 0));
    this.data = { ...this.data, order };
  }

  private setDraft(id: string, draft: boolean): boolean {
    const was = id in this.data.drafts;
    if (was === draft) {
      return was;
    }
    const drafts = { ...this.data.drafts };
    if (draft) {
      drafts[id] = true;
    } else {
      delete drafts[id];
    }
    this.data = { ...this.data, drafts };
    return was;
  }

  private isDraftInternal(id: string): boolean {
    return id in this.data.drafts;
  }

  private notesList(): Note[] {
    const out: Note[] = [];
    for (const id of this.data.order) {
      const note = this.data.notes[id];
      if (note) {
        out.push(note);
      }
    }
    return out;
  }

  private replace(updated: Note): void {
    if (!(updated.id in this.data.notes)) {
      return;
    }
    this.putNote(updated);
    if (this.notifyThrottle !== null) {
      clearTimeout(this.notifyThrottle);
      this.notifyThrottle = null;
    }
    this.notify();
  }

  /** State changes now; subscribers hear about it within ~200ms. */
  private replaceThrottled(updated: Note): void {
    if (!(updated.id in this.data.notes)) {
      return;
    }
    this.putNote(updated);
    if (this.notifyThrottle === null) {
      this.notifyThrottle = setTimeout(() => {
        this.notifyThrottle = null;
        this.notify();
      }, NOTIFY_THROTTLE_MS);
    }
  }

  // ---------------------------------------------------------------------------
  // Queries

  noteById(id: string): Note | null {
    return this.data.notes[id] ?? null;
  }

  /** The note as its card should show it while an editor is open. */
  displayNoteById(id: string): Note | null {
    if (id in this.data.editingCards) {
      return this.data.editingCards[id] ?? null;
    }
    return this.noteById(id);
  }

  /** Every note this device holds, in store order. */
  allNotes(): Note[] {
    return this.notesList();
  }

  labelById(id: string): Label | null {
    return this.data.labels.find((l) => l.id === id) ?? null;
  }

  stageById(id: string | null | undefined): Stage | null {
    return this.data.stages.find((s) => s.id === id) ?? null;
  }

  workspaceById(id: string | null | undefined): Workspace | null {
    return this.data.workspaces.find((w) => w.id === id) ?? null;
  }

  get workspaces(): readonly Workspace[] {
    return this.data.workspaces;
  }

  get activeWorkspaceId(): string | null {
    return this.ui.state.activeWorkspaceId;
  }

  get activeWorkspace(): Workspace | null {
    return this.workspaceById(this.activeWorkspaceId);
  }

  get defaultWorkspace(): Workspace | null {
    return this.data.workspaces.find((w) => w.isDefault) ?? this.data.workspaces[0] ?? null;
  }

  /** Collections of the open workspace. */
  get collections(): readonly NoteCollection[] {
    return this.activeWorkspace?.collections ?? [];
  }

  /** The collection open in the active workspace (its remembered one, else the first). */
  get activeCollection(): NoteCollection | null {
    const id = this.activeWorkspaceId === null ? undefined : this.ui.state.collectionChoices[this.activeWorkspaceId];
    const collections = this.collections;
    return collections.find((c) => c.id === id) ?? collections[0] ?? null;
  }

  /** How any one workspace narrows the content this device holds. */
  scopeFor(workspaceId: string | null): WorkspaceScope {
    return {
      workspaceId,
      collectionId: null,
      isDefault: workspaceId !== null && workspaceId === this.defaultWorkspace?.id,
      known: new Set(this.data.workspaces.map((w) => w.id)),
    };
  }

  get workspaceScope(): WorkspaceScope {
    return this.scopeFor(this.activeWorkspaceId);
  }

  get collectionScope(): WorkspaceScope {
    return { ...this.workspaceScope, collectionId: this.activeCollection?.id ?? null };
  }

  /** Labels of [workspaceId] (the open one by default), sidebar order. */
  labelsInWorkspace(workspaceId: string | null = this.activeWorkspaceId): Label[] {
    const scope = this.scopeFor(workspaceId);
    return this.data.labels.filter((l) => scopeContainsWorkspace(scope, l.workspaceId));
  }

  /** Board columns of [workspaceId], left to right. */
  stagesInWorkspace(workspaceId: string | null = this.activeWorkspaceId): Stage[] {
    const scope = this.scopeFor(workspaceId);
    return this.data.stages.filter((s) => scopeContainsWorkspace(scope, s.workspaceId));
  }

  /** Board columns of the active collection. */
  get stages(): Stage[] {
    const collectionId = this.activeCollection?.id;
    return this.stagesInWorkspace().filter((s) => (s.collectionId ?? generalCollectionId(s.workspaceId)) === collectionId);
  }

  /** Column choices for [note], following it even from trash or archive. */
  stagesForNote(note: Note | null): Stage[] {
    if (!note) {
      return [];
    }
    const workspaceId = this.effectiveWorkspaceId(note);
    const collection = note.collectionId ?? generalCollectionId(workspaceId);
    return this.stagesInWorkspace(workspaceId).filter((s) => (s.collectionId ?? generalCollectionId(workspaceId)) === collection);
  }

  /** Smart views of the open workspace. */
  get savedViews(): readonly SavedView[] {
    return this.activeWorkspace?.savedViews ?? [];
  }

  savedViewById(id: string): SavedView | null {
    return this.savedViews.find((v) => v.id === id) ?? null;
  }

  /** Notes filed in [workspaceId], whatever their view, trash included. */
  notesInWorkspace(workspaceId: string | null): Note[] {
    const scope = this.scopeFor(workspaceId);
    return this.notesList().filter((n) => scopeContains(scope, n));
  }

  get notesInActiveWorkspace(): Note[] {
    return this.notesInWorkspace(this.activeWorkspaceId);
  }

  /** Notes carrying a reminder, across every workspace. */
  get notesWithReminders(): Note[] {
    return this.notesList().filter(hasReminder);
  }

  /** Workspaces this account owns. */
  get ownedWorkspaces(): Workspace[] {
    return this.data.workspaces.filter((w) => isWorkspaceOwnedBy(w, this.currentUserId));
  }

  private get ownedWorkspaceIds(): Set<string> {
    return new Set(this.ownedWorkspaces.map((w) => w.id));
  }

  private effectiveWorkspaceId(note: Note): string {
    return note.workspaceId === "" ? (this.defaultWorkspace?.id ?? "") : note.workspaceId;
  }

  /** Non-trashed notes in owned workspaces, in workspace/grid order. */
  get notesForExport(): Note[] {
    const owned = this.ownedWorkspaceIds;
    return this.notesList()
      .filter((n) => !n.trashed && owned.has(this.effectiveWorkspaceId(n)))
      .sort((a, b) => {
        const wa = this.effectiveWorkspaceId(a);
        const wb = this.effectiveWorkspaceId(b);
        return wa !== wb ? (wa < wb ? -1 : 1) : a.position - b.position;
      });
  }

  /** Complete backup inputs; trash included. */
  get notesForBackup(): Note[] {
    const owned = this.ownedWorkspaceIds;
    return this.notesList()
      .filter((n) => owned.has(this.effectiveWorkspaceId(n)))
      .map((n) => (n.workspaceId === "" ? { ...n, workspaceId: this.defaultWorkspace?.id ?? "" } : n));
  }

  get labelsForBackup(): Label[] {
    const owned = this.ownedWorkspaceIds;
    return this.data.labels.filter((l) => owned.has(l.workspaceId));
  }

  get stagesForBackup(): Stage[] {
    const owned = this.ownedWorkspaceIds;
    return this.data.stages.filter((s) => owned.has(s.workspaceId));
  }

  /**
   * Whether closing [id]'s editor may silently remove it. Untouched drafts are
   * transient; a saved note in a shared workspace counts as shared.
   */
  canAutoDiscard(id: string): boolean {
    const note = this.noteById(id);
    if (!note || !noteCanAutoDiscard(note)) {
      return false;
    }
    if (this.isDraftInternal(id)) {
      return true;
    }
    const workspace = this.workspaceById(this.effectiveWorkspaceId(note));
    return !(workspace ? isWorkspaceShared(workspace) : false);
  }

  isDraft(id: string): boolean {
    return this.isDraftInternal(id);
  }

  isRewritingNote(id: string): boolean {
    return id in this.data.rewriting;
  }

  canTrash(id: string): boolean {
    const note = this.noteById(id);
    return note !== null && isNoteOwnedBy(note, this.currentUserId);
  }

  /** You own it and it is not your default one. */
  canDeleteWorkspace(id: string): boolean {
    const w = this.workspaceById(id);
    return w !== null && !w.isDefault && isWorkspaceOwnedBy(w, this.currentUserId);
  }

  /** The AI in workspace [id]; none for a workspace this user is not in. */
  aiIn(id: string | null | undefined): WorkspaceAi {
    return this.workspaceById(id)?.ai ?? NO_WORKSPACE_AI;
  }

  /** Current title of a linked note, or null when unreachable here. */
  linkTitleFor(id: string): string | null {
    const note = this.noteById(id);
    if (!note || note.trashed) {
      return null;
    }
    return noteLinkTitle(note);
  }

  /** Notes linking to note [id], most recently edited first. */
  backlinks(id: string): Note[] {
    return backlinksTo(id, this.notesList());
  }

  /** Notes a link being typed as `[[query` could point at. */
  linkTargets(query: string, excludeId?: string | null): Note[] {
    return linkCandidates(this.notesList(), query, excludeId);
  }

  lastWorkspaceView(workspaceId: string | null): Destination | null {
    return workspaceId === null ? null : (this.ui.state.lastWorkspaceViews[workspaceId] ?? null);
  }

  /**
   * Typing suggestions for checklist rows from items checked off in THIS note;
   * prefix matches first, texts already on the list excluded.
   */
  suggestionsFor(noteId: string | null, query: string, exclude: Iterable<string> = []): string[] {
    const history = noteId === null ? undefined : this.data.checklistHistory[noteId];
    if (!history || history.length === 0) {
      return [];
    }
    const q = query.trim().toLowerCase();
    const excluded = new Set([...exclude].map((e) => e.trim().toLowerCase()));
    const prefix: string[] = [];
    const contains: string[] = [];
    for (const text of history) {
      const lower = text.toLowerCase();
      if (excluded.has(lower)) {
        continue;
      }
      if (q === "" || lower.startsWith(q)) {
        prefix.push(text);
      } else if (lower.includes(q)) {
        contains.push(text);
      }
    }
    return [...prefix, ...contains];
  }

  // ---------------------------------------------------------------------------
  // Navigation (state in the ui store, persistence here)

  /** Switch workspace; reopens the destination last used there. */
  setActiveWorkspace(id: string): void {
    if (this.activeWorkspaceId === id || this.workspaceById(id) === null) {
      return;
    }
    this.enterWorkspace(id);
  }

  private enterWorkspace(id: string | null): void {
    const remembered = id === null ? undefined : this.ui.state.lastWorkspaceViews[id];
    this.ui.store.setState({ activeWorkspaceId: id, selectedIds: [] });
    this.ui.showDestination(remembered ?? "notes");
    this.reconcileDestination();
  }

  /** Open a collection of the active workspace. */
  selectCollection(id: string): void {
    const workspaceId = this.activeWorkspaceId;
    if (workspaceId === null || !this.collections.some((c) => c.id === id)) {
      return;
    }
    this.ui.store.setState({ collectionChoices: { ...this.ui.state.collectionChoices, [workspaceId]: id } });
  }

  /** Remember [destination] as the open workspace's last view. */
  rememberWorkspaceView(destination: Destination): void {
    const workspaceId = this.activeWorkspaceId;
    if (workspaceId === null) {
      return;
    }
    const current = this.ui.state.lastWorkspaceViews[workspaceId];
    if (current && destinationsEqual(current, destination)) {
      return;
    }
    this.ui.store.setState({ lastWorkspaceViews: { ...this.ui.state.lastWorkspaceViews, [workspaceId]: destination } });
  }

  /** Point at a workspace that still exists: the cached choice, else the default. */
  private reconcileActiveWorkspace(): void {
    if (this.data.workspaces.length === 0) {
      return;
    }
    if (this.workspaceById(this.activeWorkspaceId) !== null) {
      this.reconcileDestination();
      return;
    }
    this.enterWorkspace(this.defaultWorkspace?.id ?? null);
  }

  /** A destination pointing at a deleted label or smart view falls back to the notes. */
  private reconcileDestination(): void {
    const destination = this.ui.state.destination;
    if (typeof destination === "string") {
      return;
    }
    const available =
      "label" in destination ? this.labelsInWorkspace().some((l) => l.id === destination.label) : this.savedViewById(destination.smartView) !== null;
    if (!available) {
      this.ui.showDestination("notes");
      this.rememberWorkspaceView("notes");
    }
  }

  // ---------------------------------------------------------------------------
  // Editing cards

  /** An open editor keeps its card still; a new draft's card stays hidden. */
  beginEditing(id: string, start: EditingStart = "existing"): void {
    if (id in this.data.editingCards) {
      return;
    }
    this.data = { ...this.data, editingCards: { ...this.data.editingCards, [id]: start === "new" ? null : this.noteById(id) } };
    // Published at once, so a new draft's card is hidden before the editor paints.
    this.publish();
  }

  endEditing(id: string): void {
    if (!(id in this.data.editingCards)) {
      return;
    }
    const editingCards = { ...this.data.editingCards };
    delete editingCards[id];
    this.data = { ...this.data, editingCards };
    this.notify();
  }

  // ---------------------------------------------------------------------------
  // Loading

  async load(): Promise<void> {
    if (this.disposed) {
      return;
    }
    const generation = ++this.fetchGeneration;
    const isCurrent = (): boolean => !this.disposed && generation === this.fetchGeneration;
    await this.hydrate();
    if (!isCurrent()) {
      return;
    }
    let fetchAgain: boolean;
    do {
      fetchAgain = false;
      const startedWithLocalChanges = this.hasLocalChangesInFlight;
      const revisionAtStart = this.localWriteRevision;
      try {
        // Independent reads start together.
        const [workspaces, notes, labels, stages, history] = await Promise.all([
          this.api.fetchWorkspaces(),
          this.api.fetchNotes(),
          this.api.fetchLabels(),
          this.api.fetchStages(),
          this.api.fetchChecklistHistory(),
        ]);
        if (!isCurrent()) {
          return;
        }
        // A write can enter and leave the queue while these are in flight;
        // checking the queue alone would apply a stale pre-write snapshot.
        const writesChanged = revisionAtStart !== this.localWriteRevision;
        if (!startedWithLocalChanges && !writesChanged && !this.hasLocalChangesInFlight) {
          this.applySnapshot(workspaces, notes, labels, stages, history);
          this.reloadPending = false;
        } else if (this.hasLocalChangesInFlight) {
          this.reloadPending = true;
        } else {
          // The writes drained while fetching: pull once more for the post-write state.
          this.reloadPending = false;
          fetchAgain = true;
        }
        this.markConnectionUp();
      } catch {
        if (!isCurrent()) {
          return;
        }
        this.markConnectionDown();
        this.clearRetry();
        this.retryTimer = setTimeout(() => void this.load(), LOAD_RETRY_MS);
      }
    } while (fetchAgain);
    if (!isCurrent()) {
      return;
    }
    this.addStarterNotes();
    this.loading = false;
    this.notify();
  }

  /** Replace server-owned state, keeping the identity of everything unchanged. */
  private applySnapshot(workspaces: Workspace[], notes: Note[], labels: Label[], stages: Stage[], history: Record<string, string[]>): void {
    this.serverUpdatedAt.clear();
    for (const n of notes) {
      this.serverUpdatedAt.set(n.id, noteServerStamp(n));
    }
    const sorted = [...notes].sort(byPosition);
    const previous = this.data.notes;
    const merged: Record<string, Note> = {};
    let notesChanged = Object.keys(previous).length !== sorted.length;
    for (const note of sorted) {
      const prior = previous[note.id];
      if (prior !== undefined && deepEqual(prior, note)) {
        merged[note.id] = prior;
      } else {
        merged[note.id] = note;
        notesChanged = true;
      }
    }
    const order = sorted.map((n) => n.id);
    const orderSame = order.length === this.data.order.length && order.every((id, i) => id === this.data.order[i]);
    this.data = {
      ...this.data,
      notes: notesChanged ? merged : previous,
      order: orderSame ? this.data.order : order,
      labels: reconcileList(this.data.labels, labels),
      stages: reconcileList(this.data.stages, stages),
      workspaces: reconcileList(this.data.workspaces, workspaces),
      checklistHistory: deepEqual(this.data.checklistHistory, history) ? this.data.checklistHistory : history,
    };
    this.reconcileActiveWorkspace();
  }

  /** Fill a just-created account once the server confirmed it is empty. */
  private addStarterNotes(): void {
    if (this.accountOrigin !== "justCreated" || this.starterNotesHandled || this.connectionDown || this.activeWorkspace === null) {
      return;
    }
    this.starterNotesHandled = true;
    if (this.data.order.length > 0) {
      return;
    }
    // Drafts land in front, so the welcome note is created last to lead.
    const guide = this.createDraft({ kind: "markdown" });
    const checklist = this.createDraft({ kind: "checklist" });
    const welcome = this.createDraft({ kind: "markdown" });
    this.updateNoteContent(guide.id, { title: STARTER_GUIDE_TITLE, content: STARTER_GUIDE_BODY });
    this.updateNoteContent(checklist.id, { title: STARTER_CHECKLIST_TITLE, items: starterChecklistItems(newId) });
    this.updateNoteContent(welcome.id, { title: STARTER_WELCOME_TITLE, content: starterWelcomeBody(checklist.id, guide.id) });
  }

  /** A user-triggered re-pull: drains pending writes first, never flips loading. */
  async refresh(): Promise<void> {
    if (this.disposed || this.refreshing) {
      return;
    }
    this.refreshing = true;
    this.notify();
    this.flushDebouncedSaves();
    if (this.queue.length > 0) {
      void this.flush();
    }
    try {
      await this.load();
    } finally {
      this.refreshing = false;
      this.notify();
    }
  }

  /** The tab came back: drop any offline verdict and pull what we missed. */
  async onResumed(): Promise<void> {
    this.clearOfflineConfirm();
    this.connectionDown = false;
    if (this.offline) {
      this.offline = false;
      this.notify();
    }
    await this.refresh();
  }

  // ---------------------------------------------------------------------------
  // Connectivity

  private markConnectionDown(): void {
    if (this.connectionDown) {
      return;
    }
    this.connectionDown = true;
    this.clearOfflineConfirm();
    this.offlineConfirmTimer = setTimeout(() => {
      this.offlineConfirmTimer = null;
      if (!this.connectionDown || this.offline) {
        return;
      }
      this.offline = true;
      this.notify();
    }, this.offlineGraceMs);
  }

  /** Returns whether that changed anything the UI shows. */
  private markConnectionUp(): boolean {
    this.clearOfflineConfirm();
    const changed = this.connectionDown || !this.connectedOnce || this.offline;
    this.connectionDown = false;
    this.connectedOnce = true;
    this.offline = false;
    return changed;
  }

  private clearOfflineConfirm(): void {
    if (this.offlineConfirmTimer !== null) {
      clearTimeout(this.offlineConfirmTimer);
      this.offlineConfirmTimer = null;
    }
  }

  private clearRetry(): void {
    if (this.retryTimer !== null) {
      clearTimeout(this.retryTimer);
      this.retryTimer = null;
    }
  }

  /** Live sync, the browser's online event, and the periodic health probe. */
  startSync(): void {
    if (this.disposed) {
      return;
    }
    this.unsubscribeEvents?.();
    this.unsubscribeEvents = this.api.changeEvents(() => {
      if (this.syncReloadDebounce !== null) {
        clearTimeout(this.syncReloadDebounce);
      }
      this.syncReloadDebounce = setTimeout(() => {
        this.syncReloadDebounce = null;
        this.onRemoteChange?.();
        if (this.hasLocalChangesInFlight) {
          this.reloadPending = true;
        } else {
          void this.load();
        }
      }, SYNC_RELOAD_DEBOUNCE_MS);
    });
    this.removeOnlineListener?.();
    if (typeof window !== "undefined") {
      const onOnline = (): void => {
        if (this.connectionDown) {
          void this.retryNow();
        }
      };
      window.addEventListener("online", onOnline);
      this.removeOnlineListener = () => window.removeEventListener("online", onOnline);
    }
    if (this.connectionProbe !== null) {
      clearInterval(this.connectionProbe);
    }
    this.connectionProbe = setInterval(() => void this.checkConnectionNow(), CONNECTION_PROBE_INTERVAL_MS);
    void this.checkConnectionNow();
  }

  /** Probe the health endpoint now; a recovery pushes and re-pulls. */
  async checkConnectionNow(): Promise<void> {
    if (this.disposed || this.checkingConnection) {
      return;
    }
    this.checkingConnection = true;
    try {
      await this.api.checkConnection();
      if (this.disposed) {
        return;
      }
      const wasDown = this.connectionDown;
      if (this.markConnectionUp()) {
        this.notify();
      }
      if (wasDown) {
        this.onRemoteChange?.();
        await this.retryNow();
      }
    } catch {
      if (!this.disposed) {
        this.markConnectionDown();
      }
    } finally {
      this.checkingConnection = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Local persistence

  private get legacyCacheKey(): string {
    return notesCacheKey("", this.currentUserId);
  }

  private get cacheKey(): string {
    return notesCacheKey(this.cacheNamespace, this.currentUserId);
  }

  private get navigationKey(): string {
    return navigationCacheKey(this.cacheKey);
  }

  /** Load the on-disk snapshot once, so notes render before the network answers. */
  private async hydrate(): Promise<void> {
    if (this.hydrated) {
      return;
    }
    try {
      let doc = await this.cache.read(this.cacheKey);
      if (doc === null && this.migrateLegacyCache && this.cacheKey !== this.legacyCacheKey) {
        doc = await this.cache.read(this.legacyCacheKey);
        if (doc !== null) {
          await this.cache.write(this.cacheKey, doc);
          await this.cache.clear(this.legacyCacheKey);
        }
      }
      if (doc === null && !this.migrateLegacyCache && this.cacheKey !== this.legacyCacheKey) {
        // Claim this server's namespace now, so a later restored launch cannot
        // reinterpret another server's pending writes as its own.
        doc = notesCacheDocToJson(EMPTY_CACHE_DOC);
        await this.cache.write(this.cacheKey, doc);
      }
      if (doc !== null) {
        const cached = parseNotesCacheDoc(doc);
        const navigation = parseNavigationDoc((await this.cache.read(this.navigationKey)) ?? doc);
        this.setNotesList([...cached.notes].sort(byPosition));
        this.data = {
          ...this.data,
          labels: [...cached.labels].sort(byLabelPosition),
          stages: [...cached.stages].sort(byPosition),
          workspaces: [...cached.workspaces],
          checklistHistory: { ...cached.checklistHistory },
        };
        this.ui.store.setState({
          activeWorkspaceId: navigation.activeWorkspaceId,
          collectionChoices: { ...this.ui.state.collectionChoices, ...navigation.collectionChoices },
          lastWorkspaceViews: { ...navigation.workspaceViews },
        });
        const remembered = navigation.activeWorkspaceId === null ? undefined : navigation.workspaceViews[navigation.activeWorkspaceId];
        if (remembered) {
          this.ui.showDestination(remembered);
        }
        this.reconcileActiveWorkspace();
        this.queue.length = 0;
        this.queue.push(...cached.queue);
        this.syncIssues = [...cached.syncIssues];
        for (const [id, stamp] of Object.entries(cached.serverUpdatedAt)) {
          this.serverUpdatedAt.set(id, stamp);
        }
      }
    } catch {
      // Corrupt/unreadable cache: start empty rather than fail to open.
    }
    this.hydrated = true;
    if (this.data.order.length > 0 || this.data.labels.length > 0 || this.data.stages.length > 0 || this.data.workspaces.length > 0) {
      this.loading = false;
      this.notify();
    }
    if (this.queue.length > 0) {
      void this.flush();
    }
  }

  /** Everything worth keeping across launches; empty drafts are left out. */
  private toCacheDoc(): JsonObject {
    const notes = this.notesList().filter((n) => !(this.isDraftInternal(n.id) && this.canAutoDiscard(n.id)));
    const queue = [...this.queue];
    // An edit still in its debounce has not been enqueued yet; fold it in.
    for (const id of this.saveDebounce.keys()) {
      const note = this.noteById(id);
      if (note) {
        queue.push(this.contentPatchOp(id, note));
      }
    }
    return notesCacheDocToJson({
      notes,
      labels: this.data.labels,
      stages: this.data.stages,
      workspaces: this.data.workspaces,
      checklistHistory: this.data.checklistHistory,
      queue,
      syncIssues: this.syncIssues,
      serverUpdatedAt: Object.fromEntries(this.serverUpdatedAt),
    });
  }

  /** At most one snapshot write per second for plain state changes. */
  private persistSoon(): void {
    if (Date.now() - this.lastPersist < PERSIST_INTERVAL_MS) {
      return;
    }
    this.persistNow();
  }

  private persistNow(): void {
    if (this.disposed || !this.hydrated) {
      return;
    }
    this.lastPersist = Date.now();
    this.persistNavigation();
    this.snapshotWriter.request();
  }

  private async writeSnapshot(): Promise<void> {
    if (this.disposed) {
      return;
    }
    try {
      await this.cache.write(this.cacheKey, this.toCacheDoc());
      if (this.cacheFailure !== null) {
        this.cacheFailure = null;
        this.publish();
      }
    } catch (error) {
      this.cacheFailure = error instanceof Error ? error.message : String(error);
      this.publish();
    }
  }

  /** Try the offline cache write again after a failure. */
  retryCacheWrite(): void {
    this.persistNow();
  }

  private persistNavigation(): void {
    if (this.disposed || !this.hydrated) {
      return;
    }
    this.navigationWriter.request();
  }

  private async writeNavigation(): Promise<void> {
    if (this.disposed) {
      return;
    }
    const ui = this.ui.state;
    try {
      await this.cache.write(
        this.navigationKey,
        navigationDocToJson({ activeWorkspaceId: ui.activeWorkspaceId, collectionChoices: ui.collectionChoices, workspaceViews: ui.lastWorkspaceViews }),
      );
    } catch {
      // Losing it reopens the default workspace, nothing worse.
    }
  }

  /** Resolves once queued cache writes have landed; for tests and teardown. */
  async persisted(): Promise<void> {
    await this.snapshotWriter.idle();
    await this.navigationWriter.idle();
  }

  // ---------------------------------------------------------------------------
  // Note mutations (all optimistic)

  /**
   * A new local note at the front of the active collection. [labelIds] and
   * [stageId] file it from birth (composed inside a label view or a column).
   */
  createDraft(options: { kind?: NoteKind; labelIds?: readonly string[]; stageId?: string | null } = {}): Note {
    const workspaceId = this.activeWorkspaceId ?? "";
    // Intake into an empty workspace needs somewhere to file.
    if (this.activeWorkspace !== null && this.activeCollection === null) {
      this.saveCollection({ ...generalCollection(workspaceId), id: newId() });
    }
    const stageId = options.stageId ?? null;
    const now = new Date();
    const note = makeNote({
      id: newId(),
      workspaceId,
      collectionId: this.activeCollection?.id ?? null,
      kind: options.kind ?? "text",
      position: this.frontPosition(),
      labelIds: [...new Set(options.labelIds ?? [])],
      stageId,
      stagePosition: this.endOfStage(stageId, workspaceId),
      createdAt: now,
      updatedAt: now,
      owner: this.currentUserId === null ? null : { id: this.currentUserId, name: "" },
    });
    this.insertNote(note, "front");
    this.setDraft(note.id, true);
    this.notify();
    return note;
  }

  private frontPosition(): number {
    let min = 0;
    for (const note of Object.values(this.data.notes)) {
      if (note.position < min) {
        min = note.position;
      }
    }
    return min - POSITION_GAP;
  }

  /**
   * Debounced content autosave from the editor. `pace: "typing"` throttles the
   * notify so keystrokes never re-render the grid; discrete changes notify now.
   */
  updateNoteContent(
    id: string,
    changes: { kind?: NoteKind; title?: string; content?: string; items?: readonly ChecklistItem[]; pace?: EditPace },
  ): void {
    const note = this.noteById(id);
    if (!note) {
      return;
    }
    // The server's rule on write: no row deeper than the one above allows.
    const normalized = changes.items === undefined ? undefined : normalizeDepths(changes.items);
    const updated: Note = {
      ...note,
      kind: changes.kind ?? note.kind,
      title: changes.title ?? note.title,
      content: changes.content ?? note.content,
      items: normalized ?? note.items,
      // An item reminder lives only as long as its unchecked item does.
      itemReminders: normalized === undefined ? note.itemReminders : prunedItemReminders(note, normalized),
      updatedAt: new Date(),
    };
    if (changes.pace === "typing") {
      this.replaceThrottled(updated);
    } else {
      this.replace(updated);
    }
    if (this.isDraftInternal(id)) {
      this.materializeIfNeeded(id);
      return;
    }
    const pending = this.saveDebounce.get(id);
    if (pending !== undefined) {
      clearTimeout(pending);
    }
    this.saveDebounce.set(
      id,
      setTimeout(() => {
        this.saveDebounce.delete(id);
        this.enqueueContentPatch(id);
      }, SAVE_DEBOUNCE_MS),
    );
  }

  private enqueueContentPatch(id: string): void {
    const latest = this.noteById(id);
    if (latest) {
      this.enqueue(this.contentPatchOp(id, latest));
    }
  }

  private contentPatchOp(id: string, note: Note): PendingOp {
    return pendingOp("patch", id, { kind: note.kind, title: note.title, content: note.content, items: itemsToJson(note.items) });
  }

  private flushDebouncedSaves(): void {
    for (const [id, timer] of [...this.saveDebounce]) {
      clearTimeout(timer);
      this.saveDebounce.delete(id);
      this.enqueueContentPatch(id);
    }
  }

  /** An explicit AI rewrite, after every pending local edit reached the server. Not optimistic. */
  async rewriteNote(id: string, task: NoteRewriteTask): Promise<void> {
    if (id in this.data.rewriting) {
      return;
    }
    this.data = { ...this.data, rewriting: { ...this.data.rewriting, [id]: true } };
    this.notify();
    try {
      await this.pushPending(id);
      const updated = await this.api.rewriteNote(id, task);
      this.serverUpdatedAt.set(id, noteServerStamp(updated));
      if (this.noteById(id)) {
        this.replace(updated);
      }
    } finally {
      const rewriting = { ...this.data.rewriting };
      delete rewriting[id];
      this.data = { ...this.data, rewriting };
      this.notify();
    }
  }

  private itemById(noteId: string, itemId: string): ChecklistItem | null {
    return this.noteById(noteId)?.items.find((i) => i.id === itemId) ?? null;
  }

  /** Flip a checklist box (from the card, without opening the note). */
  toggleChecklistItem(noteId: string, itemId: string): void {
    const item = this.itemById(noteId, itemId);
    if (item) {
      this.setChecklistItemDone(noteId, itemId, !item.done);
    }
  }

  /** Set a box to an absolute state (idempotent); cascades to subtasks. */
  setChecklistItemDone(noteId: string, itemId: string, done: boolean): void {
    const note = this.noteById(noteId);
    const current = this.itemById(noteId, itemId);
    if (!note || !current || current.done === done) {
      return;
    }
    const items = setDoneCascading(note.items, itemId, done);
    if (done) {
      this.rememberCheckedText(noteId, current.text);
    }
    this.updateNoteContent(noteId, { items });
  }

  /** Keep the local suggestion dictionary warm; the server records it too. */
  rememberCheckedText(noteId: string, text: string): void {
    const trimmed = text.trim();
    if (!trimmed) {
      return;
    }
    const history = this.data.checklistHistory[noteId] ?? [];
    if (history.some((h) => h.toLowerCase() === trimmed.toLowerCase())) {
      return;
    }
    this.data = { ...this.data, checklistHistory: { ...this.data.checklistHistory, [noteId]: [trimmed, ...history] } };
  }

  /** Convert to [target]: lines to items and back, markdown task syntax kept. */
  convertKind(id: string, target: NoteKind): void {
    const note = this.noteById(id);
    if (!note || note.kind === target) {
      return;
    }
    const updated = convertNoteKind(note, target, newId);
    this.replace({ ...updated, updatedAt: new Date() });
    if (this.isDraftInternal(id)) {
      return;
    }
    this.enqueue(pendingOp("patch", id, { kind: updated.kind, content: updated.content, items: itemsToJson(updated.items) }));
  }

  // Filing stays at its queue position, so a later move cannot overtake the
  // creation of the collection, label or column it names.
  private createOp(note: Note): PendingOp {
    return pendingOp("create", note.id, {
      workspace_id: note.workspaceId,
      collection_id: note.collectionId,
      stage_id: note.stageId,
      label_ids: [...note.labelIds],
    });
  }

  private materializeIfNeeded(id: string): void {
    const note = this.noteById(id);
    if (!note || noteCanAutoDiscard(note)) {
      return;
    }
    this.setDraft(id, false);
    this.enqueue(this.createOp(note));
  }

  /** Replace locally and queue a patch; a draft's state rides along in its create. */
  private patchNote(id: string, updated: Note, fields: JsonObject): void {
    this.replace({ ...updated, updatedAt: new Date() });
    if (this.isDraftInternal(id)) {
      return;
    }
    this.enqueue(pendingOp("patch", id, fields));
  }

  /** Pinning an archived note brings it back to the notes. */
  togglePin(id: string): void {
    const note = this.noteById(id);
    if (!note) {
      return;
    }
    if (note.archived && !note.pinned) {
      this.patchNote(id, { ...note, pinned: true, archived: false }, { pinned: true, archived: false });
      return;
    }
    this.patchNote(id, { ...note, pinned: !note.pinned }, { pinned: !note.pinned });
  }

  setColor(id: string, color: string): void {
    const note = this.noteById(id);
    if (note) {
      this.patchNote(id, { ...note, color }, { color });
    }
  }

  setPattern(id: string, pattern: NotePattern): void {
    const note = this.noteById(id);
    if (note) {
      this.patchNote(id, { ...note, pattern }, { pattern });
    }
  }

  /** Card width in grid columns, 1..3. */
  setGridSpan(id: string, span: number): void {
    const note = this.noteById(id);
    if (!note || span === note.gridSpan || span < 1 || span > 3) {
      return;
    }
    this.patchNote(id, { ...note, gridSpan: span }, { grid_span: span });
  }

  /** Archiving unpins. */
  setArchived(id: string, archived: boolean): void {
    const note = this.noteById(id);
    if (note) {
      this.patchNote(id, { ...note, archived, pinned: false }, { archived, pinned: false });
    }
  }

  /** Set, or with null clear, the note's own reminder. Sends explicit nulls. */
  setReminder(id: string, at: Date | null, repeat: ReminderRepeat | null = null): void {
    const note = this.noteById(id);
    if (!note) {
      return;
    }
    const cadence = at === null ? null : repeat;
    this.patchNote(id, { ...note, reminderAt: at, reminderRepeat: cadence }, { reminder_at: at?.toISOString() ?? null, reminder_repeat: cadence });
    // A reminder makes even a wordless draft durable.
    if (at !== null && this.isDraftInternal(id)) {
      this.materializeIfNeeded(id);
    }
  }

  /**
   * Set, or with null clear, one checklist item's reminder. Queued as its own
   * operation (a server sub-resource), never folded into a content patch.
   */
  setItemReminder(noteId: string, itemId: string, at: Date | null, repeat: ReminderRepeat | null = null): void {
    const note = this.noteById(noteId);
    if (!note) {
      return;
    }
    const item = this.itemById(noteId, itemId);
    // Only a present, unchecked item may carry one; clearing is always allowed.
    if (at !== null && (!item || item.done)) {
      return;
    }
    const reminders: Record<string, ItemReminder> = { ...note.itemReminders };
    if (at === null) {
      if (!(itemId in reminders)) {
        return;
      }
      delete reminders[itemId];
    } else {
      reminders[itemId] = { itemId, at, repeat };
    }
    // No updatedAt bump: an alarm moving is not an edit.
    this.replace({ ...note, itemReminders: reminders });
    if (this.isDraftInternal(noteId)) {
      this.materializeIfNeeded(noteId);
      return;
    }
    // The server judges against the saved row, so a pending edit goes first.
    const pending = this.saveDebounce.get(noteId);
    if (pending !== undefined) {
      clearTimeout(pending);
      this.saveDebounce.delete(noteId);
      this.enqueueContentPatch(noteId);
    }
    this.enqueue(pendingOp("itemReminder", noteId, { itemId, at: at?.toISOString() ?? null, repeat: at === null ? null : repeat }));
  }

  moveToTrash(id: string): void {
    const note = this.noteById(id);
    if (note) {
      this.patchNote(id, { ...note, trashed: true, pinned: false }, { trashed: true, pinned: false });
    }
  }

  /** Restore from Trash, optionally into another (live) collection. */
  restoreFromTrash(id: string, collectionId?: string | null): void {
    const note = this.noteById(id);
    if (!note) {
      return;
    }
    const fields: JsonObject = { trashed: false };
    if (collectionId) {
      fields.collection_id = collectionId;
    }
    this.patchNote(id, { ...note, trashed: false, collectionId: collectionId ?? note.collectionId }, fields);
  }

  deleteForever(id: string): void {
    const pending = this.saveDebounce.get(id);
    if (pending !== undefined) {
      clearTimeout(pending);
      this.saveDebounce.delete(id);
    }
    this.removeNotes(new Set([id]));
    const wasDraft = this.setDraft(id, false);
    this.notify();
    if (!wasDraft) {
      this.enqueue(pendingOp("delete", id));
    }
  }

  /** Permanently delete every trashed note this user owns. */
  emptyTrash(): void {
    for (const note of this.notesList().filter((n) => n.trashed && isNoteOwnedBy(n, this.currentUserId))) {
      this.deleteForever(note.id);
    }
  }

  toggleLabelOnNote(noteId: string, labelId: string): void {
    const note = this.noteById(noteId);
    if (!note) {
      return;
    }
    const ids = note.labelIds.includes(labelId) ? note.labelIds.filter((id) => id !== labelId) : [...note.labelIds, labelId];
    this.replace({ ...note, labelIds: ids });
    if (this.isDraftInternal(noteId)) {
      return;
    }
    this.enqueue(pendingOp("patch", noteId, { label_ids: [...ids] }));
  }

  /** Idempotent add (a drop onto a sidebar label); false when already labelled. */
  addLabelToNote(noteId: string, labelId: string): boolean {
    const note = this.noteById(noteId);
    if (!note || note.labelIds.includes(labelId)) {
      return false;
    }
    this.toggleLabelOnNote(noteId, labelId);
    return true;
  }

  /** Persist a drag reorder: renumber exactly the way the server will. */
  reorder(orderedIds: readonly string[]): void {
    const notes = { ...this.data.notes };
    orderedIds.forEach((id, i) => {
      const note = notes[id];
      if (note) {
        notes[id] = { ...note, position: (i + 1) * POSITION_GAP };
      }
    });
    this.data = { ...this.data, notes };
    this.sortNotes();
    this.notify();
    this.enqueue(pendingOp("reorder", null, { ids: [...orderedIds] }));
  }

  /** Clone content into a fresh note at the front; attachments and sharing stay behind. */
  duplicate(id: string): Note | null {
    const source = this.noteById(id);
    if (!source) {
      return null;
    }
    const now = new Date();
    const copy = makeNote({
      id: newId(),
      workspaceId: source.workspaceId,
      collectionId: source.collectionId,
      kind: source.kind,
      title: copyTitle(source.title),
      content: source.content,
      items: source.items.map((item) => ({ id: newId(), text: item.text, done: item.done, depth: 0 })),
      color: source.color,
      pattern: source.pattern,
      position: this.frontPosition(),
      gridSpan: source.gridSpan,
      createdAt: now,
      updatedAt: now,
      labelIds: [...source.labelIds],
      owner: source.owner,
    });
    this.insertNote(copy, "front");
    this.sortNotes();
    this.notify();
    this.enqueue(this.createOp(copy));
    if (copy.labelIds.length > 0) {
      this.enqueue(pendingOp("patch", copy.id, { label_ids: [...copy.labelIds] }));
    }
    return copy;
  }

  /** Flush pending edits when an editor closes. True when an empty note was discarded. */
  finalizeNote(id: string, mode: FinalizeMode = "discardIfEmpty"): boolean {
    const note = this.noteById(id);
    if (!note) {
      return false;
    }
    if (mode === "discardIfEmpty" && this.canAutoDiscard(id)) {
      this.deleteForever(id);
      return true;
    }
    if (this.isDraftInternal(id)) {
      if (mode === "keepEmpty") {
        this.setDraft(id, false);
        this.enqueue(this.createOp(note));
      } else {
        this.materializeIfNeeded(id);
      }
      return false;
    }
    const pending = this.saveDebounce.get(id);
    if (pending !== undefined) {
      clearTimeout(pending);
      this.saveDebounce.delete(id);
      this.enqueueContentPatch(id);
    }
    return false;
  }

  /** The tab is going away: enqueue debounced edits and snapshot now. */
  flushForBackground(): void {
    this.flushDebouncedSaves();
    this.persistNow();
  }

  // ---------------------------------------------------------------------------
  // Sharing and history (awaited: the dialogs want immediate results)

  /** Rejects with ApiError (friendly `serverMessage`) on refusal. */
  async addCollaborator(noteId: string, email: string): Promise<void> {
    await this.pushPending(noteId);
    const updated = await this.api.addCollaborator(noteId, email);
    const local = this.noteById(noteId);
    if (local) {
      this.replace({ ...local, collaborators: updated.collaborators });
    }
  }

  /** Remove a collaborator; removing yourself leaves the note. */
  removeCollaborator(noteId: string, userId: string): void {
    const note = this.noteById(noteId);
    if (!note) {
      return;
    }
    if (userId === this.currentUserId) {
      this.removeNotes(new Set([noteId]));
      this.notify();
    } else {
      this.replace({ ...note, collaborators: note.collaborators.filter((c) => c.id !== userId) });
    }
    this.enqueue(pendingOp("removeCollaborator", noteId, { userId }));
  }

  /** Make sure the server has this note and every pending edit to it. */
  private async pushPending(noteId: string): Promise<void> {
    const pending = this.saveDebounce.get(noteId);
    if (pending !== undefined) {
      clearTimeout(pending);
      this.saveDebounce.delete(noteId);
    }
    if (this.isDraftInternal(noteId)) {
      this.materializeIfNeeded(noteId);
    } else if (pending !== undefined) {
      this.enqueueContentPatch(noteId);
    }
    await this.drainQueue();
  }

  /** A note's edit history, newest first, after flushing pending edits. */
  async noteVersions(id: string): Promise<NoteVersion[]> {
    await this.pushPending(id);
    return this.api.fetchNoteVersions(id);
  }

  /** Roll content back to a past version (the server checkpoints first). */
  async restoreNoteVersion(id: string, versionId: string): Promise<void> {
    await this.pushPending(id);
    const updated = await this.api.restoreNoteVersion(id, versionId);
    this.serverUpdatedAt.set(id, noteServerStamp(updated));
    if (this.noteById(id)) {
      this.replace(updated);
    }
  }

  /** Meaning-ranked notes of the open workspace, never trashed ones. Rejects on server errors. */
  async semanticSearch(query: string): Promise<Note[]> {
    const ids = await this.api.semanticSearch(query, { workspaceId: this.activeWorkspaceId });
    return ids.map((id) => this.noteById(id)).filter((n): n is Note => n !== null && !n.trashed);
  }

  // ---------------------------------------------------------------------------
  // Labels (workspace taxonomy)

  createLabel(name: string, style: { color?: string | null; icon?: string | null } = {}): Label {
    const workspaceId = this.activeWorkspaceId ?? "";
    const label: Label = {
      id: newId(),
      workspaceId,
      name: name.trim(),
      color: style.color ?? null,
      icon: style.icon ?? null,
      position: this.nextPosition(this.data.labels, workspaceId),
    };
    this.data = { ...this.data, labels: [...this.data.labels, label].sort(byLabelPosition) };
    this.notify();
    this.enqueue(
      pendingOp("labelCreate", label.id, { name: label.name, workspaceId, color: label.color, icon: label.icon, position: label.position }),
    );
    return label;
  }

  private nextPosition(items: readonly { workspaceId: string; position: number }[], workspaceId: string): number {
    let max = 0;
    for (const item of items) {
      if (item.workspaceId === workspaceId && item.position > max) {
        max = item.position;
      }
    }
    return max + POSITION_GAP;
  }

  /**
   * Rename and/or restyle. Colour and icon are set to exactly what is given
   * (null clears), not merged; omitting [position] leaves the order alone.
   */
  updateLabel(id: string, changes: { name?: string; color?: string | null; icon?: string | null; position?: number | null }): void {
    const existing = this.labelById(id);
    if (!existing) {
      return;
    }
    const name = (changes.name ?? existing.name).trim();
    const updated: Label = {
      ...existing,
      name,
      color: changes.color ?? null,
      icon: changes.icon ?? null,
      position: changes.position ?? existing.position,
    };
    this.data = { ...this.data, labels: this.data.labels.map((l) => (l.id === id ? updated : l)).sort(byLabelPosition) };
    this.notify();
    this.enqueue(
      pendingOp("labelUpdate", id, { name, color: updated.color, icon: updated.icon, position: changes.position ?? null }),
    );
  }

  /** Drag-reorder; [newIndex] is the final resting index. */
  moveLabel(id: string, newIndex: number): void {
    const ordered = this.labelsInWorkspace();
    const label = ordered.find((l) => l.id === id);
    if (!label) {
      return;
    }
    const others = ordered.filter((l) => l.id !== id).map((l) => l.position);
    this.updateLabel(id, { name: label.name, color: label.color, icon: label.icon, position: positionAt(others, newIndex, label.position) });
  }

  deleteLabel(id: string): void {
    const notes: Record<string, Note> = { ...this.data.notes };
    for (const [noteId, note] of Object.entries(notes)) {
      if (note.labelIds.includes(id)) {
        notes[noteId] = { ...note, labelIds: note.labelIds.filter((l) => l !== id) };
      }
    }
    this.data = { ...this.data, notes, labels: this.data.labels.filter((l) => l.id !== id) };
    this.reconcileDestination();
    this.notify();
    this.enqueue(pendingOp("labelDelete", id));
  }

  // ---------------------------------------------------------------------------
  // Stages (board columns): parallel to labels on purpose, never shared code.

  createStage(name: string, color: string | null = null): Stage {
    const workspaceId = this.activeWorkspaceId ?? "";
    const collectionId = this.activeCollection?.id ?? null;
    const stage: Stage = { id: newId(), workspaceId, collectionId, name: name.trim(), color, position: this.nextPosition(this.data.stages, workspaceId) };
    this.data = { ...this.data, stages: [...this.data.stages, stage].sort(byPosition) };
    this.notify();
    this.enqueue(pendingOp("stageCreate", stage.id, { name: stage.name, workspaceId, collectionId, color, position: stage.position }));
    return stage;
  }

  /** Rename and/or recolour (null clears); omitting [position] keeps the order. */
  updateStage(id: string, changes: { name?: string; color?: string | null; position?: number | null }): void {
    const existing = this.stageById(id);
    if (!existing) {
      return;
    }
    const name = (changes.name ?? existing.name).trim();
    const updated: Stage = { ...existing, name, color: changes.color ?? null, position: changes.position ?? existing.position };
    this.data = { ...this.data, stages: this.data.stages.map((s) => (s.id === id ? updated : s)).sort(byPosition) };
    this.notify();
    this.enqueue(pendingOp("stageUpdate", id, { name, color: updated.color, position: changes.position ?? null }));
  }

  /** Drag-reorder a column; [newIndex] counts after its own removal. */
  moveStage(id: string, newIndex: number): void {
    const ordered = this.stages;
    const stage = ordered.find((s) => s.id === id);
    if (!stage) {
      return;
    }
    const others = ordered.filter((s) => s.id !== id).map((s) => s.position);
    this.updateStage(id, { name: stage.name, color: stage.color, position: positionAt(others, newIndex, stage.position) });
  }

  /** Delete a column; its notes go back to unassigned. */
  deleteStage(id: string): void {
    const notes: Record<string, Note> = { ...this.data.notes };
    for (const [noteId, note] of Object.entries(notes)) {
      if (note.stageId === id) {
        notes[noteId] = { ...note, stageId: null };
      }
    }
    this.data = { ...this.data, notes, stages: this.data.stages.filter((s) => s.id !== id) };
    this.notify();
    this.enqueue(pendingOp("stageDelete", id));
  }

  /**
   * Move a note to [stageId] (null for unassigned). One patch carries both
   * stage_id and stage_position. Without [position] the card goes to the end.
   */
  setNoteStage(noteId: string, stageId: string | null, position?: number | null): void {
    const note = this.noteById(noteId);
    if (!note) {
      return;
    }
    if (note.stageId === stageId && (position === undefined || position === null)) {
      return;
    }
    const target = position ?? this.endOfStage(stageId, note.workspaceId);
    if (note.stageId === stageId && note.stagePosition === target) {
      return;
    }
    this.patchNote(noteId, { ...note, stageId, stagePosition: target }, { stage_id: stageId, stage_position: target });
  }

  /** One slot past the last card of [stageId] in [workspaceId]. */
  private endOfStage(stageId: string | null, workspaceId: string): number {
    let max = 0;
    for (const note of Object.values(this.data.notes)) {
      if (note.workspaceId !== workspaceId || note.stageId !== stageId) {
        continue;
      }
      if (note.stagePosition > max) {
        max = note.stagePosition;
      }
    }
    return max + POSITION_GAP;
  }

  // ---------------------------------------------------------------------------
  // Workspaces and collections

  private replaceWorkspace(id: string, update: (w: Workspace) => Workspace): Workspace | null {
    const current = this.workspaceById(id);
    if (!current) {
      return null;
    }
    const next = update(current);
    this.data = { ...this.data, workspaces: this.data.workspaces.map((w) => (w.id === id ? next : w)) };
    return next;
  }

  /** Awaited: needs every queued write on the server first. Switches to the copy. */
  async duplicateWorkspace(id: string, name: string, content: WorkspaceCopyContent, options: { reminders?: boolean } = {}): Promise<void> {
    this.flushForBackground();
    await this.drainQueue();
    if (this.connectionDown || this.queue.length > 0) {
      throw new Error("Connect and finish syncing before duplicating a workspace");
    }
    const copy = await this.api.duplicateWorkspace(id, name, content, options);
    await this.refresh();
    this.setActiveWorkspace(copy.id);
  }

  /** Create or update a collection (shared settings: layout, icon, colour, sort). */
  saveCollection(collection: NoteCollection): void {
    this.ui.clearSortOverride(collection.id);
    this.replaceWorkspace(collection.workspaceId, (w) => ({
      ...w,
      collections: [...w.collections.filter((c) => c.id !== collection.id), collection].sort(byPosition),
    }));
    this.enqueue(pendingOp("collectionPut", collection.id, collectionToJson(collection)));
    this.notify();
  }

  /** Drag-reorder a collection in the active workspace. */
  moveCollection(id: string, newIndex: number): void {
    const workspace = this.activeWorkspace;
    const collection = workspace?.collections.find((c) => c.id === id);
    if (!workspace || !collection) {
      return;
    }
    const others = workspace.collections.filter((c) => c.id !== id).map((c) => c.position);
    this.saveCollection({ ...collection, position: positionAt(others, newIndex, collection.position) });
  }

  /** Tombstone a collection: its notes go to workspace trash, its columns go. */
  deleteCollection(id: string): void {
    const workspaceId = this.data.workspaces.find((w) => w.collections.some((c) => c.id === id))?.id;
    if (workspaceId === undefined) {
      return;
    }
    this.replaceWorkspace(workspaceId, (w) => ({ ...w, collections: w.collections.filter((c) => c.id !== id) }));
    const notes: Record<string, Note> = { ...this.data.notes };
    for (const [noteId, note] of Object.entries(notes)) {
      if (note.collectionId === id) {
        notes[noteId] = { ...note, trashed: true, stageId: null };
      }
    }
    this.data = { ...this.data, notes, stages: this.data.stages.filter((s) => s.collectionId !== id) };
    this.enqueue(pendingOp("collectionDelete", id, { workspaceId }));
    this.notify();
  }

  private hasCollection(workspaceId: string, collectionId: string): boolean {
    return this.workspaceById(workspaceId)?.collections.some((c) => c.id === collectionId) ?? false;
  }

  /** File a note in another collection of its workspace; keeps labels, clears the stage. */
  moveToCollection(noteId: string, collectionId: string): void {
    const note = this.noteById(noteId);
    if (!note || !this.hasCollection(note.workspaceId, collectionId)) {
      return;
    }
    this.patchNote(noteId, { ...note, collectionId, stageId: null }, { collection_id: collectionId, stage_id: null });
  }

  /** File into [collectionId] as a live note, out of archive or trash in the same patch. */
  restoreToCollection(noteId: string, collectionId: string): void {
    const note = this.noteById(noteId);
    if (!note || !this.hasCollection(note.workspaceId, collectionId)) {
      return;
    }
    if (!note.archived && !note.trashed) {
      this.moveToCollection(noteId, collectionId);
      return;
    }
    this.patchNote(
      noteId,
      { ...note, collectionId, stageId: null, archived: false, trashed: false },
      { collection_id: collectionId, stage_id: null, archived: false, trashed: false },
    );
  }

  /** A new smart view at the end of the open workspace's list. */
  addSavedView(view: { name: string; query: string; icon?: string | null; color?: string | null }): SavedView {
    const last = this.savedViews[this.savedViews.length - 1];
    const saved: SavedView = {
      id: newId(),
      name: view.name.trim(),
      query: view.query.trim(),
      icon: view.icon ?? null,
      color: view.color ?? null,
      position: positionBetween(last?.position, null),
    };
    this.putSavedView(saved);
    return saved;
  }

  /** Edit a smart view; icon and colour are set exactly (null clears). */
  updateSavedView(id: string, view: { name: string; query: string; icon?: string | null; color?: string | null }): void {
    const existing = this.savedViewById(id);
    if (!existing) {
      return;
    }
    this.putSavedView({ ...existing, name: view.name.trim(), query: view.query.trim(), icon: view.icon ?? null, color: view.color ?? null });
  }

  private putSavedView(view: SavedView): void {
    const workspace = this.activeWorkspace;
    if (!workspace) {
      return;
    }
    this.replaceWorkspace(workspace.id, (w) => ({ ...w, savedViews: [...w.savedViews.filter((v) => v.id !== view.id), view].sort(byPosition) }));
    this.notify();
    this.enqueue(pendingOp("savedViewPut", view.id, { workspaceId: workspace.id, view: savedViewToJson(view) }));
  }

  removeSavedView(id: string): void {
    const workspace = this.activeWorkspace;
    if (!workspace || this.savedViewById(id) === null) {
      return;
    }
    this.replaceWorkspace(workspace.id, (w) => ({ ...w, savedViews: w.savedViews.filter((v) => v.id !== id) }));
    this.reconcileDestination();
    this.notify();
    this.enqueue(pendingOp("savedViewDelete", id, { workspaceId: workspace.id }));
  }

  reorderSavedViews(oldIndex: number, newIndex: number): void {
    const next = [...this.savedViews];
    if (oldIndex < 0 || oldIndex >= next.length) {
      return;
    }
    const [view] = next.splice(oldIndex, 1);
    if (!view) {
      return;
    }
    this.putSavedView({ ...view, position: positionAt(next.map((v) => v.position), newIndex, view.position) });
  }

  /** Create a workspace and switch to it, optimistically. */
  createWorkspace(name: string): Workspace {
    const id = newId();
    const workspace = makeWorkspace({
      id,
      name: name.trim(),
      collections: [generalCollection(id)],
      owner: this.currentUserId === null ? null : { id: this.currentUserId, name: "" },
    });
    this.data = { ...this.data, workspaces: [...this.data.workspaces, workspace] };
    this.enterWorkspace(id);
    this.notify();
    this.enqueue(pendingOp("workspaceCreate", id, { name: workspace.name }));
    return workspace;
  }

  renameWorkspace(id: string, name: string): void {
    const trimmed = name.trim();
    if (!trimmed || !this.replaceWorkspace(id, (w) => ({ ...w, name: trimmed }))) {
      return;
    }
    this.notify();
    this.enqueue(pendingOp("workspaceRename", id, { name: trimmed }));
  }

  /** Owner only; at least one of the two must stay on. */
  updateWorkspaceViews(id: string, views: { notesEnabled: boolean; boardEnabled: boolean }): void {
    if (!views.notesEnabled && !views.boardEnabled) {
      return;
    }
    const w = this.workspaceById(id);
    if (!w || !isWorkspaceOwnedBy(w, this.currentUserId)) {
      return;
    }
    this.replaceWorkspace(id, (x) => ({ ...x, ...views }));
    this.notify();
    this.enqueue(pendingOp("workspaceViews", id, { notesEnabled: views.notesEnabled, boardEnabled: views.boardEnabled }));
  }

  /** Owner only: which AI every member gets here. */
  updateWorkspaceAi(id: string, switches: AiSwitches): void {
    const w = this.workspaceById(id);
    if (!w || !isWorkspaceOwnedBy(w, this.currentUserId)) {
      return;
    }
    this.replaceWorkspace(id, (x) => ({ ...x, ai: { ...x.ai, switches } }));
    this.notify();
    this.enqueue(pendingOp("workspaceAi", id, aiSwitchesToJson(switches)));
  }

  /** Permanently delete a workspace and every note in it. */
  deleteWorkspace(id: string): void {
    if (!this.canDeleteWorkspace(id)) {
      return;
    }
    const doomed = new Set(this.notesList().filter((n) => n.workspaceId === id).map((n) => n.id));
    for (const noteId of doomed) {
      const pending = this.saveDebounce.get(noteId);
      if (pending !== undefined) {
        clearTimeout(pending);
        this.saveDebounce.delete(noteId);
      }
      this.setDraft(noteId, false);
    }
    this.removeNotes(doomed);
    this.dropWorkspace(id);
    this.notify();
    this.enqueue(pendingOp("workspaceDelete", id));
  }

  private dropWorkspace(id: string): void {
    this.data = {
      ...this.data,
      labels: this.data.labels.filter((l) => l.workspaceId !== id),
      stages: this.data.stages.filter((s) => s.workspaceId !== id),
      workspaces: this.data.workspaces.filter((w) => w.id !== id),
    };
    const views = { ...this.ui.state.lastWorkspaceViews };
    delete views[id];
    this.ui.store.setState({ lastWorkspaceViews: views });
    this.reconcileActiveWorkspace();
  }

  /** Leave a workspace someone else owns; directly shared notes stay. */
  leaveWorkspace(id: string): void {
    const me = this.currentUserId;
    const workspace = this.workspaceById(id);
    if (me === null || !workspace || isWorkspaceOwnedBy(workspace, me)) {
      return;
    }
    const departure = reconcileWorkspaceDeparture(this.notesList(), this.data.labels, id, me);
    this.setNotesList(departure.notes);
    this.dropWorkspace(id);
    this.notify();
    this.enqueue(pendingOp("leaveWorkspace", id, { userId: me }));
  }

  /** Awaited; rejects with ApiError on refusal. */
  async addWorkspaceMember(workspaceId: string, email: string): Promise<void> {
    await this.drainQueue();
    const updated = await this.api.addWorkspaceMember(workspaceId, email);
    if (this.replaceWorkspace(workspaceId, (w) => ({ ...w, members: updated.members }))) {
      this.notify();
    }
  }

  /** Remove a member; removing yourself leaves. */
  removeWorkspaceMember(workspaceId: string, userId: string): void {
    if (userId === this.currentUserId) {
      this.leaveWorkspace(workspaceId);
      return;
    }
    if (!this.replaceWorkspace(workspaceId, (w) => ({ ...w, members: w.members.filter((m) => m.id !== userId) }))) {
      return;
    }
    this.notify();
    this.enqueue(pendingOp("leaveWorkspace", workspaceId, { userId }));
  }

  /** Owner only. Labels from the old workspace are dropped; the stage clears. */
  moveNoteToWorkspace(noteId: string, workspaceId: string): void {
    const note = this.noteById(noteId);
    const target = this.workspaceById(workspaceId);
    if (!note || note.workspaceId === workspaceId || !isNoteOwnedBy(note, this.currentUserId) || !target) {
      return;
    }
    const collectionId = target.collections[0]?.id;
    if (collectionId === undefined) {
      return;
    }
    const kept = note.labelIds.filter((id) => this.labelById(id)?.workspaceId === workspaceId);
    this.patchNote(
      noteId,
      { ...note, workspaceId, collectionId, labelIds: kept, stageId: null },
      { workspace_id: workspaceId, collection_id: collectionId, stage_id: null },
    );
  }

  // ---------------------------------------------------------------------------
  // Attachments and audio

  /** Awaited: the editor shows progress and needs the server's attachment. */
  async uploadFile(noteId: string, body: UploadBody, mime: string, filename: string): Promise<Attachment> {
    await this.materializeForAttachment(noteId);
    await this.drainQueue();
    const attachment = await this.api.uploadAttachment(noteId, body, mime, filename);
    const note = this.noteById(noteId);
    if (note) {
      this.replace({ ...note, attachments: [...note.attachments, attachment] });
    }
    return attachment;
  }

  /** Force-create a draft even while textually empty: the file is the content. */
  private async materializeForAttachment(noteId: string): Promise<void> {
    if (!this.isDraftInternal(noteId)) {
      return;
    }
    this.setDraft(noteId, false);
    const note = this.noteById(noteId);
    if (note) {
      const created = await this.api.createNote(note);
      this.serverUpdatedAt.set(noteId, noteServerStamp(created));
    }
  }

  /** Dropped files become one note; null (and no phantom note) when nothing uploaded. */
  async createNoteWithFiles(files: readonly DroppedFile[], labelIds: readonly string[] = []): Promise<string | null> {
    const note = this.createDraft({ labelIds });
    let uploaded = 0;
    for (const file of files) {
      try {
        await this.uploadFile(note.id, file.bytes, file.mime, file.name);
        uploaded++;
      } catch {
        // Skip the failed file; the rest may still make it.
      }
    }
    if (uploaded === 0) {
      this.deleteForever(note.id);
      return null;
    }
    return note.id;
  }

  /** Shared text or a link becomes one text note; null when there was nothing. */
  createTextNote(content: string, title = ""): string | null {
    const body = content.trim();
    const heading = title.trim();
    if (!body && !heading) {
      return null;
    }
    const note = this.createDraft();
    this.updateNoteContent(note.id, { title: heading, content: body });
    return note.id;
  }

  removeAttachment(noteId: string, attachmentId: string): void {
    const note = this.noteById(noteId);
    if (!note) {
      return;
    }
    this.replace({ ...note, attachments: note.attachments.filter((a) => a.id !== attachmentId) });
    this.enqueue(pendingOp("deleteAttachment", attachmentId));
  }

  /** Ready-to-load (signed) URL for an attachment. */
  fileUrl(attachment: Attachment): string {
    return this.api.attachmentUrl(attachment);
  }

  /**
   * A finished recording becomes an audio note. Shown as transcribing at once
   * when the server transcribes. Null (draft discarded) when the upload failed.
   */
  async createAudioNote(body: UploadBody, mime: string, options: { labelIds?: readonly string[]; transcription?: "available" | "unavailable" } = {}): Promise<string | null> {
    const note = this.createDraft({ kind: "audio", labelIds: options.labelIds });
    if (options.transcription === "available") {
      this.replace({ ...note, transcriptStatus: "pending" });
    }
    const ext = audioExtension(mime);
    try {
      await this.uploadFile(note.id, body, mime, `recording.${ext}`);
    } catch {
      this.deleteForever(note.id);
      return null;
    }
    return note.id;
  }

  /** Retry a failed transcription; flips back to transcribing at once. */
  retranscribe(id: string): void {
    const note = this.noteById(id);
    if (!note) {
      return;
    }
    this.replace({ ...note, transcriptStatus: "pending" });
    this.enqueue(pendingOp("transcribe", id));
  }

  /** Stop the server's automatic link summaries. Not queued: the job lives in server memory. */
  async cancelLinkSummaries(id: string): Promise<void> {
    const note = this.noteById(id);
    if (!note || !note.summarizingLinks) {
      return;
    }
    this.replace({ ...note, summarizingLinks: false });
    try {
      await this.api.cancelLinkSummaries(id);
    } catch {
      void this.refresh();
    }
  }

  // ---------------------------------------------------------------------------
  // Backup restore and Keep import (awaited, refused while offline)

  /** Replace this account's owned workspace data with workspaces from a backup. */
  async restoreBackup(bundle: BackupBundle, options: { workspaceIds?: ReadonlySet<string>; onProgress?: BackupProgress } = {}): Promise<BackupRestoreResult> {
    const selected = bundle.workspaces.filter((w) => options.workspaceIds?.has(w.id) ?? true);
    if (selected.length === 0) {
      throw new BackupRestoreError("Choose at least one workspace to restore", 0);
    }
    return this.bulkWrite("Connect to the server before restoring a backup", () => {
      const owned = this.ownedWorkspaces;
      const ownedIds = new Set(owned.map((w) => w.id));
      const defaultId = this.defaultWorkspace?.id;
      return new BulkImporter(this.api, this.currentUserId).restoreBackup(
        selected,
        {
          notes: this.notesList().filter((n) => ownedIds.has(this.effectiveWorkspaceId(n)) && isNoteOwnedBy(n, this.currentUserId)),
          defaultWorkspace: this.defaultWorkspace,
          defaultLabels: this.data.labels.filter((l) => l.workspaceId === defaultId),
          defaultStages: this.data.stages.filter((s) => s.workspaceId === defaultId),
          otherWorkspaces: owned.filter((w) => !w.isDefault),
        },
        options.onProgress,
      );
    });
  }

  /** Add a Google Keep export beside what is already there. */
  importKeep(
    archive: KeepArchive,
    options: { workspaceId: string; collectionId: string; trash?: KeepTrash; onProgress?: BackupProgress },
  ): Promise<KeepImportResult> {
    return this.bulkWrite("Connect to the server before importing", () =>
      new BulkImporter(this.api, this.currentUserId).importKeep(archive, {
        workspaceId: options.workspaceId,
        collectionId: options.collectionId,
        existingLabels: this.labelsInWorkspace(options.workspaceId),
        frontPosition: this.frontPosition(),
        trash: options.trash,
        onProgress: options.onProgress,
      }),
    );
  }

  private async bulkWrite<T>(offlineMessage: string, write: () => Promise<T>): Promise<T> {
    this.flushForBackground();
    await this.drainQueue();
    if (this.connectionDown || this.queue.length > 0) {
      throw new BackupRestoreError(offlineMessage, 0);
    }
    this.restoringBackup = true;
    this.notify();
    try {
      return await write();
    } finally {
      this.restoringBackup = false;
      await this.refresh();
      this.notify();
      if (this.reloadPending) {
        this.reloadPending = false;
        void this.load();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Sync queue

  private enqueue(op: PendingOp): void {
    if (this.disposed) {
      return;
    }
    this.localWriteRevision++;
    this.queue.push(op);
    this.persistNow();
    this.publish();
    void this.flush();
  }

  /** Forget a refused write (and re-pull to undo its optimistic effect). */
  dismissSyncIssue(issue: SyncIssue): void {
    const index = this.syncIssues.indexOf(issue);
    if (index < 0) {
      return;
    }
    this.syncIssues = this.syncIssues.filter((i) => i !== issue);
    this.persistNow();
    this.notify();
    if (this.queue.length === 0) {
      void this.load();
    }
  }

  /** Put a refused write back on the queue, restoring the note as it stood. */
  retrySyncIssue(issue: SyncIssue): void {
    if (!this.syncIssues.includes(issue)) {
      return;
    }
    this.syncIssues = this.syncIssues.filter((i) => i !== issue);
    if (issue.note) {
      const restored = parseNote(issue.note);
      if (this.noteById(restored.id) === null) {
        this.insertNote(restored, "back");
      } else {
        this.putNote(restored);
      }
    }
    this.persistNow();
    this.notify();
    this.enqueue(issue.operation);
  }

  /** Wait for the serial queue to empty (before awaited calls that depend on it). */
  private async drainQueue(): Promise<void> {
    while (!this.disposed && this.queue.length > 0 && !this.connectionDown) {
      if (this.retryTimer !== null) {
        return;
      }
      await this.flush();
      if (this.queue.length > 0) {
        await new Promise<void>((resolve) => setTimeout(resolve, DRAIN_POLL_MS));
      }
    }
  }

  private async flush(): Promise<void> {
    if (this.disposed || this.flushing) {
      return;
    }
    this.flushing = true;
    try {
      while (!this.disposed && this.queue.length > 0) {
        const op = this.queue[0] as PendingOp;
        try {
          // Exactly one mutation in flight, so a slow one cannot land after a newer one.
          await this.executor.run(op);
          if (this.disposed) {
            break;
          }
          this.queue.shift();
          this.persistNow();
          const connectionChanged = this.markConnectionUp();
          if (connectionChanged || this.queue.length === 0) {
            this.notify();
          } else {
            this.publish();
          }
        } catch (error) {
          if (this.disposed) {
            break;
          }
          if (!(error instanceof ApiError)) {
            this.scheduleRetry("markDown", QUEUE_RETRY_MS);
            break;
          }
          const decision = syncFailureDecision(error.statusCode);
          if (decision.kind === "drop") {
            this.syncIssues = [
              ...this.syncIssues.filter((i) => !(i.operation.id === op.id && i.operation.kind === op.kind && i.statusCode === error.statusCode)),
              {
                operation: op,
                message: error.serverMessage,
                statusCode: error.statusCode,
                note: op.id === null ? null : ((n) => (n ? noteToJson(n) : null))(this.noteById(op.id)),
              },
            ];
            this.queue.shift();
            this.persistNow();
            this.notify();
            continue;
          }
          this.scheduleRetry(decision.markConnectionDown ? "markDown" : "keepUp", decision.retryDelayMs);
          break;
        }
      }
    } finally {
      this.flushing = false;
    }
    if (!this.disposed && this.queue.length === 0 && this.reloadPending && !this.hasLocalChangesInFlight) {
      this.reloadPending = false;
      void this.load();
    }
  }

  private scheduleRetry(connection: "markDown" | "keepUp", delayMs: number): void {
    if (this.disposed) {
      return;
    }
    if (connection === "markDown") {
      this.markConnectionDown();
    }
    this.clearRetry();
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      void this.flush();
    }, delayMs);
  }

  /** Push the queue now (or reload when it is empty). */
  async retryNow(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.clearRetry();
    if (this.queue.length === 0) {
      await this.load();
    } else {
      await this.flush();
    }
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.clearRetry();
    this.clearOfflineConfirm();
    if (this.syncReloadDebounce !== null) {
      clearTimeout(this.syncReloadDebounce);
    }
    if (this.connectionProbe !== null) {
      clearInterval(this.connectionProbe);
    }
    if (this.notifyThrottle !== null) {
      clearTimeout(this.notifyThrottle);
    }
    this.unsubscribeEvents?.();
    this.unsubscribeUi?.();
    this.removeOnlineListener?.();
    for (const timer of this.saveDebounce.values()) {
      clearTimeout(timer);
    }
  }
}

function audioExtension(mime: string): string {
  switch ((mime.split(";")[0] ?? "").trim()) {
    case "audio/webm":
      return "webm";
    case "audio/ogg":
      return "ogg";
    case "audio/mp4":
      return "m4a";
    case "audio/mpeg":
      return "mp3";
    case "audio/wav":
    case "audio/x-wav":
      return "wav";
    default:
      return "audio";
  }
}

