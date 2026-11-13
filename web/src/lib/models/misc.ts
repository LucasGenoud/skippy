import { asArray, asObject, num, optStr, parseDate, str } from "@/lib/util/json";
import { parseLabel, parseNote, parseStage, type Label, type Note, type Stage } from "./note";

// Smaller wire models: chat frames, link previews, search stats, share links,
// personal access tokens, managed settings. Ported 1:1 from app/lib/models.

// -- chat -------------------------------------------------------------------

/** One prior turn sent back as conversation history. */
export interface ChatMessage {
  readonly role: "user" | "assistant";
  readonly content: string;
}

/** A note the answer drew from. */
export interface ChatSource {
  readonly id: string;
  readonly title: string;
}

export type ChatEvent =
  | { readonly type: "sources"; readonly notes: readonly ChatSource[] }
  | {
      readonly type: "created";
      /** "create" | "append" | "update" */
      readonly action: string;
      readonly note: ChatSource;
      readonly undo: Readonly<Record<string, unknown>>;
    }
  | { readonly type: "delta"; readonly text: string }
  | { readonly type: "done" }
  | { readonly type: "error"; readonly message: string };

function parseChatSource(json: unknown): ChatSource | null {
  const map = asObject(json);
  if (!map || typeof map.id !== "string") {
    return null;
  }
  return { id: map.id, title: str(map.title) };
}

/** Null for frames of unknown type, so protocol additions never break us. */
export function parseChatEvent(json: unknown): ChatEvent | null {
  const map = asObject(json);
  if (!map) {
    return null;
  }
  switch (map.type) {
    case "sources":
      return {
        type: "sources",
        notes: asArray(map.notes)
          .map(parseChatSource)
          .filter((s): s is ChatSource => s !== null),
      };
    case "created": {
      const note = parseChatSource(map.note);
      if (!note) {
        return null;
      }
      return { type: "created", action: str(map.action, "create"), note, undo: asObject(map.undo) ?? {} };
    }
    case "delta":
      return { type: "delta", text: str(map.text) };
    case "done":
      return { type: "done" };
    case "error":
      return { type: "error", message: str(map.message, "unknown error") };
    default:
      return null;
  }
}

export const isTerminalChatEvent = (e: ChatEvent): boolean => e.type === "done" || e.type === "error";

// -- link previews ----------------------------------------------------------

/** Open Graph metadata from `/api/unfurl`. Every field but url may be null. */
export interface LinkPreview {
  readonly url: string;
  readonly title: string | null;
  readonly description: string | null;
  readonly image: string | null;
  readonly siteName: string | null;
  readonly favicon: string | null;
}

function clean(value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }
  const t = value.trim();
  return t ? t : null;
}

export function parseLinkPreview(json: unknown): LinkPreview {
  const map = asObject(json) ?? {};
  return {
    url: str(map.url),
    title: clean(map.title),
    description: clean(map.description),
    image: clean(map.image),
    siteName: clean(map.site_name),
    favicon: clean(map.favicon),
  };
}

/** The host with `www.` stripped, for the card's caption line. */
export function previewHost(preview: LinkPreview): string {
  let host = "";
  try {
    host = new URL(preview.url).host;
  } catch {
    host = "";
  }
  return host.startsWith("www.") ? host.slice(4) : host;
}

export function previewHasRichContent(preview: LinkPreview): boolean {
  return Boolean(preview.title) || Boolean(preview.image);
}

// -- semantic search stats --------------------------------------------------

export interface SearchStats {
  readonly enabled: boolean;
  readonly model: string;
  readonly dimensions: number;
  readonly totalNotes: number;
  readonly indexedNotes: number;
}

export const DISABLED_SEARCH_STATS: SearchStats = {
  enabled: false,
  model: "",
  dimensions: 0,
  totalNotes: 0,
  indexedNotes: 0,
};

export function parseSearchStats(json: unknown): SearchStats {
  const map = asObject(json) ?? {};
  if (map.enabled !== true) {
    return DISABLED_SEARCH_STATS;
  }
  return {
    enabled: true,
    model: str(map.model, "unknown"),
    dimensions: Math.trunc(num(map.dimensions)),
    totalNotes: Math.trunc(num(map.total_notes)),
    indexedNotes: Math.trunc(num(map.indexed_notes)),
  };
}

export interface ReindexStatus {
  readonly running: boolean;
  readonly done: number;
  readonly total: number;
}

// -- public share links -----------------------------------------------------

export const SHARE_TARGETS = [
  { id: "note", noun: "Note" },
  { id: "notes", noun: "Notes" },
  { id: "board", noun: "Board" },
  { id: "label", noun: "Label" },
] as const;
export type ShareTarget = (typeof SHARE_TARGETS)[number]["id"];

export function shareTargetFromWire(value: unknown): ShareTarget | null {
  return SHARE_TARGETS.find((t) => t.id === value)?.id ?? null;
}

