import { asArray, asObject, num, str, type JsonObject } from "@/lib/util/json";
import { parsePendingOp, pendingOpToJson, type PendingOp } from "./pending-operation";

// A queued write the server refused for good, kept with the note as it stood
// so the user can copy their text out, retry, or dismiss it. Ported from
// `state/sync_issue.dart`.

const HTTP_CONFLICT = 409;
const CONFLICT_MESSAGE = "note changed elsewhere";

export interface SyncIssue {
  readonly operation: PendingOp;
  readonly message: string;
  readonly statusCode: number;
  /** The note's JSON when the write was refused. */
  readonly note: Readonly<JsonObject> | null;
}

export function isConflictIssue(issue: SyncIssue): boolean {
  return issue.statusCode === HTTP_CONFLICT && issue.message === CONFLICT_MESSAGE;
}

export function syncIssueLabel(issue: SyncIssue): string {
  const fromNote = issue.note?.title;
  if (typeof fromNote === "string") {
    return fromNote;
  }
  const fromOp = issue.operation.data.title;
  return typeof fromOp === "string" ? fromOp : issue.operation.kind;
}

/** The text to offer for copying, or null when the write carried none. */
export function syncIssueCopyText(issue: SyncIssue): string | null {
  const data = issue.note ?? issue.operation.data;
  if (issue.operation.kind !== "create" && !("content" in data) && !("items" in data)) {
    return null;
  }
  const items = asArray(data.items).map((raw) => {
    const item = asObject(raw) ?? {};
    return `${item.done === true ? "☑" : "☐"} ${str(item.text)}`;
  });
  return [str(data.title), str(data.content), ...items].filter((part) => part !== "").join("\n");
}

export function syncIssueToJson(issue: SyncIssue): JsonObject {
  const json: JsonObject = { operation: pendingOpToJson(issue.operation), message: issue.message, status: issue.statusCode };
  if (issue.note !== null) {
    json.note = issue.note;
  }
  return json;
}

export function parseSyncIssue(json: unknown): SyncIssue {
  const map = asObject(json) ?? {};
  return {
    operation: parsePendingOp(map.operation),
    message: str(map.message, "Change was rejected"),
    statusCode: Math.trunc(num(map.status, 400)),
    note: asObject(map.note),
  };
}
