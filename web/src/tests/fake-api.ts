import type { AccountUpdate, Api, AuthResult, ChatStream, ProbeResult, ShareLinkRequest, Unsubscribe, UploadBody } from "@/lib/api/client";
import { ApiError } from "@/lib/api/errors";
import {
  makeNote,
  makeWorkspace,
  noteKindFromWire,
  notePatternFromWire,
  parseChecklistItem,
  reminderRepeatFromWire,
  type AiSwitches,
  type ApiToken,
  type Attachment,
  type AuthUser,
  type Capabilities,
  type ChatEvent,
  type ChatMessage,
  type CreatedApiToken,
  type ItemReminder,
  type Label,
  type LinkPreview,
  type ManagedSetting,
  type Note,
  type NoteCollection,
  type NoteRewriteTask,
  type NoteVersion,
  type PublicShare,
  type ReindexStatus,
  type ReminderRepeat,
  type SavedView,
  type SearchStats,
  type ShareLink,
  type Stage,
  type TokenScope,
  type UrlSummaryLength,
  type Workspace,
  type WorkspaceCopyContent,
} from "@/lib/models";
import { generalCollection } from "@/lib/models/workspace";
import type { JsonObject } from "@/lib/util/json";

// In-memory Api for tests: mirrors the server closely enough to exercise the
// stores (patch merging, label sets, item reminder pruning, conflict checks),
// with failure injection for offline/retry paths. Ported from
// `app/test/fake_api.dart`.

/** A promise a test resolves to let a gated call continue. */
export class Gate {
  readonly promise: Promise<void>;
  open!: () => void;
  constructor() {
    this.promise = new Promise((resolve) => {
      this.open = resolve;
    });
  }
}

const notFound = (): ApiError => new ApiError(404, '{"error":"not found"}');

export class FakeApi implements Api {
  baseUrl: string;
  token: string | null = null;
  onUnauthorized: (() => void) | null = null;

  readonly notes = new Map<string, Note>();
  readonly labels = new Map<string, Label>();
  readonly stages = new Map<string, Stage>();
  /** Seeded with the default workspace every account has. */
  readonly workspaces = new Map<string, Workspace>([
    [
      "w-default",
      makeWorkspace({
        id: "w-default",
        name: "My notes",
        collections: [{ ...generalCollection("w-default") }],
        owner: { id: "u-me", name: "Me Example" },
        isDefault: true,
      }),
    ],
  ]);
  /** Edit history per note id, newest first. */
  readonly versions = new Map<string, NoteVersion[]>();
  history: Record<string, string[]> = {};
  settings: JsonObject = {};
  capabilities: Capabilities = { semanticSearch: true, audioTranscription: false, imageOcr: false, passwordReset: false, serverVersion: "test-server" };
  managedSettings: Record<string, ManagedSetting> = {};
  previews = new Map<string, LinkPreview>();
  urlSummaries = new Map<string, string>();
  readonly shareLinks = new Map<string, ShareLink>();
  readonly publicShares = new Map<string, PublicShare>();
  readonly apiTokens = new Map<string, ApiToken>();
  resetTokens = new Map<string, string>();
  readonly passwordResetRequests: string[] = [];
  passwordResetError: Error | null = null;
  semanticIds: string[] | null = null;
  readonly semanticQueries: string[] = [];
  reindexStatus: ReindexStatus = { running: false, done: 0, total: 0 };
  llmTestOk = true;
  notifyTestOk = true;
  lastNotifyTestConfig: Record<string, string> | null = null;
  chatScript: ChatEvent[] = [{ type: "sources", notes: [] }, { type: "delta", text: "Hello " }, { type: "delta", text: "there." }, { type: "done" }];
  lastChatHistory: readonly ChatMessage[] | null = null;
  lastChatWorkspaceId: string | null = null;

  /** When set, every call rejects with it (network-down simulation). */
  failWith: Error | null = null;
  /** Every API call, in order. */
  readonly log: string[] = [];

  fetchWorkspacesGate: Gate | null = null;
  fetchLabelsGate: Gate | null = null;
  fetchHistoryGate: Gate | null = null;
  patchGate: Gate | null = null;
  rewriteGate: Gate | null = null;

