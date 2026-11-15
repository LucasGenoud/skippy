import JSZip from "jszip";
import {
  aiSwitchesToJson,
  collectionToJson,
  DEFAULT_AI_SWITCHES,
  generalCollection,
  parseAiSwitches,
  parseCollection,
  parseSavedView,
  savedViewToJson,
  type AiSwitches,
  type NoteCollection,
  type SavedView,
  type Workspace,
} from "@/lib/models/workspace";
import {
  itemReminderToJson,
  noteKindFromWire,
  notePatternFromWire,
  orderedItemReminders,
  parseItemReminder,
  reminderRepeatFromWire,
  type Attachment,
  type ItemReminder,
  type Label,
  type Note,
  type NoteKind,
  type NotePattern,
  type ReminderRepeat,
  type Stage,
} from "@/lib/models/note";
import { asObject } from "./json";
import { MAX_UPLOAD_BYTES } from "./mime";

// A portable zip of owned workspaces: `backup.json` plus every attachment.
// Writes version 3; reads 1, 2 and 3. Ported from `util/backup.dart`, every
// validation rule included.

const BACKUP_FORMAT = "skippy-backup";
const BACKUP_VERSION = 3;
export const MAX_BACKUP_ARCHIVE_BYTES = 512 * 1024 * 1024;
const MAX_MANIFEST_BYTES = 8 * 1024 * 1024;
const MAX_WORKSPACES = 1000;
const MAX_NOTES = 10_000;
const MAX_LABELS = 2000;
const MAX_STAGES = 2000;
const MAX_ATTACHMENTS = 10_000;
const MAX_COLLECTIONS = 1000;
const MAX_SMART_VIEWS = 2000;
const MANIFEST = "backup.json";

export type AttachmentReader = (attachment: Attachment) => Promise<Uint8Array>;
export type BackupProgress = (completed: number, total: number) => void;

export interface BackupLabel {
  readonly id: string;
  readonly name: string;
  readonly color: string | null;
  readonly icon: string | null;
  readonly position: number;
}

export interface BackupStage {
  readonly collectionId: string | null;
  readonly id: string;
  readonly name: string;
  readonly color: string | null;
  readonly position: number;
}

export interface BackupChecklistItem {
  readonly id: string;
  readonly text: string;
  readonly done: boolean;
}

export interface BackupAttachment {
  readonly filename: string;
  readonly mime: string;
  readonly bytes: Uint8Array;
}

export interface BackupNote {
  readonly collectionId: string | null;
  readonly id: string;
  readonly kind: NoteKind;
  readonly title: string;
  readonly content: string;
  readonly items: readonly BackupChecklistItem[];
  readonly color: string;
  readonly pattern: NotePattern;
  readonly pinned: boolean;
  readonly archived: boolean;
  readonly trashed: boolean;
  readonly position: number;
  readonly gridSpan: number;
  readonly stageId: string | null;
  readonly stagePosition: number;
  readonly reminderAt: Date | null;
  readonly reminderRepeat: ReminderRepeat | null;
  readonly itemReminders: readonly ItemReminder[];
  readonly createdAt: Date;
  readonly updatedAt: Date;
  readonly labelIds: readonly string[];
  readonly attachments: readonly BackupAttachment[];
}

export interface BackupWorkspace {
  readonly collections: readonly NoteCollection[];
  readonly savedViews: readonly SavedView[];
  readonly id: string;
  readonly name: string;
  readonly isDefault: boolean;
  readonly notesEnabled: boolean;
  readonly boardEnabled: boolean;
  /** A backup from before switches reads as everything on. */
  readonly aiSwitches: AiSwitches;
  readonly labels: readonly BackupLabel[];
  readonly stages: readonly BackupStage[];
  readonly notes: readonly BackupNote[];
}

export interface BackupBundle {
  readonly workspaces: readonly BackupWorkspace[];
}

export const workspaceAttachmentCount = (w: BackupWorkspace): number => w.notes.reduce((n, note) => n + note.attachments.length, 0);
export const bundleNotes = (b: BackupBundle): BackupNote[] => b.workspaces.flatMap((w) => w.notes);
export const bundleAttachmentCount = (b: BackupBundle): number => b.workspaces.reduce((n, w) => n + workspaceAttachmentCount(w), 0);

export interface BackupRestoreResult {
  readonly workspaces: number;
  readonly notes: number;
  readonly attachments: number;
  readonly labels: number;
  readonly stages: number;
}

