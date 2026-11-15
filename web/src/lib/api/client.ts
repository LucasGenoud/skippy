import type {
  ApiToken,
  Attachment,
  AuthUser,
  Capabilities,
  ChatEvent,
  ChatMessage,
  CreatedApiToken,
  Label,
  LinkPreview,
  ManagedSetting,
  Note,
  NoteCollection,
  NoteRewriteTask,
  NoteVersion,
  PublicShare,
  ReindexStatus,
  ReminderRepeat,
  SavedView,
  SearchStats,
  ShareLink,
  ShareTarget,
  Stage,
  TokenScope,
  UrlSummaryLength,
  Workspace,
  WorkspaceCopyContent,
  AiSwitches,
} from "@/lib/models";
import type { JsonObject } from "@/lib/util/json";

// Everything the stores and screens need from the backend, method for method
// with `Api` in `app/lib/api/api_client.dart`. `HttpApi` implements it over
// fetch/WebSocket; `tests/fake-api.ts` is the in-memory one.
//
// Every method rejects with `ApiError` (non-2xx), `NetworkError` (never reached
// the server, including timeouts) or `AbortedError` (caller cancelled).

export interface AuthResult {
  readonly token: string;
  readonly user: AuthUser;
}

export interface AccountUpdate {
  readonly name?: string;
  readonly email?: string;
  readonly currentPassword?: string;
  readonly newPassword?: string;
}

export interface ProbeResult {
  readonly ok: boolean;
  readonly error: string | null;
}

export interface ShareLinkRequest {
  readonly target: ShareTarget;
  readonly noteId?: string | null;
  readonly workspaceId?: string | null;
  readonly collectionId?: string | null;
  readonly labelId?: string | null;
  readonly expiresAt?: Date | null;
}

/** Bytes to upload: a Blob/File from the browser, or raw bytes. */
export type UploadBody = Blob | Uint8Array;

/** Unsubscribes from [Api.changeEvents] and closes its socket. */
export type Unsubscribe = () => void;

/**
 * One chat turn's frames. Iterate with `for await`; breaking out (or calling
 * `cancel`) closes the socket. The stream ends after a `done` or `error` frame.
 */
export interface ChatStream extends AsyncIterable<ChatEvent> {
  cancel(): void;
}

export interface Api {
  /** Origin of the server this client talks to. */
  readonly baseUrl: string;

  /** Lightweight reachability probe; fails within ~3s when unreachable. */
  checkConnection(): Promise<void>;

  // auth
  register(name: string, email: string, password: string): Promise<AuthResult>;
  login(email: string, password: string): Promise<AuthResult>;
  logout(): Promise<void>;
  /** Resolves whether or not the address has an account. */
  requestPasswordReset(email: string): Promise<void>;
  /** Redeems an emailed link; resolves to the address it was sent to. */
  resetPassword(token: string, password: string): Promise<string>;
  me(): Promise<AuthUser>;
  deleteAccount(currentPassword: string): Promise<void>;
  updateAccount(update: AccountUpdate): Promise<AuthUser>;

  // workspaces
  /** Every workspace the user owns or was invited to, default first. */
  fetchWorkspaces(): Promise<Workspace[]>;
  createWorkspace(id: string, name: string): Promise<Workspace>;
  renameWorkspace(id: string, name: string): Promise<Workspace>;
  updateWorkspaceViews(id: string, views: { notesEnabled: boolean; boardEnabled: boolean }): Promise<Workspace>;
  /** Owner only. */
  updateWorkspaceAi(id: string, switches: AiSwitches): Promise<Workspace>;
  duplicateWorkspace(id: string, name: string, content: WorkspaceCopyContent, options?: { reminders?: boolean }): Promise<Workspace>;
  putCollection(collection: NoteCollection): Promise<void>;
  deleteCollection(workspaceId: string, id: string): Promise<void>;
  putSavedView(workspaceId: string, view: SavedView): Promise<void>;
  deleteSavedView(workspaceId: string, id: string): Promise<void>;
  deleteWorkspace(id: string): Promise<void>;
  /** Invite by email; resolves to the workspace with its new roster. */
  addWorkspaceMember(workspaceId: string, email: string): Promise<Workspace>;
  /** Remove a member, or leave by passing your own id. */
  removeWorkspaceMember(workspaceId: string, userId: string): Promise<void>;