  account: AuthUser = { id: "u-me", name: "Me Example", email: "me@example.test" };

  private readonly listeners = new Set<() => void>();
  private shareTokenCount = 0;
  private apiTokenCount = 0;

  constructor(baseUrl = "http://fake.test") {
    this.baseUrl = baseUrl;
  }

  pushChangeEvent(): void {
    for (const listener of this.listeners) {
      listener();
    }
  }

  get defaultWorkspaceId(): string {
    return [...this.workspaces.values()].find((w) => w.isDefault)?.id ?? "";
  }

  private workspaceOf(note: Note): string {
    return note.workspaceId === "" ? this.defaultWorkspaceId : note.workspaceId;
  }

  private async run<T>(op: string, body: () => T): Promise<T> {
    this.log.push(op);
    if (this.failWith) {
      throw this.failWith;
    }
    return body();
  }

  private static async pass(gate: Gate | null): Promise<void> {
    if (gate) {
      await gate.promise;
    }
  }

  checkConnection(): Promise<void> {
    return this.run("checkConnection", () => undefined);
  }

  // -- auth -------------------------------------------------------------------

  register(name: string, email: string): Promise<AuthResult> {
    return this.run("register", () => ({ token: `t-${email}`, user: { id: `u-${email}`, name, email } }));
  }

  login(email: string): Promise<AuthResult> {
    return this.run("login", () => ({ token: `t-${email}`, user: { id: `u-${email}`, name: email, email } }));
  }

  logout(): Promise<void> {
    return this.run("logout", () => undefined);
  }

  requestPasswordReset(email: string): Promise<void> {
    return this.run("requestPasswordReset", () => {
      if (this.passwordResetError) {
        throw this.passwordResetError;
      }
      this.passwordResetRequests.push(email);
    });
  }

  resetPassword(token: string): Promise<string> {
    return this.run("resetPassword", () => {
      if (this.passwordResetError) {
        throw this.passwordResetError;
      }
      const email = this.resetTokens.get(token);
      if (email === undefined) {
        throw new ApiError(403, '{"error":"this reset link has expired or was already used"}');
      }
      this.resetTokens.delete(token);
      return email;
    });
  }

  me(): Promise<AuthUser> {
    return this.run("me", () => this.account);
  }

  deleteAccount(): Promise<void> {
    return this.run("deleteAccount", () => {
      this.notes.clear();
      this.labels.clear();
      this.stages.clear();
      this.workspaces.clear();
    });
  }

  updateAccount(update: AccountUpdate): Promise<AuthUser> {
    return this.run("updateAccount", () => {
      this.account = { id: this.account.id, name: update.name ?? this.account.name, email: update.email ?? this.account.email };
      return this.account;
    });
  }

  // -- workspaces -------------------------------------------------------------

  async fetchWorkspaces(): Promise<Workspace[]> {
    const gate = this.fetchWorkspacesGate;
    this.fetchWorkspacesGate = null;
    await FakeApi.pass(gate);
    return this.run("fetchWorkspaces", () =>
      [...this.workspaces.values()].sort((a, b) => (a.isDefault !== b.isDefault ? (a.isDefault ? -1 : 1) : a.name.localeCompare(b.name))),
    );
  }

  createWorkspace(id: string, name: string): Promise<Workspace> {
    return this.run(`createWorkspace:${name}`, () => {
      const workspace = makeWorkspace({ id, name, collections: [generalCollection(id)], owner: { id: this.account.id, name: this.account.name } });
      this.workspaces.set(id, workspace);
      return workspace;
    });
  }

  private updateWorkspace(id: string, update: (w: Workspace) => Workspace): Workspace {
    const existing = this.workspaces.get(id);
    if (!existing) {
      throw notFound();
    }
    const next = update(existing);
    this.workspaces.set(id, next);
    return next;
  }

  renameWorkspace(id: string, name: string): Promise<Workspace> {
    return this.run(`renameWorkspace:${id}`, () => this.updateWorkspace(id, (w) => ({ ...w, name })));
  }