/** A restore or import that could not complete; the message is for the user. */
export class BackupRestoreError extends Error {
  constructor(
    message: string,
    readonly restoredNotes: number,
  ) {
    super(message);
    this.name = "BackupRestoreError";
  }
}

/** A backup that fails validation; the message is for the user. */
export class BackupFormatError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BackupFormatError";
  }
}

const fail = (message: string): never => {
  throw new BackupFormatError(message);
};

const two = (v: number): string => String(v).padStart(2, "0");

export function backupFilename(now: Date = new Date()): string {
  return `skippy-backup-${now.getFullYear()}-${two(now.getMonth() + 1)}-${two(now.getDate())}.zip`;
}

function safeName(filename: string): string {
  const cleaned = filename.replace(/[/\\\x00-\x1f]/g, "_").trim();
  return cleaned || "file";
}

/** One zip of every supplied (owned) workspace. Memberships are never serialized. */
export async function createBackupArchive(input: {
  workspaces: readonly Workspace[];
  notes: readonly Note[];
  labels: readonly Label[];
  stages: readonly Stage[];
  readAttachment: AttachmentReader;
  now?: Date;
  onProgress?: BackupProgress;
}): Promise<Uint8Array> {
  const zip = new JSZip();
  const total = input.notes.reduce((n, note) => n + note.attachments.length, 0);
  let completed = 0;
  const byPosition = <T extends { position: number }>(a: T, b: T): number => a.position - b.position;
  const workspaceDocs: Record<string, unknown>[] = [];

  for (const [workspaceIndex, workspace] of input.workspaces.entries()) {
    const labels = input.labels.filter((l) => l.workspaceId === workspace.id).sort(byPosition);
    const stages = input.stages.filter((s) => s.workspaceId === workspace.id).sort(byPosition);
    const notes = input.notes.filter((n) => n.workspaceId === workspace.id).sort(byPosition);
    const noteDocs: Record<string, unknown>[] = [];
    for (const [noteIndex, note] of notes.entries()) {
      const attachmentDocs: Record<string, unknown>[] = [];
      for (const [attachmentIndex, attachment] of note.attachments.entries()) {
        const bytes = await input.readAttachment(attachment);
        const path = `files/${workspaceIndex}/${noteIndex}/${attachmentIndex}-${safeName(attachment.filename)}`;
        zip.file(path, bytes);
        attachmentDocs.push({ path, filename: attachment.filename, mime: attachment.mime, size: bytes.length });
        completed++;
        input.onProgress?.(completed, total);
      }
      noteDocs.push({
        id: note.id,
        collection_id: note.collectionId,
        kind: note.kind,
        title: note.title,
        content: note.content,
        items: note.items.map((i) => ({ id: i.id, text: i.text, done: i.done })),
        color: note.color,
        pattern: note.pattern,
        pinned: note.pinned,
        archived: note.archived,
        trashed: note.trashed,
        position: note.position,
        grid_span: note.gridSpan,
        stage_id: note.stageId,
        stage_position: note.stagePosition,
        reminder_at: note.reminderAt?.toISOString() ?? null,
        reminder_repeat: note.reminderRepeat,
        item_reminders: orderedItemReminders(note).map(itemReminderToJson),
        created_at: note.createdAt.toISOString(),
        updated_at: note.updatedAt.toISOString(),
        label_ids: [...note.labelIds],
        attachments: attachmentDocs,
      });
    }
    workspaceDocs.push({
      id: workspace.id,
      name: workspace.name,
      is_default: workspace.isDefault,
      notes_enabled: workspace.notesEnabled,
      board_enabled: workspace.boardEnabled,
      ai: aiSwitchesToJson(workspace.ai.switches),
      collections: workspace.collections.map(collectionToJson),
      smart_views: workspace.savedViews.map(savedViewToJson),
      labels: labels.map((l) => ({ id: l.id, name: l.name, color: l.color, icon: l.icon, position: l.position })),
      stages: stages.map((s) => ({ id: s.id, collection_id: s.collectionId, name: s.name, color: s.color, position: s.position })),
      notes: noteDocs,
    });
  }

  const manifest = JSON.stringify(
    {
      format: BACKUP_FORMAT,
      version: BACKUP_VERSION,
      exported_at: (input.now ?? new Date()).toISOString(),
      workspaces: workspaceDocs,
    },
    null,
    2,
  );
  zip.file(MANIFEST, manifest);
  return zip.generateAsync({ type: "uint8array", compression: "DEFLATE" });
}

// -- reading ----------------------------------------------------------------

type Entries = Map<string, Uint8Array>;

