import type { Api } from "@/lib/api/client";
import { noteServerStamp, noteToJson, parseNote, reminderRepeatFromWire, type Note } from "@/lib/models/note";
import { parseAiSwitches, parseCollection, parseSavedView } from "@/lib/models/workspace";
import { optNum, optStr, str, strings, type JsonObject } from "@/lib/util/json";
import type { PendingOp } from "./pending-operation";

// Translates durable queue entries into calls on the API seam. Queue order,
// retries and optimistic state stay in the notes store. Ported from
// `state/pending_operation_executor.dart`.

const CONTENT_FIELDS = new Set(["kind", "title", "content", "items"]);

export class PendingOperationExecutor {
  constructor(
    private readonly api: Api,
    private readonly noteById: (id: string) => Note | null,
    /**
     * Note id to the exact `updated_at` the server last reported. A content
     * patch sends it as `if_unmodified_since`, so an offline edit cannot
     * silently overwrite one made elsewhere since.
     */
    private readonly serverUpdatedAt: Map<string, string>,
  ) {}

  /** Execute one queued write. */
  async run(op: PendingOp): Promise<void> {
    const id = op.id ?? "";
    const d = op.data;
    switch (op.kind) {
      case "collectionPut":
        return this.api.putCollection(parseCollection(d));
      case "collectionDelete":
        return this.api.deleteCollection(str(d.workspaceId), id);
      case "create":
        return this.create(op);
      case "patch":
        return this.patch(op);
      case "delete":
        return this.api.deleteNote(id);
      case "reorder":
        return this.api.reorderNotes(strings(d.ids));
      case "labelCreate":
        return this.api.createLabel(id, str(d.name), {
          workspaceId: str(d.workspaceId),
          color: optStr(d.color),
          icon: optStr(d.icon),
          position: optNum(d.position),
        });
      case "labelUpdate":
        return this.api.updateLabel(id, str(d.name), { color: optStr(d.color), icon: optStr(d.icon), position: optNum(d.position) });
      case "labelDelete":
        return this.api.deleteLabel(id);
      case "stageCreate":
        return this.api.createStage(id, str(d.name), {
          workspaceId: str(d.workspaceId),
          collectionId: optStr(d.collectionId),
          color: optStr(d.color),
          position: optNum(d.position),
        });
      case "stageUpdate":
        return this.api.updateStage(id, str(d.name), { color: optStr(d.color), position: optNum(d.position) });
      case "stageDelete":
        return this.api.deleteStage(id);
      case "workspaceCreate":
        await this.api.createWorkspace(id, str(d.name));
        return;
      case "workspaceRename":
        await this.api.renameWorkspace(id, str(d.name));
        return;
      case "workspaceViews":
        await this.api.updateWorkspaceViews(id, { notesEnabled: d.notesEnabled !== false, boardEnabled: d.boardEnabled !== false });
        return;
      case "workspaceAi":
        await this.api.updateWorkspaceAi(id, parseAiSwitches(d));
        return;
      case "savedViewPut": {
        const view = parseSavedView(d.view);
        if (view) {
          await this.api.putSavedView(str(d.workspaceId), view);
        }
        return;
      }
      case "savedViewDelete":
        return this.api.deleteSavedView(str(d.workspaceId), id);
      case "workspaceDelete":
        return this.api.deleteWorkspace(id);
      case "leaveWorkspace":
        return this.api.removeWorkspaceMember(id, str(d.userId));
      case "removeCollaborator":
        return this.api.removeCollaborator(id, str(d.userId));
      case "itemReminder": {
        // A null time is the clear, which is why the whole resource is written.
        const at = typeof d.at === "string" ? new Date(d.at) : null;
        return this.api.setItemReminder(id, str(d.itemId), at, reminderRepeatFromWire(d.repeat));
      }
      case "deleteAttachment":
        return this.api.deleteAttachment(id);
      case "transcribe":
        return this.api.transcribeNote(id);
      case "unknown":
        return;
    }
  }

  /** Re-reads the freshest note, filing from the queued op; a vanished note is a no-op. */
  private async create(op: PendingOp): Promise<void> {
    const id = op.id ?? "";
    const note = this.noteById(id);
    if (!note) {
      return;
    }
    const created = await this.api.createNote(parseNote({ ...noteToJson(note), ...op.data }));
    this.serverUpdatedAt.set(id, noteServerStamp(created));
  }

  private async patch(op: PendingOp): Promise<void> {
    const id = op.id ?? "";
    const fields: JsonObject = { ...op.data };
    const expected = this.serverUpdatedAt.get(id);
    if (expected !== undefined && Object.keys(fields).some((k) => CONTENT_FIELDS.has(k))) {
      fields.if_unmodified_since = expected;
    }
    const updated = await this.api.patchNote(id, fields);
    this.serverUpdatedAt.set(id, noteServerStamp(updated));
  }
}