  updateWorkspaceViews(id: string, views: { notesEnabled: boolean; boardEnabled: boolean }): Promise<Workspace> {
    return this.run(`updateWorkspaceViews:${id}:${views.notesEnabled}:${views.boardEnabled}`, () => {
      if (!views.notesEnabled && !views.boardEnabled) {
        throw new ApiError(400, '{"error":"at least one workspace view must remain enabled"}');
      }
      return this.updateWorkspace(id, (w) => ({ ...w, ...views }));
    });
  }

  updateWorkspaceAi(id: string, switches: AiSwitches): Promise<Workspace> {
    return this.run(`updateWorkspaceAi:${id}`, () => this.updateWorkspace(id, (w) => ({ ...w, ai: { ...w.ai, switches } })));
  }

  duplicateWorkspace(id: string, name: string, content: WorkspaceCopyContent, options?: { reminders?: boolean }): Promise<Workspace> {
    return this.run(`duplicateWorkspace:${id}`, () => {
      const source = this.workspaces.get(id);
      if (!source) {
        throw notFound();
      }
      const targetId = `copy-${this.workspaces.size}`;
      const target = makeWorkspace({
        id: targetId,
        name,
        owner: { id: this.account.id, name: this.account.name },
        savedViews: source.savedViews.map((v) => ({ ...v, id: `${targetId}-${v.id}` })),
        collections: source.collections.map((c) => ({ ...c, id: `${targetId}-${c.id}`, workspaceId: targetId })),
      });
      const labelMap = new Map<string, string>();
      for (const label of [...this.labels.values()].filter((l) => l.workspaceId === id)) {
        const newId = `${targetId}-${label.id}`;
        labelMap.set(label.id, newId);
        this.labels.set(newId, { ...label, id: newId, workspaceId: targetId });
      }
      for (const stage of [...this.stages.values()].filter((s) => s.workspaceId === id)) {
        const newId = `${targetId}-${stage.id}`;
        this.stages.set(newId, { ...stage, id: newId, workspaceId: targetId, collectionId: `${targetId}-${stage.collectionId ?? `${id}-general`}` });
      }
      if (content === "notes") {
        for (const n of [...this.notes.values()].filter((n) => this.workspaceOf(n) === id && !n.trashed)) {
          const newId = `${targetId}-${n.id}`;
          this.notes.set(newId, {
            ...n,
            id: newId,
            workspaceId: targetId,
            collectionId: `${targetId}-${n.collectionId ?? `${id}-general`}`,
            stageId: n.stageId === null ? null : `${targetId}-${n.stageId}`,
            labelIds: n.labelIds.map((l) => labelMap.get(l)).filter((l): l is string => l !== undefined),
            owner: { id: this.account.id, name: this.account.name },
            collaborators: [],
            ...(options?.reminders ? {} : { reminderAt: null, reminderRepeat: null, itemReminders: {} }),
            attachments: n.attachments.map((a) => ({ ...a, id: `${targetId}-${a.id}`, url: null })),
          });
        }
      }
      this.workspaces.set(targetId, target);
      return target;
    });
  }

  putCollection(c: NoteCollection): Promise<void> {
    return this.run(`putCollection:${c.id}`, () => {
      this.updateWorkspace(c.workspaceId, (w) => ({ ...w, collections: [...w.collections.filter((v) => v.id !== c.id), c] }));
    });
  }

  deleteCollection(workspaceId: string, id: string): Promise<void> {
    return this.run(`deleteCollection:${id}`, () => {
      this.updateWorkspace(workspaceId, (w) => ({ ...w, collections: w.collections.filter((c) => c.id !== id) }));
      for (const [key, stage] of [...this.stages]) {
        if (stage.collectionId === id) {
          this.stages.delete(key);
        }
      }
      for (const n of [...this.notes.values()]) {
        if (n.collectionId === id) {
          this.notes.set(n.id, { ...n, trashed: true, stageId: null });
        }
      }
    });
  }

  putSavedView(workspaceId: string, view: SavedView): Promise<void> {
    return this.run(`putSavedView:${workspaceId}:${view.id}`, () => {
      this.updateWorkspace(workspaceId, (w) => ({
        ...w,
        savedViews: [...w.savedViews.filter((v) => v.id !== view.id), view].sort((a, b) => a.position - b.position),
      }));
    });
  }