function list(value: unknown, field: string): unknown[] {
  return Array.isArray(value) ? value : fail(`Backup ${field} is invalid`);
}

function map(value: unknown, field: string): Record<string, unknown> {
  return asObject(value) ?? fail(`Backup ${field} is invalid`);
}

function requiredString(m: Record<string, unknown>, key: string, max: number): string {
  const value = m[key];
  if (typeof value !== "string" || value === "" || value.length > max) {
    fail(`Backup ${key} is invalid`);
  }
  return value as string;
}

function text(value: unknown, max: number, fallback = ""): string {
  if (value === null || value === undefined) {
    return fallback;
  }
  if (typeof value !== "string" || value.length > max) {
    fail("Backup text field is invalid");
  }
  return value as string;
}

function optionalString(value: unknown, max: number): string | null {
  return value === null || value === undefined ? null : text(value, max);
}

function number(value: unknown, fallback: number | null): number {
  if ((value === null || value === undefined) && fallback !== null) {
    return fallback;
  }
  if (typeof value !== "number" || !Number.isFinite(value)) {
    fail("Backup number field is invalid");
  }
  return value as number;
}

function requiredDate(value: unknown): Date {
  const parsed = typeof value === "string" ? new Date(value) : null;
  if (!parsed || Number.isNaN(parsed.getTime())) {
    fail("Backup date is invalid");
  }
  return parsed as Date;
}

const optionalDate = (value: unknown): Date | null => (value === null || value === undefined ? null : requiredDate(value));

export async function parseBackupArchive(bytes: Uint8Array): Promise<BackupBundle> {
  if (bytes.length === 0 || bytes.length > MAX_BACKUP_ARCHIVE_BYTES) {
    fail("Backup must be a non-empty zip under 512 MB");
  }
  let zip: JSZip;
  try {
    zip = await JSZip.loadAsync(bytes);
  } catch {
    return fail("This file is not a readable Skippy backup");
  }
  const entries: Entries = new Map();
  let expandedBytes = 0;
  for (const entry of Object.values(zip.files)) {
    if (entry.dir) {
      continue;
    }
    if (entries.has(entry.name)) {
      fail("Backup contains duplicate file paths");
    }
    const content = await entry.async("uint8array");
    expandedBytes += content.length;
    if (expandedBytes > MAX_BACKUP_ARCHIVE_BYTES) {
      fail("Expanded backup is larger than 512 MB");
    }
    entries.set(entry.name, content);
  }
  const manifestBytes = entries.get(MANIFEST);
  if (!manifestBytes || manifestBytes.length > MAX_MANIFEST_BYTES) {
    fail("Backup manifest is missing or too large");
  }
  let manifest: Record<string, unknown>;
  try {
    manifest = map(JSON.parse(new TextDecoder().decode(manifestBytes)), "manifest");
  } catch {
    return fail("Backup manifest is invalid");
  }
  if (manifest.format !== BACKUP_FORMAT) {
    fail("Unsupported Skippy backup version");
  }
  const version = manifest.version;
  if (version === 1) {
    return parseLegacyBackup(manifest, entries);
  }
  if (version !== 2 && version !== BACKUP_VERSION) {
    fail("Unsupported Skippy backup version");
  }

  const rawWorkspaces = list(manifest.workspaces, "workspaces");
  if (rawWorkspaces.length === 0 || rawWorkspaces.length > MAX_WORKSPACES) {
    fail("Backup contains an invalid workspace list");
  }
  const usedFiles = new Set<string>([MANIFEST]);
  const workspaceIds = new Set<string>();
  const workspaces: BackupWorkspace[] = [];
  let noteCount = 0;
  let labelCount = 0;
  let stageCount = 0;
  let attachmentCount = 0;
  let defaultCount = 0;

  for (const rawWorkspace of rawWorkspaces) {
    const m = map(rawWorkspace, "workspace");
    const id = requiredString(m, "id", 200);
    const name = requiredString(m, "name", 60).trim();
    const isDefault = m.is_default === true;
    const notesEnabled = m.notes_enabled !== false;
    const boardEnabled = m.board_enabled !== false;
    if (!name || workspaceIds.has(id)) {
      fail("Backup contains an invalid workspace");
    }
    workspaceIds.add(id);
    if (!notesEnabled && !boardEnabled) {
      fail("Backup contains a workspace with no enabled view");
    }
    if (isDefault && ++defaultCount > 1) {
      fail("Backup contains multiple default workspaces");
    }
    const parsed = parseWorkspaceContents(m, entries, usedFiles, "current");
    const collections = readCollections(m.collections, id, notesEnabled ? "masonry" : "board");
    const collectionIds = new Set(collections.map((c) => c.id));
    for (const stage of parsed.stages) {
      if (stage.collectionId !== null && !collectionIds.has(stage.collectionId)) {
        fail("Board column belongs to a missing collection");
      }
    }
    for (const note of parsed.notes) {
      if (!note.trashed && note.collectionId !== null && !collectionIds.has(note.collectionId)) {
        fail("Note belongs to a missing collection");
      }
      if (
        note.stageId !== null &&
        note.collectionId !== null &&
        parsed.stages.some((s) => s.id === note.stageId && s.collectionId !== note.collectionId)
      ) {
        fail("Board column belongs to a different collection");
      }
    }
    noteCount += parsed.notes.length;
    labelCount += parsed.labels.length;
    stageCount += parsed.stages.length;
    attachmentCount += workspaceAttachmentCount(parsed);
    if (noteCount > MAX_NOTES || labelCount > MAX_LABELS || stageCount > MAX_STAGES || attachmentCount > MAX_ATTACHMENTS) {
      fail("Backup contains too much workspace data");
    }
    workspaces.push({
      ...parsed,
      id,
      name,
      isDefault,
      notesEnabled,
      boardEnabled,
      aiSwitches: parseAiSwitches(m.ai),
      savedViews: readSavedViews(m.smart_views),
      collections,
    });
  }
  if ([...entries.keys()].some((path) => !usedFiles.has(path))) {
    fail("Backup contains unreferenced files");
  }
  return { workspaces };
}

