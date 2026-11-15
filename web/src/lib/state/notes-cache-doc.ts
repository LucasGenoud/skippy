import { parseWorkspace, workspaceToJson, type Workspace } from "@/lib/models/workspace";
import { labelToJson, noteToJson, parseLabel, parseNote, parseStage, stageToJson, type Label, type Note, type Stage } from "@/lib/models/note";
import { asArray, asObject, strings, type JsonObject } from "@/lib/util/json";
import { parsePendingOp, pendingOpToJson, type PendingOp } from "./pending-operation";
import { parseSyncIssue, syncIssueToJson, type SyncIssue } from "./sync-issue";

// The offline snapshot the notes store keeps per account and server, plus the
// small navigation record kept beside it. Pure encoding; ported from
// `state/notes_cache_doc.dart`.

export interface NotesCacheDoc {
  readonly notes: readonly Note[];
  readonly labels: readonly Label[];
  readonly stages: readonly Stage[];
  readonly workspaces: readonly Workspace[];
  readonly checklistHistory: Readonly<Record<string, readonly string[]>>;
  readonly queue: readonly PendingOp[];
  readonly syncIssues: readonly SyncIssue[];
  /** Note id to the exact `updated_at` the server last reported. */
  readonly serverUpdatedAt: Readonly<Record<string, string>>;
}

export const EMPTY_CACHE_DOC: NotesCacheDoc = {
  notes: [],
  labels: [],
  stages: [],
  workspaces: [],
  checklistHistory: {},
  queue: [],
  syncIssues: [],
  serverUpdatedAt: {},
};

export function parseNotesCacheDoc(doc: JsonObject): NotesCacheDoc {
  const history: Record<string, string[]> = {};
  for (const [key, value] of Object.entries(asObject(doc.history) ?? {})) {
    history[key] = strings(value);
  }
  const serverUpdatedAt: Record<string, string> = {};
  for (const [key, value] of Object.entries(asObject(doc.server_updated_at) ?? {})) {
    if (typeof value === "string") {
      serverUpdatedAt[key] = value;
    }
  }
  return {
    notes: asArray(doc.notes).map(parseNote),
    labels: asArray(doc.labels).map(parseLabel),
    stages: asArray(doc.stages).map(parseStage),
    workspaces: asArray(doc.workspaces).map(parseWorkspace),
    checklistHistory: history,
    queue: asArray(doc.queue).map(parsePendingOp),
    syncIssues: asArray(doc.sync_issues).map(parseSyncIssue),
    serverUpdatedAt,
  };
}

export function notesCacheDocToJson(doc: NotesCacheDoc): JsonObject {
  return {
    // Attachment metadata only, never bytes.
    notes: doc.notes.map(noteToJson),
    labels: doc.labels.map(labelToJson),
    stages: doc.stages.map(stageToJson),
    workspaces: doc.workspaces.map(workspaceToJson),
    history: Object.fromEntries(Object.entries(doc.checklistHistory).map(([k, v]) => [k, [...v]])),
    queue: doc.queue.map(pendingOpToJson),
    sync_issues: doc.syncIssues.map(syncIssueToJson),
    server_updated_at: { ...doc.serverUpdatedAt },
  };
}

/**
 * Where a navigation destination points. Persisted per workspace so each
 * workspace reopens its own last view.
 */
export type Destination = "notes" | "archive" | "trash" | "reminders" | { readonly label: string } | { readonly smartView: string };

export function destinationsEqual(a: Destination, b: Destination): boolean {
  if (typeof a === "string" || typeof b === "string") {
    return a === b;
  }
  if ("label" in a && "label" in b) {
    return a.label === b.label;
  }
  if ("smartView" in a && "smartView" in b) {
    return a.smartView === b.smartView;
  }
  return false;
}

/** Where this device was: the open workspace, and each workspace's collection and view. */
export interface NavigationCacheDoc {
  readonly activeWorkspaceId: string | null;
  readonly collectionChoices: Readonly<Record<string, string>>;
  readonly workspaceViews: Readonly<Record<string, Destination>>;
}

function destinationFromJson(value: unknown): Destination | null {
  const map = asObject(value);
  if (!map) {
    return null;
  }
  switch (map.view) {
    case "notes":
    case "board":
      return "notes";
    case "archive":
    case "trash":
    case "reminders":
      return map.view;
    case "label":
      return typeof map.label_id === "string" && map.label_id ? { label: map.label_id } : null;
    case "smart":
      return typeof map.saved_view_id === "string" && map.saved_view_id ? { smartView: map.saved_view_id } : null;
    default:
      return null;
  }
}

function destinationToJson(d: Destination): JsonObject {
  if (typeof d === "string") {
    return { view: d };
  }
  return "label" in d ? { view: "label", label_id: d.label } : { view: "smart", saved_view_id: d.smartView };
}

export function parseNavigationDoc(doc: JsonObject): NavigationCacheDoc {
  const choices: Record<string, string> = {};
  for (const [key, value] of Object.entries(asObject(doc.collection_choices) ?? {})) {
    if (typeof value === "string") {
      choices[key] = value;
    }
  }
  const views: Record<string, Destination> = {};
  for (const [key, value] of Object.entries(asObject(doc.workspace_views) ?? {})) {
    const d = destinationFromJson(value);
    if (d) {
      views[key] = d;
    }
  }
  return {
    activeWorkspaceId: typeof doc.active_workspace === "string" ? doc.active_workspace : null,
    collectionChoices: choices,
    workspaceViews: views,
  };
}

export function navigationDocToJson(doc: NavigationCacheDoc): JsonObject {
  return {
    active_workspace: doc.activeWorkspaceId,
    collection_choices: { ...doc.collectionChoices },
    workspace_views: Object.fromEntries(Object.entries(doc.workspaceViews).map(([k, v]) => [k, destinationToJson(v)])),
  };
}