  deleteSavedView(workspaceId: string, id: string): Promise<void> {
    return this.run(`deleteSavedView:${workspaceId}:${id}`, () => {
      this.updateWorkspace(workspaceId, (w) => ({ ...w, savedViews: w.savedViews.filter((v) => v.id !== id) }));
    });
  }

  deleteWorkspace(id: string): Promise<void> {
    return this.run(`deleteWorkspace:${id}`, () => {
      if (!this.workspaces.delete(id)) {
        throw notFound();
      }
      for (const [key, n] of [...this.notes]) {
        if (n.workspaceId === id) {
          this.notes.delete(key);
        }
      }
      for (const [key, l] of [...this.labels]) {
        if (l.workspaceId === id) {
          this.labels.delete(key);
        }
      }
      for (const [key, s] of [...this.stages]) {
        if (s.workspaceId === id) {
          this.stages.delete(key);
        }
      }
    });
  }

  addWorkspaceMember(workspaceId: string, email: string): Promise<Workspace> {
    return this.run(`addWorkspaceMember:${workspaceId}:${email}`, () => {
      if (!email.includes("@")) {
        throw new ApiError(400, `{"error":"no account for '${email}'"}`);
      }
      return this.updateWorkspace(workspaceId, (w) => ({ ...w, members: [...w.members, { id: `u-${email}`, name: email.split("@")[0] ?? email }] }));
    });
  }

  removeWorkspaceMember(workspaceId: string, userId: string): Promise<void> {
    return this.run(`removeWorkspaceMember:${workspaceId}:${userId}`, () => {
      this.updateWorkspace(workspaceId, (w) => ({ ...w, members: w.members.filter((m) => m.id !== userId) }));
    });
  }

  // -- notes ------------------------------------------------------------------

  fetchNotes(): Promise<Note[]> {
    return this.run("fetchNotes", () => [...this.notes.values()].sort((a, b) => a.position - b.position));
  }

  createNote(note: Note): Promise<Note> {
    return this.run(`createNote:${note.id}`, () => {
      if (this.notes.has(note.id)) {
        throw new ApiError(409, '{"error":"note id already exists"}');
      }
      const stored = note.workspaceId === "" ? { ...note, workspaceId: this.defaultWorkspaceId } : note;
      this.notes.set(note.id, stored);
      return stored;
    });
  }

  async patchNote(id: string, fields: JsonObject): Promise<Note> {
    const gate = this.patchGate;
    this.patchGate = null;
    await FakeApi.pass(gate);
    return this.run(`patchNote:${id}:${Object.keys(fields).join(",")}`, () => {
      const existing = this.notes.get(id);
      if (!existing) {
        throw notFound();
      }
      const expected = fields.if_unmodified_since;
      if (typeof expected === "string" && existing.updatedAt.getTime() !== new Date(expected).getTime()) {
        throw new ApiError(409, '{"error":"note changed elsewhere"}');
      }
      const has = (key: string): boolean => key in fields;
      let next: Note = {
        ...existing,
        kind: has("kind") ? noteKindFromWire(fields.kind) : existing.kind,
        title: typeof fields.title === "string" ? fields.title : existing.title,
        content: typeof fields.content === "string" ? fields.content : existing.content,
        items: has("items") && Array.isArray(fields.items) ? fields.items.map(parseChecklistItem) : existing.items,
        workspaceId: typeof fields.workspace_id === "string" ? fields.workspace_id : existing.workspaceId,
        gridSpan: typeof fields.grid_span === "number" ? fields.grid_span : existing.gridSpan,
        collectionId: typeof fields.collection_id === "string" ? fields.collection_id : existing.collectionId,
        color: typeof fields.color === "string" ? fields.color : existing.color,
        pattern: has("pattern") ? notePatternFromWire(fields.pattern) : existing.pattern,
        pinned: typeof fields.pinned === "boolean" ? fields.pinned : existing.pinned,
        archived: typeof fields.archived === "boolean" ? fields.archived : existing.archived,
        trashed: typeof fields.trashed === "boolean" ? fields.trashed : existing.trashed,
        position: typeof fields.position === "number" ? fields.position : existing.position,
        reminderAt: has("reminder_at") ? (typeof fields.reminder_at === "string" ? new Date(fields.reminder_at) : null) : existing.reminderAt,
        reminderRepeat: has("reminder_repeat") ? reminderRepeatFromWire(fields.reminder_repeat) : existing.reminderRepeat,
        labelIds: has("label_ids") && Array.isArray(fields.label_ids) ? [...new Set(fields.label_ids.map(String))] : existing.labelIds,
        // Present-but-null means unassigned; an unknown stage is dropped.
        stageId: has("stage_id") ? (typeof fields.stage_id === "string" && this.stages.has(fields.stage_id) ? fields.stage_id : null) : existing.stageId,
        stagePosition: typeof fields.stage_position === "number" ? fields.stage_position : existing.stagePosition,
        updatedAt: new Date(Math.max(Date.now(), existing.updatedAt.getTime() + 1)),
      };
      // The server prunes item reminders in the same write.
      next = { ...next, itemReminders: FakeApi.pruneItemReminders(next) };
      this.notes.set(id, next);
      return next;
    });
  }