function parseLegacyBackup(manifest: Record<string, unknown>, entries: Entries): BackupBundle {
  const usedFiles = new Set<string>([MANIFEST]);
  const parsed = parseWorkspaceContents({ labels: manifest.labels, stages: [], notes: manifest.notes }, entries, usedFiles, "legacy");
  if (parsed.notes.length > MAX_NOTES || parsed.labels.length > MAX_LABELS || workspaceAttachmentCount(parsed) > MAX_ATTACHMENTS) {
    fail("Backup contains too much workspace data");
  }
  if ([...entries.keys()].some((path) => !usedFiles.has(path))) {
    fail("Backup contains unreferenced files");
  }
  return { workspaces: [{ ...parsed, id: "legacy-default", name: "My notes", isDefault: true, stages: [] }] };
}

const VALID_KINDS = new Set(["text", "markdown", "checklist", "audio"]);

/** Whether label positions may be absent (version 1 had none). */
type ManifestEra = "legacy" | "current";

function parseWorkspaceContents(m: Record<string, unknown>, entries: Entries, usedFiles: Set<string>, era: ManifestEra): BackupWorkspace {
  const rawLabels = list(m.labels, "labels");
  const rawStages = list(m.stages, "stages");
  const rawNotes = list(m.notes, "notes");

  const labels: BackupLabel[] = [];
  const labelIds = new Set<string>();
  for (const raw of rawLabels) {
    const label = map(raw, "label");
    const id = requiredString(label, "id", 200);
    const name = requiredString(label, "name", 100).trim();
    if (!name || labelIds.has(id)) {
      fail("Backup contains an invalid label");
    }
    labelIds.add(id);
    labels.push({
      id,
      name,
      color: optionalString(label.color, 32),
      icon: optionalString(label.icon, 64),
      position: number(label.position, era === "legacy" ? 0 : null),
    });
  }

  const stages: BackupStage[] = [];
  const stageIds = new Set<string>();
  for (const raw of rawStages) {
    const stage = map(raw, "stage");
    const id = requiredString(stage, "id", 200);
    const name = requiredString(stage, "name", 100).trim();
    if (!name || stageIds.has(id)) {
      fail("Backup contains an invalid board column");
    }
    stageIds.add(id);
    stages.push({
      collectionId: optionalString(stage.collection_id, 200),
      id,
      name,
      color: optionalString(stage.color, 32),
      position: number(stage.position, null),
    });
  }

  const notes: BackupNote[] = [];
  for (const raw of rawNotes) {
    const note = map(raw, "note");
    const rawKind = requiredString(note, "kind", 20);
    if (!VALID_KINDS.has(rawKind)) {
      fail("Backup contains an unknown note type");
    }
    const rawItems = list(note.items, "items");
    // Absent in a backup written before item reminders existed.
    const rawItemReminders = note.item_reminders == null ? [] : list(note.item_reminders, "item_reminders");
    const rawLabelIds = list(note.label_ids, "label_ids");
    const rawAttachments = list(note.attachments, "attachments");

    const attachments: BackupAttachment[] = [];
    for (const rawAttachment of rawAttachments) {
      const attachment = map(rawAttachment, "attachment");
      const path = requiredString(attachment, "path", 500);
      const entry = entries.get(path);
      if (!entry || !path.startsWith("files/") || usedFiles.has(path)) {
        fail("Backup attachment data is missing");
      }
      usedFiles.add(path);
      const content = entry as Uint8Array;
      if (content.length > MAX_UPLOAD_BYTES) {
        fail("A backup attachment exceeds 25 MB");
      }
      const declaredSize = attachment.size;
      if (typeof declaredSize !== "number" || Math.trunc(declaredSize) !== content.length) {
        fail("Backup attachment size does not match");
      }
      attachments.push({
        filename: requiredString(attachment, "filename", 255),
        mime: requiredString(attachment, "mime", 200),
        bytes: content,
      });
    }

    const stageId = optionalString(note.stage_id, 200);
    const itemReminders: ItemReminder[] = [];
    for (const rawReminder of rawItemReminders) {
      const reminder = parseItemReminder(map(rawReminder, "item reminder"));
      if (reminder) {
        itemReminders.push(reminder);
      }
    }
    notes.push({
      collectionId: optionalString(note.collection_id, 200),
      id: requiredString(note, "id", 200),
      kind: noteKindFromWire(rawKind),
      title: text(note.title, 100_000),
      content: text(note.content, 10_000_000),
      items: rawItems.map((rawItem) => {
        const item = map(rawItem, "checklist item");
        return { id: text(item.id, 200), text: text(item.text, 100_000), done: item.done === true };
      }),
      color: text(note.color, 64, "default"),
      pattern: notePatternFromWire(optionalString(note.pattern, 32)),
      pinned: note.pinned === true,
      archived: note.archived === true,
      trashed: note.trashed === true,
      position: number(note.position, 0),
      gridSpan: Math.min(Math.max(Math.trunc(number(note.grid_span, 1)), 1), 3),
      stageId: stageId !== null && stageIds.has(stageId) ? stageId : null,
      stagePosition: number(note.stage_position, 0),
      reminderAt: optionalDate(note.reminder_at),
      reminderRepeat: reminderRepeatFromWire(optionalString(note.reminder_repeat, 32)),
      itemReminders,
      createdAt: requiredDate(note.created_at),
      updatedAt: requiredDate(note.updated_at),
      labelIds: rawLabelIds.filter((v): v is string => typeof v === "string" && labelIds.has(v)),
      attachments,
    });
  }

  return {
    collections: [],
    savedViews: [],
    id: "",
    name: "",
    isDefault: false,
    notesEnabled: true,
    boardEnabled: true,
    aiSwitches: DEFAULT_AI_SWITCHES,
    labels,
    stages,
    notes,
  };
}

