import { asArray, asObject, bool, num, optStr, str, type JsonObject } from "@/lib/util/json";
import { parseUserRef, userRefToJson, type NoteRewriteTask, type UserRef } from "./note";

// Workspaces, collections, smart views and the AI a workspace allows. Ported
// from `models/workspace.dart`, `collection.dart` and `saved_view.dart`.

/** Collection layouts, as stored on the wire. */
export type CollectionLayout = "masonry" | "list" | "board";
export type CollectionSort = "custom" | "edited" | "newest" | "oldest";

export const COLLECTION_LAYOUTS: readonly CollectionLayout[] = ["masonry", "list", "board"];
export const COLLECTION_SORTS: readonly CollectionSort[] = ["custom", "edited", "newest", "oldest"];

/** A shared container inside a workspace; its layout is everyone's. */
export interface NoteCollection {
  readonly id: string;
  readonly workspaceId: string;
  readonly name: string;
  readonly icon: string | null;
  readonly color: string | null;
  /** Normally a [CollectionLayout]; kept as a string so unknowns survive. */
  readonly layout: string;
  readonly sort: string;
  readonly position: number;
}

/** Id of a workspace's base collection. */
export function generalCollectionId(workspaceId: string): string {
  return `${workspaceId}-general`;
}

export function generalCollection(workspaceId: string, layout: string = "masonry"): NoteCollection {
  return {
    id: generalCollectionId(workspaceId),
    workspaceId,
    name: "General",
    icon: null,
    color: null,
    layout,
    sort: "custom",
    position: 0,
  };
}

export function parseCollection(json: unknown): NoteCollection {
  const map = asObject(json) ?? {};
  return {
    id: str(map.id),
    workspaceId: str(map.workspace_id),
    name: str(map.name),
    icon: optStr(map.icon),
    color: optStr(map.color),
    layout: str(map.layout, "masonry"),
    sort: str(map.sort, "custom"),
    position: num(map.position),
  };
}

export function collectionToJson(c: NoteCollection): JsonObject {
  return {
    id: c.id,
    workspace_id: c.workspaceId,
    name: c.name,
    icon: c.icon,
    color: c.color,
    layout: c.layout,
    sort: c.sort,
    position: c.position,
  };
}

/** A named search pinned to the sidebar (a "smart view"). */
export interface SavedView {
  readonly id: string;
  readonly position: number;
  readonly name: string;
  /** The search string, operators included. */
  readonly query: string;
  readonly icon: string | null;
  readonly color: string | null;
}

/** Null for an entry with no id, name or query. */
export function parseSavedView(json: unknown): SavedView | null {
  const map = asObject(json);
  if (!map) {
    return null;
  }
  const id = str(map.id).trim();
  const name = str(map.name).trim();
  const query = str(map.query).trim();
  if (!id || !name || !query) {
    return null;
  }
  const icon = str(map.icon).trim();
  const color = str(map.color).trim();
  return {
    id,
    position: num(map.position),
    name,
    query,
    icon: icon || null,
    color: color || null,
  };
}

export function savedViewToJson(view: SavedView): JsonObject {
  const json: JsonObject = { id: view.id, position: view.position, name: view.name, query: view.query };
  if (view.icon !== null) {
    json.icon = view.icon;
  }
  if (view.color !== null) {
    json.color = view.color;
  }
  return json;
}

export type AiFeature = "labeling" | "chat" | "writing";

/** What AI a workspace allows. Only the owner flips these. */
export interface AiSwitches {
  readonly enabled: boolean;
  readonly labeling: boolean;
  readonly chat: boolean;
  readonly writing: boolean;
  /** Whether personal access tokens (MCP) may reach the workspace. */
  readonly assistantAccess: boolean;
}

export const DEFAULT_AI_SWITCHES: AiSwitches = {
  enabled: true,
  labeling: true,
  chat: true,
  writing: true,
  assistantAccess: true,
};

export function switchesAllow(switches: AiSwitches, feature: AiFeature): boolean {
  return switches.enabled && switches[feature];
}

/** A switch the payload leaves out is on, as on the server. */
export function parseAiSwitches(json: unknown): AiSwitches {
  const map = asObject(json) ?? {};
  return {
    enabled: map.enabled !== false,
    labeling: map.labeling !== false,
    chat: map.chat !== false,
    writing: map.writing !== false,
    assistantAccess: map.assistant_access !== false,
  };
}

export function aiSwitchesToJson(s: AiSwitches): JsonObject {
  return {
    enabled: s.enabled,
    labeling: s.labeling,
    chat: s.chat,
    writing: s.writing,
    assistant_access: s.assistantAccess,
  };
}

