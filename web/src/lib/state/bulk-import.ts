import type { Api } from "@/lib/api/client";
import { ApiError } from "@/lib/api/errors";
import { makeNote, type ChecklistItem, type ItemReminder, type Label, type Note, type Stage, type UserRef } from "@/lib/models/note";
import { aiSwitchesEqual, DEFAULT_AI_SWITCHES, generalCollection, type Workspace } from "@/lib/models/workspace";
import { BackupRestoreError, workspaceAttachmentCount, type BackupNote, type BackupProgress, type BackupRestoreResult, type BackupWorkspace } from "@/lib/util/backup";
import { newId } from "@/lib/util/id";
import type { KeepArchive, KeepImportResult, KeepTrash } from "@/lib/util/keep-import";
import { remapNoteLinks } from "./note-links";
import { POSITION_GAP } from "./sparse-position";

// The awaited server writes behind a backup restore and a Google Keep import,
// in a fixed order so progress stays truthful. The notes store decides when
// one may run and refreshes afterwards. Ported from `state/bulk_import.dart`.

/** What a restore replaces: the account's owned workspace data when it starts. */
export interface RestoreReplacement {
  /** Notes this user owns in their own workspaces, the default one included. */
  readonly notes: readonly Note[];
  readonly defaultWorkspace: Workspace | null;
  readonly defaultLabels: readonly Label[];
  readonly defaultStages: readonly Stage[];
  /** Owned workspaces other than the default one, deleted with their contents. */
  readonly otherWorkspaces: readonly Workspace[];
}

export class BulkImporter {
  constructor(
    private readonly api: Api,
    private readonly currentUserId: string | null,
  ) {}

  private get owner(): UserRef | null {
    return this.currentUserId === null ? null : { id: this.currentUserId, name: "" };
  }