function readSavedViews(raw: unknown): SavedView[] {
  if (raw === null || raw === undefined) {
    return [];
  }
  if (!Array.isArray(raw) || raw.length > MAX_SMART_VIEWS) {
    fail("Invalid smart views");
  }
  const ids = new Set<string>();
  return (raw as unknown[]).map((entry) => {
    const view = asObject(entry) ? parseSavedView(entry) : null;
    if (!view || ids.has(view.id) || !Number.isFinite(view.position) || view.id.length > 128 || view.name.length > 240 || view.query.length > 4096) {
      return fail("Invalid smart view");
    }
    ids.add(view.id);
    return view;
  });
}

const VALID_LAYOUTS = new Set(["masonry", "list", "board"]);
const VALID_SORTS = new Set(["custom", "edited", "newest", "oldest"]);

function readCollections(raw: unknown, workspaceId: string, legacyLayout: string): NoteCollection[] {
  if (raw === null || raw === undefined) {
    return [generalCollection(workspaceId, legacyLayout)];
  }
  if (!Array.isArray(raw) || raw.length > MAX_COLLECTIONS) {
    fail("Invalid collections");
  }
  const ids = new Set<string>();
  return (raw as unknown[]).map((value) => {
    const c = parseCollection({ ...map(value, "collection"), workspace_id: workspaceId });
    if (
      !c.id ||
      ids.has(c.id) ||
      !c.name.trim() ||
      c.name.length > 60 ||
      !VALID_LAYOUTS.has(c.layout) ||
      !VALID_SORTS.has(c.sort) ||
      !Number.isFinite(c.position)
    ) {
      return fail("Invalid collection settings");
    }
    ids.add(c.id);
    return c;
  });
}