export function aiSwitchesEqual(a: AiSwitches, b: AiSwitches): boolean {
  return (
    a.enabled === b.enabled &&
    a.labeling === b.labeling &&
    a.chat === b.chat &&
    a.writing === b.writing &&
    a.assistantAccess === b.assistantAccess
  );
}

/**
 * A workspace's AI as a member sees it: the switches, whether the owner has a
 * provider, and the owner's rewrite task names (prompts are always empty).
 */
export interface WorkspaceAi {
  readonly switches: AiSwitches;
  readonly providerReady: boolean;
  readonly rewriteTasks: readonly NoteRewriteTask[];
}

export const NO_WORKSPACE_AI: WorkspaceAi = {
  switches: DEFAULT_AI_SWITCHES,
  providerReady: false,
  rewriteTasks: [],
};

/** Whether [feature] runs here: switched on, with a provider to run it. */
export function aiAllows(ai: WorkspaceAi, feature: AiFeature): boolean {
  return ai.providerReady && switchesAllow(ai.switches, feature);
}

export function parseWorkspaceAi(json: unknown): WorkspaceAi {
  const map = asObject(json) ?? {};
  const rewriteTasks: NoteRewriteTask[] = [];
  for (const task of asArray(map.rewrite_tasks)) {
    const t = asObject(task);
    if (t && typeof t.id === "string" && typeof t.name === "string") {
      rewriteTasks.push({ id: t.id, name: t.name, prompt: "" });
    }
  }
  return {
    switches: parseAiSwitches(map),
    providerReady: map.provider_ready === true,
    rewriteTasks,
  };
}

export function workspaceAiToJson(ai: WorkspaceAi): JsonObject {
  return {
    ...aiSwitchesToJson(ai.switches),
    provider_ready: ai.providerReady,
    rewrite_tasks: ai.rewriteTasks.map((t) => ({ id: t.id, name: t.name })),
  };
}

export interface Workspace {
  readonly id: string;
  readonly collections: readonly NoteCollection[];
  /** Smart views, shared with every member. */
  readonly savedViews: readonly SavedView[];
  readonly name: string;
  readonly notesEnabled: boolean;
  readonly boardEnabled: boolean;
  /** Null only for a workspace created locally that has not synced. */
  readonly owner: UserRef | null;
  /** Everyone invited, excluding the owner. */
  readonly members: readonly UserRef[];
  /** The account's own workspace; cannot be deleted or left. */
  readonly isDefault: boolean;
  readonly ai: WorkspaceAi;
}

export function makeWorkspace(fields: Partial<Workspace> & { id: string; name: string }): Workspace {
  return {
    collections: [],
    savedViews: [],
    notesEnabled: true,
    boardEnabled: true,
    owner: null,
    members: [],
    isDefault: false,
    ai: NO_WORKSPACE_AI,
    ...fields,
  };
}

export function isWorkspaceOwnedBy(w: Workspace, userId: string | null | undefined): boolean {
  return w.owner === null || w.owner.id === userId;
}

export const isWorkspaceShared = (w: Workspace): boolean => w.members.length > 0;

export function parseWorkspace(json: unknown): Workspace {
  const map = asObject(json) ?? {};
  const id = str(map.id);
  const rawCollections = Array.isArray(map.collections)
    ? map.collections
    : [collectionToJson(generalCollection(id, map.notes_enabled === false ? "board" : "masonry"))];
  const savedViews: SavedView[] = [];
  for (const entry of asArray(map.smart_views)) {
    const view = parseSavedView(entry);
    if (view) {
      savedViews.push(view);
    }
  }
  return {
    id,
    collections: rawCollections.map(parseCollection),
    savedViews,
    name: str(map.name),
    notesEnabled: bool(map.notes_enabled, true),
    boardEnabled: bool(map.board_enabled, true),
    owner: map.owner == null ? null : parseUserRef(map.owner),
    members: asArray(map.members).map(parseUserRef),
    isDefault: bool(map.is_default),
    ai: parseWorkspaceAi(map.ai),
  };
}

export function workspaceToJson(w: Workspace): JsonObject {
  return {
    id: w.id,
    collections: w.collections.map(collectionToJson),
    smart_views: w.savedViews.map(savedViewToJson),
    name: w.name,
    notes_enabled: w.notesEnabled,
    board_enabled: w.boardEnabled,
    owner: w.owner ? userRefToJson(w.owner) : null,
    members: w.members.map(userRefToJson),
    is_default: w.isDefault,
    ai: workspaceAiToJson(w.ai),
  };
}

/** What a workspace duplicate copies. */
export type WorkspaceCopyContent = "structure" | "notes";