  private static pruneItemReminders(note: Note): Record<string, ItemReminder> {
    const out: Record<string, ItemReminder> = {};
    for (const item of note.items) {
      const reminder = note.itemReminders[item.id];
      if (!item.done && reminder) {
        out[item.id] = reminder;
      }
    }
    return out;
  }

  setItemReminder(noteId: string, itemId: string, at: Date | null, repeat?: ReminderRepeat | null): Promise<void> {
    return this.run(`setItemReminder:${noteId}:${itemId}`, () => {
      const existing = this.notes.get(noteId);
      if (!existing) {
        throw notFound();
      }
      const reminders = { ...existing.itemReminders };
      if (at === null) {
        delete reminders[itemId];
      } else {
        const item = existing.items.find((i) => i.id === itemId);
        if (!item) {
          throw notFound();
        }
        if (item.done) {
          throw new ApiError(400, '{"error":"a checked item cannot carry a reminder"}');
        }
        reminders[itemId] = { itemId, at, repeat: repeat ?? null };
      }
      this.notes.set(noteId, { ...existing, itemReminders: reminders });
    });
  }

  async rewriteNote(id: string, task: NoteRewriteTask): Promise<Note> {
    await FakeApi.pass(this.rewriteGate);
    return this.run(`rewriteNote:${id}:${task.id}`, () => {
      const note = this.notes.get(id);
      if (!note) {
        throw notFound();
      }
      const updated = { ...note, content: `${task.name}: ${note.content}`, updatedAt: new Date() };
      this.notes.set(id, updated);
      this.pushChangeEvent();
      return updated;
    });
  }

  deleteNote(id: string): Promise<void> {
    return this.run(`deleteNote:${id}`, () => {
      if (!this.notes.delete(id)) {
        throw notFound();
      }
    });
  }

  reorderNotes(ids: readonly string[]): Promise<void> {
    return this.run(`reorder:${ids.join("|")}`, () => {
      ids.forEach((id, i) => {
        const note = this.notes.get(id);
        if (note) {
          this.notes.set(id, { ...note, position: (i + 1) * 1024 });
        }
      });
    });
  }

  fetchNoteVersions(noteId: string): Promise<NoteVersion[]> {
    return this.run(`fetchVersions:${noteId}`, () => [...(this.versions.get(noteId) ?? [])]);
  }

  restoreNoteVersion(noteId: string, versionId: string): Promise<Note> {
    return this.run(`restoreVersion:${noteId}:${versionId}`, () => {
      const note = this.notes.get(noteId);
      if (!note) {
        throw notFound();
      }
      const list = this.versions.get(noteId) ?? [];
      const v = list.find((e) => e.id === versionId);
      if (!v) {
        throw notFound();
      }
      // Checkpoint the current state, then roll content back, as the server does.
      this.versions.set(noteId, [
        { id: `chk-${list.length}`, noteId, kind: note.kind, title: note.title, content: note.content, items: note.items, editedBy: null, createdAt: new Date() },
        ...list,
      ]);
      const restored = { ...note, kind: v.kind, title: v.title, content: v.content, items: v.items, updatedAt: new Date() };
      this.notes.set(noteId, restored);
      return restored;
    });
  }

