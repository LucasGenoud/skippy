import {
  aiSwitchesToJson,
  collectionToJson,
  itemRemindersToJson,
  itemsToJson,
  parseApiToken,
  parseAttachment,
  parseAuthUser,
  parseCreatedApiToken,
  parseLabel,
  parseLinkPreview,
  parseManagedSetting,
  parseNote,
  parseNoteVersion,
  parsePublicShare,
  parseSearchStats,
  parseShareLink,
  parseStage,
  parseWorkspace,
  savedViewToJson,
  type AiSwitches,
  type ApiToken,
  type Attachment,
  type AuthUser,
  type Capabilities,
  type ChatMessage,
  type CreatedApiToken,
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
import { asArray, asObject, num, str, type JsonObject } from "@/lib/util/json";
import { TimeoutError } from "@/lib/util/network-error";
import type { AccountUpdate, Api, AuthResult, ChatStream, ProbeResult, ShareLinkRequest, Unsubscribe, UploadBody } from "./client";
import { AbortedError, ApiError, NetworkError } from "./errors";
import { connectChangeEvents, defaultWebSocketFactory, openChatStream, type WebSocketFactory } from "./sockets";

// The fetch/WebSocket implementation of `Api`. Ported from `ApiClient` and its
// `_ApiTransport` in `app/lib/api/`.

/** Ceiling on any ordinary request. */
const REQUEST_TIMEOUT_MS = 15_000;
/** Ceiling on a request a model answers (the server gives up on a rewrite at 50s). */
const AI_REQUEST_TIMEOUT_MS = 90_000;
/** Ceiling on the reachability probe. */
const PROBE_TIMEOUT_MS = 3_000;
const HTTP_UNAUTHORIZED = 401;
const DEFAULT_SEARCH_LIMIT = 20;

type Method = "GET" | "POST" | "PUT" | "PATCH" | "DELETE";

/**
 * How a request authenticates: `session` sends the token and lets a 401 end
 * the session; `revoking` sends it without that (logout); `anonymous` sends none.
 */
type Auth = "session" | "revoking" | "anonymous";

/** Which timeout bounds a request. */
type Deadline = "standard" | "ai" | "probe" | "none";

interface RequestOptions {
  readonly body?: unknown;
  readonly auth?: Auth;
  readonly deadline?: Deadline;
  readonly signal?: AbortSignal;
  readonly query?: Record<string, string>;
  readonly form?: FormData;
}

const DEADLINES: Record<Deadline, number | null> = {
  standard: REQUEST_TIMEOUT_MS,
  ai: AI_REQUEST_TIMEOUT_MS,
  probe: PROBE_TIMEOUT_MS,
  none: null,
};

export interface HttpApiOptions {
  readonly baseUrl: string;
  readonly fetch?: typeof fetch;
  readonly webSocketFactory?: WebSocketFactory;
}

export class HttpApi implements Api {
  baseUrl: string;
  /** Session token; set by the auth store after sign-in. */
  token: string | null = null;
  /** Called when the current server rejects the active session. */
  onUnauthorized: (() => void) | null = null;

  private readonly fetchImpl: typeof fetch;
  private readonly webSocketFactory: WebSocketFactory;

  constructor(options: HttpApiOptions) {
    this.baseUrl = options.baseUrl;
    this.fetchImpl = options.fetch ?? ((input, init) => globalThis.fetch(input, init));
    this.webSocketFactory = options.webSocketFactory ?? defaultWebSocketFactory;
  }

  // -- transport --------------------------------------------------------------

  private url(path: string, query?: Record<string, string>): string {
    const base = `${this.baseUrl}/api${path}`;
    if (!query) {
      return base;
    }
    const params = new URLSearchParams(query).toString();
    return params ? `${base}?${params}` : base;
  }

  private webSocketUrl(path: string): string {
    const http = new URL(this.url(path), typeof window === "undefined" ? undefined : window.location.href);
    if (http.protocol !== "https:" && http.protocol !== "http:") {
      throw new Error("backend URL must use http or https");
    }
    http.protocol = http.protocol === "https:" ? "wss:" : "ws:";
    return http.toString();
  }

  private async request(method: Method, path: string, options: RequestOptions = {}): Promise<unknown> {
    const auth = options.auth ?? "session";
    const sentToken = auth === "anonymous" ? null : this.token;
    const sentBase = this.baseUrl;
    const headers: Record<string, string> = {};
    let body: BodyInit | undefined;
    if (options.form) {
      body = options.form;
    } else if (options.body !== undefined) {
      headers["content-type"] = "application/json";
      body = JSON.stringify(options.body);
    }
    if (sentToken !== null) {
      headers.authorization = `Bearer ${sentToken}`;
    }

    const controller = new AbortController();
    const limit = DEADLINES[options.deadline ?? "standard"];
    let timedOut = false;
    const timer =
      limit === null
        ? null
        : setTimeout(() => {
            timedOut = true;
            controller.abort();
          }, limit);
    const onCallerAbort = (): void => controller.abort();
    options.signal?.addEventListener("abort", onCallerAbort);

    let response: Response;
    let text: string;
    try {
      if (options.signal?.aborted) {
        throw new AbortedError();
      }
      response = await this.fetchImpl(this.url(path, options.query), { method, headers, body, signal: controller.signal });
      text = await response.text();
    } catch (error) {
      if (error instanceof AbortedError) {
        throw error;
      }
      if (timedOut) {
        throw new NetworkError(new TimeoutError(), sentBase);
      }
      if (options.signal?.aborted) {
        throw new AbortedError();
      }
      throw new NetworkError(error, sentBase);
    } finally {
      if (timer !== null) {
        clearTimeout(timer);
      }
      options.signal?.removeEventListener("abort", onCallerAbort);
    }

    // A 401 ends the session only when it answers the token and server in use.
    if (response.status === HTTP_UNAUTHORIZED && auth === "session" && sentToken !== null && sentToken === this.token && sentBase === this.baseUrl) {
      this.onUnauthorized?.();
    }
    if (response.status < 200 || response.status >= 300) {
      throw new ApiError(response.status, text);
    }
    if (!text) {
      return null;
    }
    try {
      return JSON.parse(text) as unknown;
    } catch {
      throw new ApiError(response.status, text);
    }
  }

  private get(path: string, options?: RequestOptions): Promise<unknown> {
    return this.request("GET", path, options);
  }

  private post(path: string, body?: unknown, options?: RequestOptions): Promise<unknown> {
    return this.request("POST", path, { ...options, body });
  }

  private put(path: string, body?: unknown): Promise<unknown> {
    return this.request("PUT", path, { body });
  }

  private patch(path: string, body?: unknown): Promise<unknown> {
    return this.request("PATCH", path, { body });
  }

  private del(path: string, body?: unknown): Promise<unknown> {
    return this.request("DELETE", path, { body });
  }

  async checkConnection(): Promise<void> {
    await this.get("/health", { auth: "anonymous", deadline: "probe" });
  }

  // -- auth -------------------------------------------------------------------

  private async authCall(path: string, body: Record<string, string>): Promise<AuthResult> {
    const data = asObject(await this.post(path, body, { auth: "anonymous" })) ?? {};
    return { token: str(data.token), user: parseAuthUser(data.user) };
  }

  register(name: string, email: string, password: string): Promise<AuthResult> {
    return this.authCall("/auth/register", { name, email, password });
  }

  login(email: string, password: string): Promise<AuthResult> {
    return this.authCall("/auth/login", { email, password });
  }

  async logout(): Promise<void> {
    // Carries the token being revoked; a 401 here must not re-trigger sign-out.
    await this.request("POST", "/auth/logout", { auth: "revoking" });
  }

  async requestPasswordReset(email: string): Promise<void> {
    await this.post("/auth/forgot-password", { email }, { auth: "anonymous" });
  }

  async resetPassword(token: string, password: string): Promise<string> {
    const data = asObject(await this.post("/auth/reset-password", { token, password }, { auth: "anonymous" }));
    return data?.email == null ? "" : String(data.email);
  }

  async me(): Promise<AuthUser> {
    return parseAuthUser(await this.get("/auth/me"));
  }

  async deleteAccount(currentPassword: string): Promise<void> {
    await this.del("/auth/me", { current_password: currentPassword });
  }

  async updateAccount(update: AccountUpdate): Promise<AuthUser> {
    const body: Record<string, string> = {};
    if (update.name !== undefined) {
      body.name = update.name;
    }
    if (update.email !== undefined) {
      body.email = update.email;
    }
    if (update.currentPassword !== undefined) {
      body.current_password = update.currentPassword;
    }
    if (update.newPassword !== undefined) {
      body.new_password = update.newPassword;
    }
    return parseAuthUser(await this.patch("/auth/me", body));
  }

  // -- workspaces -------------------------------------------------------------

  async fetchWorkspaces(): Promise<Workspace[]> {
    return asArray(await this.get("/workspaces")).map(parseWorkspace);
  }

  async createWorkspace(id: string, name: string): Promise<Workspace> {
    return parseWorkspace(await this.post("/workspaces", { id, name }));
  }

  async renameWorkspace(id: string, name: string): Promise<Workspace> {
    return parseWorkspace(await this.patch(`/workspaces/${id}`, { name }));
  }

  async updateWorkspaceViews(id: string, views: { notesEnabled: boolean; boardEnabled: boolean }): Promise<Workspace> {
    return parseWorkspace(await this.patch(`/workspaces/${id}`, { notes_enabled: views.notesEnabled, board_enabled: views.boardEnabled }));
  }

  async updateWorkspaceAi(id: string, switches: AiSwitches): Promise<Workspace> {
    return parseWorkspace(await this.patch(`/workspaces/${id}`, { ai: aiSwitchesToJson(switches) }));
  }

  async duplicateWorkspace(id: string, name: string, content: WorkspaceCopyContent, options?: { reminders?: boolean }): Promise<Workspace> {
    // A full copy can take a while; no ordinary timeout, like the Dart upload client.
    return parseWorkspace(
      await this.request("POST", `/workspaces/${id}/duplicate`, {
        body: { name, content, reminders: options?.reminders ?? false },
        deadline: "none",
      }),
    );
  }

  async putCollection(collection: NoteCollection): Promise<void> {
    await this.put(`/workspaces/${collection.workspaceId}/collections/${collection.id}`, collectionToJson(collection));
  }

  async deleteCollection(workspaceId: string, id: string): Promise<void> {
    await this.del(`/workspaces/${workspaceId}/collections/${id}`);
  }

  async putSavedView(workspaceId: string, view: SavedView): Promise<void> {
    await this.put(`/workspaces/${workspaceId}/smart-views/${view.id}`, savedViewToJson(view));
  }

  async deleteSavedView(workspaceId: string, id: string): Promise<void> {
    await this.del(`/workspaces/${workspaceId}/smart-views/${id}`);
  }

  async deleteWorkspace(id: string): Promise<void> {
    await this.del(`/workspaces/${id}`);
  }

  async addWorkspaceMember(workspaceId: string, email: string): Promise<Workspace> {
    return parseWorkspace(await this.post(`/workspaces/${workspaceId}/members`, { email }));
  }

  async removeWorkspaceMember(workspaceId: string, userId: string): Promise<void> {
    await this.del(`/workspaces/${workspaceId}/members/${userId}`);
  }

  // -- notes ------------------------------------------------------------------

  async fetchNotes(): Promise<Note[]> {
    return asArray(await this.get("/notes")).map(parseNote);
  }

  async createNote(note: Note, options?: { preserveTimestamps?: boolean }): Promise<Note> {
    const body: JsonObject = { id: note.id };
    if (note.workspaceId) {
      body.workspace_id = note.workspaceId;
    }
    Object.assign(body, {
      collection_id: note.collectionId,
      kind: note.kind,
      title: note.title,
      content: note.content,
      items: itemsToJson(note.items),
      color: note.color,
      pattern: note.pattern,
      pinned: note.pinned,
      position: note.position,
      grid_span: note.gridSpan,
    });
    if (note.reminderAt) {
      body.reminder_at = note.reminderAt.toISOString();
    }
    if (note.reminderRepeat) {
      body.reminder_repeat = note.reminderRepeat;
    }
    // A checklist composed offline arrives with its item alarms in the same request.
    if (Object.keys(note.itemReminders).length > 0) {
      body.item_reminders = itemRemindersToJson(note.itemReminders);
    }
    // Filed from birth: a note composed in a label view or board column.
    body.label_ids = [...note.labelIds];
    if (note.stageId !== null) {
      body.stage_id = note.stageId;
    }
    body.stage_position = note.stagePosition;
    if (options?.preserveTimestamps) {
      body.archived = note.archived;
      body.trashed = note.trashed;
      body.created_at = note.createdAt.toISOString();
      body.updated_at = note.updatedAt.toISOString();
    }
    return parseNote(await this.post("/notes", body));
  }

  async patchNote(id: string, fields: JsonObject): Promise<Note> {
    return parseNote(await this.patch(`/notes/${id}`, fields));
  }

  async setItemReminder(noteId: string, itemId: string, at: Date | null, repeat?: ReminderRepeat | null): Promise<void> {
    await this.put(`/notes/${noteId}/item-reminders/${encodeURIComponent(itemId)}`, {
      reminder_at: at?.toISOString() ?? null,
      reminder_repeat: at === null ? null : (repeat ?? null),
    });
  }

  async rewriteNote(id: string, task: NoteRewriteTask, signal?: AbortSignal): Promise<Note> {
    return parseNote(await this.request("POST", `/notes/${id}/rewrite`, { body: { task_id: task.id }, deadline: "ai", signal }));
  }

  async deleteNote(id: string): Promise<void> {
    await this.del(`/notes/${id}`);
  }

  async reorderNotes(ids: readonly string[]): Promise<void> {
    await this.post("/notes/reorder", { ids });
  }

  async fetchNoteVersions(noteId: string): Promise<NoteVersion[]> {
    return asArray(await this.get(`/notes/${noteId}/versions`)).map(parseNoteVersion);
  }

  async restoreNoteVersion(noteId: string, versionId: string): Promise<Note> {
    return parseNote(await this.post(`/notes/${noteId}/versions/${versionId}/restore`));
  }

  async fetchChecklistHistory(): Promise<Record<string, string[]>> {
    const byNote: Record<string, string[]> = {};
    for (const entry of asArray(await this.get("/checklist-history"))) {
      const map = asObject(entry);
      if (!map || typeof map.note_id !== "string" || typeof map.text !== "string") {
        continue;
      }
      (byNote[map.note_id] ??= []).push(map.text);
    }
    return byNote;
  }

  // -- public share links -----------------------------------------------------

  async fetchShareLinks(): Promise<ShareLink[]> {
    return asArray(await this.get("/share-links")).map(parseShareLink);
  }

  async createShareLink(request: ShareLinkRequest): Promise<ShareLink> {
    const body: JsonObject = { target: request.target };
    if (request.noteId) {
      body.note_id = request.noteId;
    }
    if (request.workspaceId) {
      body.workspace_id = request.workspaceId;
    }
    if (request.collectionId) {
      body.collection_id = request.collectionId;
    }
    if (request.labelId) {
      body.label_id = request.labelId;
    }
    if (request.expiresAt) {
      body.expires_at = request.expiresAt.toISOString();
    }
    return parseShareLink(await this.post("/share-links", body));
  }

  async deleteShareLink(token: string): Promise<void> {
    await this.del(`/share-links/${token}`);
  }

  // -- personal access tokens -------------------------------------------------

  async fetchApiTokens(): Promise<ApiToken[]> {
    return asArray(await this.get("/tokens")).map(parseApiToken);
  }

  async createApiToken(name: string, scope: TokenScope): Promise<CreatedApiToken> {
    return parseCreatedApiToken(await this.post("/tokens", { name, scope }));
  }

  async deleteApiToken(id: string): Promise<void> {
    await this.del(`/tokens/${id}`);
  }

  async fetchPublicShare(token: string): Promise<PublicShare> {
    // No Authorization: a reader following the link is usually signed out.
    return parsePublicShare(await this.get(`/public/${token}`, { auth: "anonymous" }));
  }

  // -- labels -----------------------------------------------------------------

  async fetchLabels(): Promise<Label[]> {
    return asArray(await this.get("/labels")).map(parseLabel);
  }

  async createLabel(
    id: string,
    name: string,
    options: { workspaceId: string; color?: string | null; icon?: string | null; position?: number | null },
  ): Promise<void> {
    // Empty strings clear a field server-side; an omitted position appends.
    const body: JsonObject = { id };
    if (options.workspaceId) {
      body.workspace_id = options.workspaceId;
    }
    Object.assign(body, { name, color: options.color ?? "", icon: options.icon ?? "" });
    if (options.position != null) {
      body.position = options.position;
    }
    await this.post("/labels", body);
  }

  async updateLabel(id: string, name: string, options?: { color?: string | null; icon?: string | null; position?: number | null }): Promise<void> {
    const body: JsonObject = { name, color: options?.color ?? "", icon: options?.icon ?? "" };
    if (options?.position != null) {
      body.position = options.position;
    }
    await this.patch(`/labels/${id}`, body);
  }

  async deleteLabel(id: string): Promise<void> {
    await this.del(`/labels/${id}`);
  }

  // -- stages -----------------------------------------------------------------

  async fetchStages(): Promise<Stage[]> {
    return asArray(await this.get("/stages")).map(parseStage);
  }

  async createStage(
    id: string,
    name: string,
    options: { workspaceId: string; collectionId?: string | null; color?: string | null; position?: number | null },
  ): Promise<void> {
    const body: JsonObject = { id };
    if (options.workspaceId) {
      body.workspace_id = options.workspaceId;
    }
    Object.assign(body, { collection_id: options.collectionId ?? null, name, color: options.color ?? "" });
    if (options.position != null) {
      body.position = options.position;
    }
    await this.post("/stages", body);
  }

  async updateStage(id: string, name: string, options?: { color?: string | null; position?: number | null }): Promise<void> {
    const body: JsonObject = { name, color: options?.color ?? "" };
    if (options?.position != null) {
      body.position = options.position;
    }
    await this.patch(`/stages/${id}`, body);
  }

  async deleteStage(id: string): Promise<void> {
    await this.del(`/stages/${id}`);
  }

  // -- sharing ----------------------------------------------------------------

  async addCollaborator(noteId: string, email: string): Promise<Note> {
    return parseNote(await this.post(`/notes/${noteId}/collaborators`, { email }));
  }

  async removeCollaborator(noteId: string, userId: string): Promise<void> {
    await this.del(`/notes/${noteId}/collaborators/${userId}`);
  }

  // -- attachments ------------------------------------------------------------

  async uploadAttachment(noteId: string, body: UploadBody, mime: string, filename: string): Promise<Attachment> {
    const blob = body instanceof Blob ? body : new Blob([body as BlobPart], { type: mime });
    const typed = blob.type === mime ? blob : new Blob([blob], { type: mime });
    const form = new FormData();
    form.append("file", typed, filename || "file");
    // Uploads bypass the ordinary timeout: a large file on a slow link takes time.
    return parseAttachment(await this.request("POST", `/notes/${noteId}/attachments`, { form, deadline: "none" }));
  }

  async deleteAttachment(attachmentId: string): Promise<void> {
    await this.del(`/attachments/${attachmentId}`);
  }

  fileUrl(attachmentId: string): string {
    return `${this.baseUrl}/api/files/${attachmentId}`;
  }

  attachmentUrl(attachment: Attachment): string {
    if (attachment.url) {
      return `${this.baseUrl}${attachment.url}`;
    }
    return this.fileUrl(attachment.id);
  }

  // -- settings ---------------------------------------------------------------

  async fetchSettings(): Promise<JsonObject> {
    return asObject(await this.get("/settings")) ?? {};
  }

  async putSettings(settings: JsonObject): Promise<void> {
    await this.put("/settings", settings);
  }

  async semanticSearch(query: string, options?: { limit?: number; workspaceId?: string | null }): Promise<string[]> {
    const params: Record<string, string> = { q: query, limit: String(options?.limit ?? DEFAULT_SEARCH_LIMIT) };
    if (options?.workspaceId) {
      params.workspace_id = options.workspaceId;
    }
    const data = asArray(await this.get("/search", { query: params }));
    return data.map((hit) => str(asObject(hit)?.note_id)).filter((id) => id !== "");
  }

  async fetchCapabilities(): Promise<Capabilities> {
    const map = asObject(await this.get("/capabilities", { auth: "anonymous" })) ?? {};
    return {
      semanticSearch: map.semantic_search === true,
      audioTranscription: map.audio_transcription === true,
      imageOcr: map.image_ocr === true,
      // Absent on servers older than the reset feature.
      passwordReset: map.password_reset === true,
      serverVersion: map.server_version == null ? null : String(map.server_version),
    };
  }

  async fetchSearchStats(): Promise<SearchStats> {
    return parseSearchStats(await this.get("/search/stats"));
  }

  async reindexEmbeddings(): Promise<number> {
    return Math.trunc(num(asObject(await this.post("/search/reindex"))?.total));
  }

  async fetchReindexStatus(): Promise<ReindexStatus> {
    const map = asObject(await this.get("/search/reindex/status")) ?? {};
    return { running: map.running === true, done: Math.trunc(num(map.done)), total: Math.trunc(num(map.total)) };
  }

  async fetchManagedSettings(): Promise<Record<string, ManagedSetting>> {
    const map = asObject(await this.get("/managed-settings")) ?? {};
    const out: Record<string, ManagedSetting> = {};
    for (const [key, value] of Object.entries(map)) {
      if (asObject(value)) {
        out[key] = parseManagedSetting(value);
      }
    }
    return out;
  }

  async transcribeNote(noteId: string): Promise<void> {
    await this.post(`/notes/${noteId}/transcribe`);
  }

  async unfurl(url: string): Promise<LinkPreview | null> {
    try {
      const data = asObject(await this.get("/unfurl", { query: { url } }));
      return data ? parseLinkPreview(data) : null;
    } catch (error) {
      // Invalid/blocked URL (400) or auth/transient error: no preview.
      if (error instanceof ApiError) {
        return null;
      }
      throw error;
    }
  }

  async summarizeUrl(url: string, options: { noteId: string; length?: UrlSummaryLength; signal?: AbortSignal }): Promise<string> {
    const data = await this.request("POST", "/unfurl/summary", {
      body: { url, note_id: options.noteId, length: options.length ?? "short" },
      deadline: "ai",
      signal: options.signal,
    });
    return str(asObject(data)?.summary);
  }

  async cancelLinkSummaries(noteId: string): Promise<void> {
    await this.del(`/notes/${noteId}/link-summaries`);
  }

  // -- live sync and chat -----------------------------------------------------

  changeEvents(listener: () => void): Unsubscribe {
    return connectChangeEvents({
      url: () => this.webSocketUrl("/ws"),
      token: () => this.token,
      listener,
      factory: this.webSocketFactory,
    });
  }

  async testLlm(config: { baseUrl: string; apiKey: string; model: string }): Promise<ProbeResult> {
    const map = asObject(await this.post("/llm/test", { base_url: config.baseUrl, api_key: config.apiKey, model: config.model })) ?? {};
    return { ok: map.ok === true, error: typeof map.error === "string" ? map.error : null };
  }

  async testNotify(config: Readonly<Record<string, string>>): Promise<ProbeResult> {
    const map = asObject(await this.post("/notify/test", config)) ?? {};
    return { ok: map.ok === true, error: typeof map.error === "string" ? map.error : null };
  }

  chat(message: string, history: readonly ChatMessage[], options?: { workspaceId?: string | null }): ChatStream {
    let url = "";
    try {
      url = this.webSocketUrl("/chat");
    } catch {
      url = "";
    }
    return openChatStream({
      url,
      token: this.token,
      factory: (u) => {
        if (!u) {
          throw new Error("invalid backend URL");
        }
        return this.webSocketFactory(u);
      },
      request: (token) => {
        const frame: Record<string, unknown> = {
          token,
          message,
          history: history.map((m) => ({ role: m.role, content: m.content })),
        };
        if (options?.workspaceId) {
          frame.workspace_id = options.workspaceId;
        }
        return frame;
      },
    });
  }
}