  /** Delete what [replacing] describes, then recreate [selected] under fresh ids. */
  async restoreBackup(selected: readonly BackupWorkspace[], replacing: RestoreReplacement, onProgress?: BackupProgress): Promise<BackupRestoreResult> {
    const sum = (count: (w: BackupWorkspace) => number): number => selected.reduce((t, w) => t + count(w), 0);
    const totalSteps =
      replacing.notes.length +
      replacing.defaultLabels.length +
      replacing.defaultStages.length +
      replacing.otherWorkspaces.length +
      selected.filter((w) => !w.isDefault).length +
      sum((w) => w.labels.length) +
      sum((w) => w.stages.length) +
      sum((w) => w.notes.length) +
      sum(workspaceAttachmentCount);
    let completed = 0;
    const step = (): void => onProgress?.(++completed, totalSteps);

    let restoredNotes = 0;
    let restoredAttachments = 0;
    let restoredLabels = 0;
    let restoredStages = 0;
    let restoredWorkspaces = 0;

    try {
      // Individually owned notes first; deleting the other workspaces then
      // removes whatever they still hold, regardless of author.
      const defaultWorkspace = replacing.defaultWorkspace;
      for (const note of replacing.notes) {
        await this.api.deleteNote(note.id);
        step();
      }
      for (const label of replacing.defaultLabels) {
        await this.api.deleteLabel(label.id);
        step();
      }
      for (const view of defaultWorkspace?.savedViews ?? []) {
        await this.api.deleteSavedView(defaultWorkspace?.id ?? "", view.id);
      }
      for (const stage of replacing.defaultStages) {
        await this.api.deleteStage(stage.id);
        step();
      }
      for (const workspace of replacing.otherWorkspaces) {
        await this.api.deleteWorkspace(workspace.id);
        step();
      }

      // Every restored note gets its id up front, so links between them remap.
      const restoredIds: Record<string, string> = {};
      for (const workspace of selected) {
        for (const note of workspace.notes) {
          restoredIds[note.id] = newId();
        }
      }

      for (const backupWorkspace of selected) {
        let targetWorkspaceId: string;
        if (backupWorkspace.isDefault) {
          if (!defaultWorkspace) {
            throw new BackupRestoreError("The account has no default workspace", 0);
          }
          targetWorkspaceId = defaultWorkspace.id;
          if (defaultWorkspace.name !== backupWorkspace.name) {
            await this.api.renameWorkspace(defaultWorkspace.id, backupWorkspace.name);
          }
        } else {
          const created = await this.api.createWorkspace(newId(), backupWorkspace.name);
          targetWorkspaceId = created.id;
          restoredWorkspaces++;
          step();
        }
        await this.restoreSettings(backupWorkspace, targetWorkspaceId);
        const collectionMap = await this.restoreCollections(backupWorkspace, targetWorkspaceId);
        const firstCollection = Object.values(collectionMap)[0] ?? null;
        for (const view of backupWorkspace.savedViews) {
          await this.api.putSavedView(targetWorkspaceId, view);
        }

        const labelMap: Record<string, string> = {};
        for (const label of backupWorkspace.labels) {
          const id = newId();
          await this.api.createLabel(id, label.name, { workspaceId: targetWorkspaceId, color: label.color, icon: label.icon, position: label.position });
          labelMap[label.id] = id;
          restoredLabels++;
          step();
        }

        const stageMap: Record<string, string> = {};
        for (const stage of backupWorkspace.stages) {
          const id = newId();
          await this.api.createStage(id, stage.name, {
            collectionId: (stage.collectionId !== null ? collectionMap[stage.collectionId] : undefined) ?? firstCollection,
            workspaceId: targetWorkspaceId,
            color: stage.color,
            position: stage.position,
          });
          stageMap[stage.id] = id;
          restoredStages++;
          step();
        }

        for (const backupNote of backupWorkspace.notes) {
          const note = this.restoredNote(backupNote, {
            id: restoredIds[backupNote.id] ?? newId(),
            workspaceId: targetWorkspaceId,
            collectionId: (backupNote.collectionId !== null ? collectionMap[backupNote.collectionId] : undefined) ?? firstCollection,
            noteIds: restoredIds,
            labelIds: labelMap,
            stageIds: stageMap,
          });
          await this.api.createNote(note, { preserveTimestamps: true });
          restoredNotes++;
          step();
          for (const attachment of backupNote.attachments) {
            await this.api.uploadAttachment(note.id, attachment.bytes, attachment.mime, attachment.filename);
            restoredAttachments++;
            step();
          }
        }
      }

      return {
        workspaces: restoredWorkspaces + (selected.some((w) => w.isDefault) ? 1 : 0),
        notes: restoredNotes,
        attachments: restoredAttachments,
        labels: restoredLabels,
        stages: restoredStages,
      };
    } catch (error) {
      const message =
        error instanceof ApiError ? error.serverMessage : error instanceof BackupRestoreError ? error.message : "Restore could not be completed";
      throw new BackupRestoreError(`${message}. Some owned workspace data may already have been replaced`, restoredNotes);
    }
  }

  /** Workspace switches that differ from a new workspace's defaults. */
  private async restoreSettings(backup: BackupWorkspace, targetId: string): Promise<void> {
    if (!backup.notesEnabled || !backup.boardEnabled) {
      await this.api.updateWorkspaceViews(targetId, { notesEnabled: backup.notesEnabled, boardEnabled: backup.boardEnabled });
    }
    if (!aiSwitchesEqual(backup.aiSwitches, DEFAULT_AI_SWITCHES)) {
      await this.api.updateWorkspaceAi(targetId, backup.aiSwitches);
    }
  }

  /** Replace the target's collections with the backup's; old id to new id. */
  private async restoreCollections(backup: BackupWorkspace, targetId: string): Promise<Record<string, string>> {
    const current = await this.api.fetchWorkspaces();
    for (const target of current.filter((w) => w.id === targetId)) {
      for (const collection of target.collections) {
        await this.api.deleteCollection(targetId, collection.id);
      }
    }
    const source =
      backup.collections.length === 0 && (backup.notes.length > 0 || backup.stages.length > 0) ? [generalCollection(backup.id)] : backup.collections;
    const map: Record<string, string> = {};
    for (const old of source) {
      const id = newId();
      map[old.id] = id;
      await this.api.putCollection({ ...old, id, workspaceId: targetId });
    }
    return map;
  }