  async fetchChecklistHistory(): Promise<Record<string, string[]>> {
    const result = await this.run("fetchHistory", () => Object.fromEntries(Object.entries(this.history).map(([k, v]) => [k, [...v]])));
    await FakeApi.pass(this.fetchHistoryGate);
    return result;
  }

  // -- public share links -----------------------------------------------------

  fetchShareLinks(): Promise<ShareLink[]> {
    return this.run("fetchShareLinks", () => [...this.shareLinks.values()]);
  }

  createShareLink(request: ShareLinkRequest): Promise<ShareLink> {
    return this.run("createShareLink", () => {
      for (const link of this.shareLinks.values()) {
        if (
          link.target === request.target &&
          link.noteId === (request.noteId ?? null) &&
          link.workspaceId === (request.workspaceId ?? null) &&
          link.collectionId === (request.collectionId ?? null) &&
          link.labelId === (request.labelId ?? null)
        ) {
          return link;
        }
      }
      const link: ShareLink = {
        token: `tok-${this.shareTokenCount++}`,
        target: request.target,
        noteId: request.noteId ?? null,
        workspaceId: request.workspaceId ?? null,
        collectionId: request.collectionId ?? null,
        labelId: request.labelId ?? null,
        title: request.noteId ? (this.notes.get(request.noteId)?.title ?? "") : "Shared view",
        createdAt: new Date(2026, 0, 1),
        expiresAt: request.expiresAt ?? null,
      };
      this.shareLinks.set(link.token, link);
      return link;
    });
  }

  deleteShareLink(token: string): Promise<void> {
    return this.run("deleteShareLink", () => {
      this.shareLinks.delete(token);
    });
  }

  fetchApiTokens(): Promise<ApiToken[]> {
    return this.run("fetchApiTokens", () => [...this.apiTokens.values()]);
  }

  createApiToken(name: string, scope: TokenScope): Promise<CreatedApiToken> {
    return this.run("createApiToken", () => {
      const id = `api-${this.apiTokenCount++}`;
      const token: ApiToken = { id, name, scope, createdAt: new Date(2026, 0, 1), lastUsedAt: null };
      this.apiTokens.set(id, token);
      return { token, secret: `skp_secret_${id}` };
    });
  }

  deleteApiToken(id: string): Promise<void> {
    return this.run("deleteApiToken", () => {
      this.apiTokens.delete(id);
    });
  }

  fetchPublicShare(token: string): Promise<PublicShare> {
    return this.run("fetchPublicShare", () => {
      const share = this.publicShares.get(token);
      if (!share) {
        throw notFound();
      }
      return share;
    });
  }

  // -- labels and stages --------------------------------------------------------

  async fetchLabels(): Promise<Label[]> {
    const result = await this.run("fetchLabels", () =>
      [...this.labels.values()].sort((a, b) => a.position - b.position || a.name.toLowerCase().localeCompare(b.name.toLowerCase())),
    );
    const gate = this.fetchLabelsGate;
    this.fetchLabelsGate = null;
    await FakeApi.pass(gate);
    return result;
  }

  private nextPosition(items: Iterable<{ workspaceId: string; position: number }>, workspaceId: string): number {
    let max = 0;
    for (const item of items) {
      if (item.workspaceId === workspaceId && item.position > max) {
        max = item.position;
      }
    }
    return max + 1024;
  }

  createLabel(id: string, name: string, options: { workspaceId: string; color?: string | null; icon?: string | null; position?: number | null }): Promise<void> {
    return this.run(`createLabel:${name}`, () => {
      this.labels.set(id, {
        id,
        workspaceId: options.workspaceId,
        name,
        color: options.color || null,
        icon: options.icon || null,
        position: options.position ?? this.nextPosition(this.labels.values(), options.workspaceId),
      });
    });
  }

  updateLabel(id: string, name: string, options?: { color?: string | null; icon?: string | null; position?: number | null }): Promise<void> {
    return this.run(`updateLabel:${id}`, () => {
      const existing = this.labels.get(id);
      this.labels.set(id, {
        id,
        workspaceId: existing?.workspaceId ?? "",
        name,
        color: options?.color || null,
        icon: options?.icon || null,
        position: options?.position ?? existing?.position ?? 0,
      });
    });
  }