  // notes
  fetchNotes(): Promise<Note[]>;
  createNote(note: Note, options?: { preserveTimestamps?: boolean }): Promise<Note>;
  /** Raw PATCH fields; omission and explicit null differ (reminders, stage). */
  patchNote(id: string, fields: JsonObject): Promise<Note>;
  /** Set, or with a null [at] clear, one checklist item's reminder. */
  setItemReminder(noteId: string, itemId: string, at: Date | null, repeat?: ReminderRepeat | null): Promise<void>;
  /** AI rewrite on the workspace owner's provider; resolves to the updated note. */
  rewriteNote(id: string, task: NoteRewriteTask, signal?: AbortSignal): Promise<Note>;
  deleteNote(id: string): Promise<void>;
  reorderNotes(ids: readonly string[]): Promise<void>;
  /** Newest first. */
  fetchNoteVersions(noteId: string): Promise<NoteVersion[]>;
  restoreNoteVersion(noteId: string, versionId: string): Promise<Note>;
  /** Previously checked item texts per note id, most used first. */
  fetchChecklistHistory(): Promise<Record<string, string[]>>;

  // public share links
  fetchShareLinks(): Promise<ShareLink[]>;
  createShareLink(request: ShareLinkRequest): Promise<ShareLink>;
  deleteShareLink(token: string): Promise<void>;

  // personal access tokens (MCP)
  fetchApiTokens(): Promise<ApiToken[]>;
  createApiToken(name: string, scope: TokenScope): Promise<CreatedApiToken>;
  deleteApiToken(id: string): Promise<void>;

  /** Unauthenticated: the token is the credential. */
  fetchPublicShare(token: string): Promise<PublicShare>;

  // labels
  fetchLabels(): Promise<Label[]>;
  createLabel(id: string, name: string, options: { workspaceId: string; color?: string | null; icon?: string | null; position?: number | null }): Promise<void>;
  updateLabel(id: string, name: string, options?: { color?: string | null; icon?: string | null; position?: number | null }): Promise<void>;
  deleteLabel(id: string): Promise<void>;

  // stages (board columns), parallel to labels on purpose
  fetchStages(): Promise<Stage[]>;
  createStage(
    id: string,
    name: string,
    options: { workspaceId: string; collectionId?: string | null; color?: string | null; position?: number | null },
  ): Promise<void>;
  updateStage(id: string, name: string, options?: { color?: string | null; position?: number | null }): Promise<void>;
  deleteStage(id: string): Promise<void>;

  // sharing
  addCollaborator(noteId: string, email: string): Promise<Note>;
  removeCollaborator(noteId: string, userId: string): Promise<void>;

  // attachments
  uploadAttachment(noteId: string, body: UploadBody, mime: string, filename: string): Promise<Attachment>;
  deleteAttachment(attachmentId: string): Promise<void>;
  /** Unsigned path for an attachment id (older servers). */
  fileUrl(attachmentId: string): string;
  /** Absolute, ready-to-load URL, preferring the server's signed one. */
  attachmentUrl(attachment: Attachment): string;

  // per-user settings document
  fetchSettings(): Promise<JsonObject>;
  putSettings(settings: JsonObject): Promise<void>;

  /** Note ids ranked by meaning. Rejects with ApiError 503 when disabled. */
  semanticSearch(query: string, options?: { limit?: number; workspaceId?: string | null }): Promise<string[]>;
  fetchCapabilities(): Promise<Capabilities>;
  fetchSearchStats(): Promise<SearchStats>;
  /** Re-embed everything; resolves to how many notes will be embedded. */
  reindexEmbeddings(): Promise<number>;
  fetchReindexStatus(): Promise<ReindexStatus>;
  /** Keys the self-hoster pinned via env vars. */
  fetchManagedSettings(): Promise<Record<string, ManagedSetting>>;
  /** (Re)transcribe an audio note's clip. */
  transcribeNote(noteId: string): Promise<void>;
  /** Link-preview metadata, or null when the server refuses the URL or fails. */
  unfurl(url: string): Promise<LinkPreview | null>;
  /** A short plain-text summary of a page, on the note's workspace AI. */
  summarizeUrl(url: string, options: { noteId: string; length?: UrlSummaryLength; signal?: AbortSignal }): Promise<string>;
  cancelLinkSummaries(noteId: string): Promise<void>;

  /** Live-sync nudges: [listener] runs whenever this user's data changes. */
  changeEvents(listener: () => void): Unsubscribe;

  /** Probe an unsaved LLM configuration. A failed probe resolves with ok false. */
  testLlm(config: { baseUrl: string; apiKey: string; model: string }): Promise<ProbeResult>;
  /** Send a real test notification with unsaved connector keys. */
  testNotify(config: Readonly<Record<string, string>>): Promise<ProbeResult>;

  /** One notes-chat turn over its own WebSocket. */
  chat(message: string, history: readonly ChatMessage[], options?: { workspaceId?: string | null }): ChatStream;
}