/** How a target reads in the manage list ("Board", "Note"). */
export function shareTargetNoun(target: ShareTarget): string {
  return SHARE_TARGETS.find((t) => t.id === target)?.noun ?? "Note";
}

/** A public link as its owner sees it. */
export interface ShareLink {
  readonly token: string;
  readonly target: ShareTarget;
  readonly noteId: string | null;
  readonly workspaceId: string | null;
  readonly collectionId: string | null;
  readonly labelId: string | null;
  /** Server-resolved name of what the link points at. */
  readonly title: string;
  readonly createdAt: Date;
  readonly expiresAt: Date | null;
}

export function parseShareLink(json: unknown): ShareLink {
  const map = asObject(json) ?? {};
  return {
    token: str(map.token),
    target: shareTargetFromWire(map.target) ?? "note",
    noteId: optStr(map.note_id),
    workspaceId: optStr(map.workspace_id),
    collectionId: optStr(map.collection_id),
    labelId: optStr(map.label_id),
    title: str(map.title),
    createdAt: parseDate(map.created_at) ?? new Date(),
    expiresAt: parseDate(map.expires_at),
  };
}

export const shareLinkPath = (link: ShareLink): string => `/s/${link.token}`;

/** The full URL to hand out, built from the backend's origin. */
export function publicShareUrl(baseUrl: string, link: ShareLink): string {
  return `${baseUrl.replace(/\/+$/, "")}${shareLinkPath(link)}`;
}

/** Everything behind a public link. Read-only by construction. */
export interface PublicShare {
  readonly target: ShareTarget;
  readonly title: string;
  readonly sharedBy: string;
  readonly notes: readonly Note[];
  readonly labels: readonly Label[];
  readonly stages: readonly Stage[];
  readonly expiresAt: Date | null;
}

export function parsePublicShare(json: unknown): PublicShare {
  const map = asObject(json) ?? {};
  return {
    target: shareTargetFromWire(map.target) ?? "note",
    title: str(map.title),
    sharedBy: str(map.shared_by),
    notes: asArray(map.notes).map(parseNote),
    labels: asArray(map.labels).map(parseLabel),
    stages: asArray(map.stages).map(parseStage),
    expiresAt: parseDate(map.expires_at),
  };
}

// -- personal access tokens -------------------------------------------------

export const TOKEN_SCOPES = [
  { id: "read", label: "Read only" },
  { id: "write", label: "Read and add" },
] as const;
export type TokenScope = (typeof TOKEN_SCOPES)[number]["id"];

export interface ApiToken {
  readonly id: string;
  readonly name: string;
  readonly scope: TokenScope;
  readonly createdAt: Date;
  readonly lastUsedAt: Date | null;
}

export function parseApiToken(json: unknown): ApiToken {
  const map = asObject(json) ?? {};
  return {
    id: str(map.id),
    name: str(map.name),
    scope: map.scope === "write" ? "write" : "read",
    createdAt: parseDate(map.created_at) ?? new Date(),
    lastUsedAt: parseDate(map.last_used_at),
  };
}

/** A token just created: the one time its secret is shown. */
export interface CreatedApiToken {
  readonly token: ApiToken;
  readonly secret: string;
}

export function parseCreatedApiToken(json: unknown): CreatedApiToken {
  const map = asObject(json) ?? {};
  return { token: parseApiToken(map), secret: str(map.secret) };
}

/** Where an MCP client connects. */
export function mcpUrl(baseUrl: string): string {
  return `${baseUrl.replace(/\/+$/, "")}/api/mcp`;
}

/** The command that adds this server to Claude Code. */
export function claudeCodeCommand(baseUrl: string, secret: string): string {
  return `claude mcp add --transport http skippy ${mcpUrl(baseUrl)} --header "Authorization: Bearer ${secret}"`;
}

// -- managed settings -------------------------------------------------------

/**
 * A settings key the server pinned via an env var. Locked in the UI; [value]
 * is null for secrets, which the server never sends.
 */
export interface ManagedSetting {
  readonly secret: boolean;
  readonly value: unknown;
}

export function parseManagedSetting(json: unknown): ManagedSetting {
  const map = asObject(json) ?? {};
  return { secret: map.secret === true, value: map.value ?? null };
}

/** Capabilities from `/api/capabilities`. */
export interface Capabilities {
  readonly semanticSearch: boolean;
  readonly audioTranscription: boolean;
  readonly imageOcr: boolean;
  readonly passwordReset: boolean;
  readonly serverVersion: string | null;
}

/** A file handed in from outside (drop, picker, paste), ready to upload. */
export interface DroppedFile {
  readonly name: string;
  readonly mime: string;
  readonly bytes: Uint8Array | Blob;
}

export type UrlSummaryLength = "short" | "medium" | "long";