  deleteLabel(id: string): Promise<void> {
    return this.run(`deleteLabel:${id}`, () => {
      this.labels.delete(id);
    });
  }

  fetchStages(): Promise<Stage[]> {
    return this.run("fetchStages", () => [...this.stages.values()].sort((a, b) => a.position - b.position));
  }

  createStage(id: string, name: string, options: { workspaceId: string; collectionId?: string | null; color?: string | null; position?: number | null }): Promise<void> {
    return this.run(`createStage:${name}`, () => {
      this.stages.set(id, {
        id,
        workspaceId: options.workspaceId,
        collectionId: options.collectionId ?? null,
        name,
        color: options.color || null,
        position: options.position ?? this.nextPosition(this.stages.values(), options.workspaceId),
      });
    });
  }

  updateStage(id: string, name: string, options?: { color?: string | null; position?: number | null }): Promise<void> {
    return this.run(`updateStage:${id}`, () => {
      const existing = this.stages.get(id);
      this.stages.set(id, {
        id,
        workspaceId: existing?.workspaceId ?? "",
        collectionId: existing?.collectionId ?? null,
        name,
        color: options?.color || null,
        position: options?.position ?? existing?.position ?? 0,
      });
    });
  }

  deleteStage(id: string): Promise<void> {
    return this.run(`deleteStage:${id}`, () => {
      this.stages.delete(id);
      // Notes outlive their column, as on the server.
      for (const [key, note] of [...this.notes]) {
        if (note.stageId === id) {
          this.notes.set(key, { ...note, stageId: null });
        }
      }
    });
  }

  // -- sharing and attachments ----------------------------------------------------

  addCollaborator(noteId: string, email: string): Promise<Note> {
    return this.run(`addCollaborator:${noteId}:${email}`, () => {
      const note = this.notes.get(noteId);
      if (!note) {
        throw notFound();
      }
      if (email === "nobody@example.test") {
        throw new ApiError(400, '{"error":"no account for email"}');
      }
      const updated = { ...note, collaborators: [...note.collaborators, { id: `u-${email}`, name: email.split("@")[0] ?? email }] };
      this.notes.set(noteId, updated);
      return updated;
    });
  }

  removeCollaborator(noteId: string, userId: string): Promise<void> {
    return this.run(`removeCollaborator:${noteId}:${userId}`, () => {
      const note = this.notes.get(noteId);
      if (!note) {
        throw notFound();
      }
      this.notes.set(noteId, { ...note, collaborators: note.collaborators.filter((c) => c.id !== userId) });
    });
  }

  uploadAttachment(noteId: string, body: UploadBody, mime: string, filename: string): Promise<Attachment> {
    return this.run(`upload:${noteId}:${filename}`, () => {
      const note = this.notes.get(noteId);
      if (!note) {
        throw notFound();
      }
      const size = body instanceof Blob ? body.size : body.length;
      const attachment: Attachment = { id: `att-${size}`, mime, filename, size, url: null, ocrText: "" };
      this.notes.set(noteId, { ...note, attachments: [...note.attachments, attachment] });
      return attachment;
    });
  }

  deleteAttachment(attachmentId: string): Promise<void> {
    return this.run(`deleteAttachment:${attachmentId}`, () => undefined);
  }

  fileUrl(attachmentId: string): string {
    return `http://fake.test/files/${attachmentId}`;
  }

  attachmentUrl(attachment: Attachment): string {
    return attachment.url ? `http://fake.test${attachment.url}` : this.fileUrl(attachment.id);
  }

  // -- settings, search, capabilities ----------------------------------------------

  fetchSettings(): Promise<JsonObject> {
    return this.run("fetchSettings", () => ({ ...this.settings }));
  }

  putSettings(settings: JsonObject): Promise<void> {
    return this.run("putSettings", () => {
      this.settings = { ...settings };
    });
  }