  /** A backup note as it is recreated, every reference mapped to new ids. */
  private restoredNote(
    backup: BackupNote,
    ids: {
      id: string;
      workspaceId: string;
      collectionId: string | null;
      noteIds: Record<string, string>;
      labelIds: Record<string, string>;
      stageIds: Record<string, string>;
    },
  ): Note {
    // An item with no id gets a fresh one, so its reminder follows it.
    const itemIdMap: Record<string, string> = {};
    const items: ChecklistItem[] = backup.items.map((item) => {
      const id = item.id === "" ? newId() : item.id;
      itemIdMap[item.id] = id;
      return { id, text: item.text, done: item.done, depth: 0 };
    });
    const itemReminders: Record<string, ItemReminder> = {};
    for (const reminder of backup.itemReminders) {
      const itemId = itemIdMap[reminder.itemId];
      if (itemId !== undefined && items.some((i) => i.id === itemId && !i.done)) {
        itemReminders[itemId] = { itemId, at: reminder.at, repeat: reminder.repeat };
      }
    }
    return makeNote({
      id: ids.id,
      workspaceId: ids.workspaceId,
      collectionId: ids.collectionId,
      kind: backup.kind,
      title: backup.title,
      content: remapNoteLinks(backup.content, ids.noteIds),
      items,
      color: backup.color,
      pattern: backup.pattern,
      pinned: backup.pinned,
      archived: backup.archived,
      trashed: backup.trashed,
      position: backup.position,
      gridSpan: backup.gridSpan,
      stageId: backup.stageId === null ? null : (ids.stageIds[backup.stageId] ?? null),
      stagePosition: backup.stagePosition,
      reminderAt: backup.reminderAt,
      reminderRepeat: backup.reminderRepeat,
      itemReminders,
      createdAt: backup.createdAt,
      updatedAt: backup.updatedAt,
      labelIds: backup.labelIds.map((old) => ids.labelIds[old]).filter((id): id is string => id !== undefined),
      owner: this.owner,
    });
  }

  /**
   * Add [archive]'s notes in front of [frontPosition]. A label is matched by
   * name, ignoring case, and created when the workspace has none.
   */
  async importKeep(
    archive: KeepArchive,
    options: {
      workspaceId: string;
      collectionId: string;
      existingLabels: readonly Label[];
      frontPosition: number;
      trash?: KeepTrash;
      onProgress?: BackupProgress;
    },
  ): Promise<KeepImportResult> {
    // Oldest first, each ahead of the last, so the most recent ends up in front.
    const notes = archive.notes
      .filter((n) => options.trash === "include" || !n.trashed)
      .sort((a, b) => a.updatedAt.getTime() - b.updatedAt.getTime());
    const total = notes.reduce((n, note) => n + 1 + note.attachments.length, 0);
    const labelIds = new Map(options.existingLabels.map((l) => [l.name.toLowerCase(), l.id]));
    let position = options.frontPosition;
    let completed = 0;
    let importedNotes = 0;
    let importedAttachments = 0;
    let createdLabels = 0;

    try {
      for (const keep of notes) {
        const noteLabels: string[] = [];
        for (const name of keep.labels) {
          let id = labelIds.get(name.toLowerCase());
          if (id === undefined) {
            id = newId();
            await this.api.createLabel(id, name, { workspaceId: options.workspaceId });
            labelIds.set(name.toLowerCase(), id);
            createdLabels++;
          }
          if (!noteLabels.includes(id)) {
            noteLabels.push(id);
          }
        }
        const note = makeNote({
          id: newId(),
          workspaceId: options.workspaceId,
          collectionId: options.collectionId,
          kind: keep.kind,
          title: keep.title,
          content: keep.content,
          items: keep.items.map((item) => ({ id: newId(), text: item.text, done: item.done, depth: 0 })),
          color: keep.color,
          pinned: keep.pinned,
          archived: keep.archived,
          trashed: keep.trashed,
          position,
          createdAt: keep.createdAt,
          updatedAt: keep.updatedAt,
          labelIds: noteLabels,
          owner: this.owner,
        });
        position -= POSITION_GAP;
        await this.api.createNote(note, { preserveTimestamps: true });
        importedNotes++;
        options.onProgress?.(++completed, total);
        for (const attachment of keep.attachments) {
          await this.api.uploadAttachment(note.id, attachment.bytes, attachment.mime, attachment.filename);
          importedAttachments++;
          options.onProgress?.(++completed, total);
        }
      }
      return { notes: importedNotes, attachments: importedAttachments, labels: createdLabels };
    } catch (error) {
      const message = error instanceof ApiError ? error.serverMessage : "Import could not be completed";
      throw new BackupRestoreError(message, importedNotes);
    }
  }
}
