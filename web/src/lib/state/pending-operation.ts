import { asObject, optStr, str, type JsonObject } from "@/lib/util/json";

// The backend write a persisted queue entry represents. Ported from
// `state/pending_operation.dart`; the kind names are the persisted format.

export const PENDING_OP_KINDS = [
  "collectionPut",
  "collectionDelete",
  "create",
  "patch",
  "delete",
  "reorder",
  "labelCreate",
  "labelUpdate",
  "labelDelete",
  "stageCreate",
  "stageUpdate",
  "stageDelete",
  "workspaceCreate",
  "workspaceRename",
  "workspaceViews",
  "workspaceAi",
  "savedViewPut",
  "savedViewDelete",
  "workspaceDelete",
  "leaveWorkspace",
  "removeCollaborator",
  "itemReminder",
  "deleteAttachment",
  "transcribe",
  "unknown",
] as const;
export type PendingOpKind = (typeof PENDING_OP_KINDS)[number];

export function pendingOpKindFromWire(value: unknown): PendingOpKind {
  return (PENDING_OP_KINDS as readonly unknown[]).includes(value) ? (value as PendingOpKind) : "unknown";
}

/** A serializable backend write that survives a reload. */
export interface PendingOp {
  readonly kind: PendingOpKind;
  readonly id: string | null;
  readonly data: Readonly<JsonObject>;
}

export function pendingOp(kind: PendingOpKind, id: string | null = null, data: JsonObject = {}): PendingOp {
  return { kind, id, data };
}

export function pendingOpToJson(op: PendingOp): JsonObject {
  const json: JsonObject = { kind: op.kind };
  if (op.id !== null) {
    json.id = op.id;
  }
  if (Object.keys(op.data).length > 0) {
    json.data = op.data;
  }
  return json;
}

export function parsePendingOp(json: unknown): PendingOp {
  const map = asObject(json) ?? {};
  return { kind: pendingOpKindFromWire(str(map.kind)), id: optStr(map.id), data: asObject(map.data) ?? {} };
}