  /** Keyword containment ranked by match count, unless [semanticIds] is set. */
  semanticSearch(query: string, options?: { limit?: number; workspaceId?: string | null }): Promise<string[]> {
    return this.run(`semanticSearch:${query}`, () => {
      this.semanticQueries.push(query);
      if (this.semanticIds) {
        return this.semanticIds;
      }
      const terms = query.toLowerCase().split(/\s+/);
      const scored: [string, number][] = [];
      for (const note of this.notes.values()) {
        if (options?.workspaceId && this.workspaceOf(note) !== options.workspaceId) {
          continue;
        }
        const text = `${note.title} ${note.content} ${note.items.map((i) => i.text).join(" ")}`.toLowerCase();
        const score = terms.filter((t) => text.includes(t)).length;
        if (score > 0) {
          scored.push([note.id, score]);
        }
      }
      scored.sort((a, b) => b[1] - a[1]);
      return scored.slice(0, options?.limit ?? 20).map(([id]) => id);
    });
  }

  fetchCapabilities(): Promise<Capabilities> {
    return this.run("fetchCapabilities", () => this.capabilities);
  }

  fetchSearchStats(): Promise<SearchStats> {
    return this.run("fetchSearchStats", () =>
      this.capabilities.semanticSearch
        ? { enabled: true, model: "fake-embedder", dimensions: 8, totalNotes: this.notes.size, indexedNotes: this.notes.size }
        : { enabled: false, model: "", dimensions: 0, totalNotes: 0, indexedNotes: 0 },
    );
  }

  reindexEmbeddings(): Promise<number> {
    return this.run("reindexEmbeddings", () => this.notes.size);
  }

  fetchReindexStatus(): Promise<ReindexStatus> {
    return this.run("fetchReindexStatus", () => this.reindexStatus);
  }

  fetchManagedSettings(): Promise<Record<string, ManagedSetting>> {
    return this.run("fetchManagedSettings", () => this.managedSettings);
  }

  transcribeNote(noteId: string): Promise<void> {
    return this.run(`transcribe:${noteId}`, () => {
      if (!this.notes.has(noteId)) {
        throw notFound();
      }
    });
  }

  unfurl(url: string): Promise<LinkPreview | null> {
    return this.run(`unfurl:${url}`, () => this.previews.get(url) ?? null);
  }

  summarizeUrl(url: string, options: { noteId: string; length?: UrlSummaryLength; signal?: AbortSignal }): Promise<string> {
    void options;
    return this.run(`summarizeUrl:${url}`, () => {
      const summary = this.urlSummaries.get(url);
      if (summary === undefined) {
        throw new ApiError(400, "summary unavailable");
      }
      return summary;
    });
  }

  cancelLinkSummaries(noteId: string): Promise<void> {
    return this.run(`cancelLinkSummaries:${noteId}`, () => {
      const note = this.notes.get(noteId);
      if (note) {
        this.notes.set(noteId, { ...note, summarizingLinks: false });
      }
    });
  }

  changeEvents(listener: () => void): Unsubscribe {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  testLlm(): Promise<ProbeResult> {
    return this.run("testLlm", () => ({ ok: this.llmTestOk, error: this.llmTestOk ? null : "connection refused" }));
  }

  testNotify(config: Readonly<Record<string, string>>): Promise<ProbeResult> {
    return this.run("testNotify", () => {
      this.lastNotifyTestConfig = { ...config };
      return { ok: this.notifyTestOk, error: this.notifyTestOk ? null : "ntfy: boom" };
    });
  }

  chat(message: string, history: readonly ChatMessage[], options?: { workspaceId?: string | null }): ChatStream {
    this.log.push(`chat:${message}`);
    this.lastChatHistory = history;
    this.lastChatWorkspaceId = options?.workspaceId ?? null;
    const fail = this.failWith;
    const script = [...this.chatScript];
    let cancelled = false;
    return {
      cancel: () => {
        cancelled = true;
      },
      async *[Symbol.asyncIterator]() {
        if (fail) {
          yield { type: "error", message: fail.message } as ChatEvent;
          return;
        }
        for (const event of script) {
          if (cancelled) {
            return;
          }
          yield event;
        }
      },
    };
  }

  // -- fixtures -----------------------------------------------------------------

  /** Store a note as the server would hold it. */
  seedNote(fields: Partial<Note> & { id: string }): Note {
    const note = makeNote({ workspaceId: this.defaultWorkspaceId, owner: { id: "u-me", name: "me" }, ...fields });
    this.notes.set(note.id, note);
    return note;
  }
}

