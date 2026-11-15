import { asArray, asObject, bool, clamp, num, optNum, optStr, parseDate, str, strings, type JsonObject } from "@/lib/util/json";

// Domain types for notes and their parts, with the wire parsers and
// serializers. Ported from `app/lib/models/note.dart`; the wire semantics
// (omitted vs null, clamps, fallbacks) are kept exactly.

export const NOTE_KINDS = ["text", "checklist", "markdown", "audio"] as const;
export type NoteKind = (typeof NOTE_KINDS)[number];

/** Unknown kinds read as text, as in Dart. */
export function noteKindFromWire(value: unknown): NoteKind {
  switch (value) {
    case "checklist":
    case "markdown":
    case "audio":
      return value;
    default:
      return "text";
  }
}

/** The texture drawn under a note, chosen beside its colour. */
export const NOTE_PATTERNS = [
  { id: "none", label: "Plain" },
  { id: "dots", label: "Dots" },
  { id: "grid", label: "Grid" },
  { id: "lines", label: "Lines" },
  { id: "diagonal", label: "Diagonal" },
  { id: "checks", label: "Checks" },
  { id: "airplanes", label: "Airplanes" },
  { id: "cars", label: "Cars" },
  { id: "notes", label: "Notes" },
  { id: "ideas", label: "Ideas" },
  { id: "hearts", label: "Hearts" },
  { id: "stars", label: "Stars" },
  { id: "coffee", label: "Coffee" },
  { id: "leaves", label: "Leaves" },
  { id: "weather", label: "Weather" },
  { id: "music", label: "Music" },
  { id: "paws", label: "Paws" },
  { id: "space", label: "Space" },
  { id: "sea", label: "Sea" },
  { id: "food", label: "Food" },
] as const;
export type NotePattern = (typeof NOTE_PATTERNS)[number]["id"];

/** An unknown value, from a newer client, draws plain rather than failing. */
export function notePatternFromWire(value: unknown): NotePattern {
  return NOTE_PATTERNS.find((p) => p.id === value)?.id ?? "none";
}

/** Optional cadence for a reminder; null means one-shot. */
export const REMINDER_REPEATS = [
  { id: "daily", label: "Every day" },
  { id: "weekly", label: "Every week" },
  { id: "monthly", label: "Every month" },
  { id: "yearly", label: "Every year" },
] as const;
export type ReminderRepeat = (typeof REMINDER_REPEATS)[number]["id"];

export function reminderRepeatFromWire(value: unknown): ReminderRepeat | null {
  return REMINDER_REPEATS.find((r) => r.id === value)?.id ?? null;
}

/** One user-configurable AI action shown in note menus. */
export interface NoteRewriteTask {
  readonly id: string;
  readonly name: string;
  readonly prompt: string;
}

export function parseRewriteTask(json: unknown): NoteRewriteTask | null {
  const map = asObject(json);
  if (!map) {
    return null;
  }
  const id = str(map.id).trim();
  const name = str(map.name).trim();
  const prompt = str(map.prompt).trim();
  if (!id || !name || !prompt) {
    return null;
  }
  return { id, name, prompt };
}

export const DEFAULT_REWRITE_TASKS: readonly NoteRewriteTask[] = [
  {
    id: "concise",
    name: "Make concise",
    prompt:
      "Clean up this note and make it concise. Preserve every important fact, intent, and task; do not add new information.",
  },
  {
    id: "grammar",
    name: "Fix grammar",
    prompt:
      "Fix grammar, spelling, punctuation, and syntax only. Do not summarize, rephrase for style, add information, remove information, or change tone.",
  },
];

/** Deepest a checklist row may be nested (three levels). Mirrors the backend. */
export const MAX_ITEM_DEPTH = 2;

export interface ChecklistItem {
  readonly id: string;
  readonly text: string;
  readonly done: boolean;
  /** Nesting level, 0 for a top-level task. */
  readonly depth: number;
}

export function parseChecklistItem(json: unknown): ChecklistItem {
  const map = asObject(json) ?? {};
  return {
    id: str(map.id),
    text: str(map.text),
    done: bool(map.done),
    // Absent for a row written before subtasks existed, which is what it was.
    depth: clamp(Math.trunc(num(map.depth)), 0, MAX_ITEM_DEPTH),
  };
}

export function checklistItemToJson(item: ChecklistItem): JsonObject {
  const json: JsonObject = { id: item.id, text: item.text, done: item.done };
  // Omitted at the top level, matching the server.
  if (item.depth > 0) {
    json.depth = item.depth;
  }
  return json;
}

export function itemsToJson(items: readonly ChecklistItem[]): JsonObject[] {
  return items.map(checklistItemToJson);
}

/** A reminder on one checklist item. Lives beside the items, never inside. */
export interface ItemReminder {
  readonly itemId: string;
  readonly at: Date;
  readonly repeat: ReminderRepeat | null;
}

export function parseItemReminder(json: unknown): ItemReminder | null {
  const map = asObject(json);
  if (!map) {
    return null;
  }
  const itemId = str(map.item_id).trim();
  const at = parseDate(map.reminder_at);
  if (!itemId || !at) {
    return null;
  }
  return { itemId, at, repeat: reminderRepeatFromWire(map.reminder_repeat) };
}

export function itemReminderToJson(reminder: ItemReminder): JsonObject {
  return {
    item_id: reminder.itemId,
    reminder_at: reminder.at.toISOString(),
    reminder_repeat: reminder.repeat,
  };
}

export function parseItemReminders(json: unknown): Record<string, ItemReminder> {
  const parsed: Record<string, ItemReminder> = {};
  for (const entry of asArray(json)) {
    const reminder = parseItemReminder(entry);
    if (reminder) {
      parsed[reminder.itemId] = reminder;
    }
  }
  return parsed;
}

export function itemRemindersToJson(reminders: Readonly<Record<string, ItemReminder>>): JsonObject[] {
  return Object.values(reminders).map(itemReminderToJson);
}

export interface UserRef {
  readonly id: string;
  readonly name: string;
}

export function parseUserRef(json: unknown): UserRef {
  const map = asObject(json) ?? {};
  // Old caches carried `username`.
  return { id: str(map.id), name: str(map.name, str(map.username)) };
}

export function userRefToJson(user: UserRef): JsonObject {
  return { id: user.id, name: user.name };
}

export interface Attachment {
  readonly id: string;
  readonly mime: string;
  readonly filename: string;
  readonly size: number;
  /** Signed, time-limited path from the server; null for a local one. */
  readonly url: string | null;
  /** Text the server read out of the picture; empty for everything else. */
  readonly ocrText: string;
}

export const isImageAttachment = (a: Attachment): boolean => a.mime.startsWith("image/");
export const isAudioAttachment = (a: Attachment): boolean => a.mime.startsWith("audio/");

export function parseAttachment(json: unknown): Attachment {
  const map = asObject(json) ?? {};
  return {
    id: str(map.id),
    mime: str(map.mime),
    filename: str(map.filename),
    size: Math.trunc(num(map.size)),
    url: optStr(map.url),
    ocrText: str(map.ocr_text),
  };
}

export function attachmentToJson(a: Attachment): JsonObject {
  const json: JsonObject = { id: a.id, mime: a.mime, filename: a.filename, size: a.size };
  if (a.url !== null) {
    json.url = a.url;
  }
  if (a.ocrText) {
    json.ocr_text = a.ocrText;
  }
  return json;
}

/** Audio transcription state, server-owned. */
export type TranscriptStatus = "none" | "pending" | "done" | "failed" | (string & {});

export interface Note {
  readonly id: string;
  /** The workspace holding this note; empty only for a pre-workspace cache. */
  readonly workspaceId: string;
  readonly collectionId: string | null;
  readonly kind: NoteKind;
  readonly title: string;
  readonly content: string;
  readonly items: readonly ChecklistItem[];
  readonly color: string;
  readonly pattern: NotePattern;
  readonly pinned: boolean;
  readonly archived: boolean;
  readonly trashed: boolean;
  readonly position: number;
  /** 1..3 grid columns. */
  readonly gridSpan: number;
  /** The board column, or null for unassigned. At most one. */
  readonly stageId: string | null;
  /** Order within the column; separate from [position]. */
  readonly stagePosition: number;
  readonly reminderAt: Date | null;
  readonly reminderRepeat: ReminderRepeat | null;
  /** Reminders on checklist items, keyed by item id. Read-only on the wire. */
  readonly itemReminders: Readonly<Record<string, ItemReminder>>;
  readonly transcriptStatus: TranscriptStatus;
  /** True only while the server is generating automatic link summaries. */
  readonly summarizingLinks: boolean;
  readonly createdAt: Date;
  readonly updatedAt: Date;
  /** A set, kept as an array in insertion order. */
  readonly labelIds: readonly string[];
  readonly owner: UserRef | null;
  readonly collaborators: readonly UserRef[];
  readonly attachments: readonly Attachment[];
}

const EMPTY_REMINDERS: Readonly<Record<string, ItemReminder>> = Object.freeze({});

/** A note with every field defaulted the way the Dart constructor does. */
export function makeNote(fields: Partial<Note> & { id: string }): Note {
  const now = new Date();
  return {
    workspaceId: "",
    collectionId: null,
    kind: "text",
    title: "",
    content: "",
    items: [],
    color: "default",
    pattern: "none",
    pinned: false,
    archived: false,
    trashed: false,
    position: 0,
    gridSpan: 1,
    stageId: null,
    stagePosition: 0,
    reminderAt: null,
    reminderRepeat: null,
    itemReminders: EMPTY_REMINDERS,
    transcriptStatus: "none",
    summarizingLinks: false,
    createdAt: now,
    updatedAt: now,
    labelIds: [],
    owner: null,
    collaborators: [],
    attachments: [],
    ...fields,
  };
}

// The server's `updated_at` keeps microseconds, which a JS Date cannot. The
// conflict check (`if_unmodified_since`) compares at microsecond precision, so
// the exact wire string is remembered per parsed note.
const wireStamps = new WeakMap<Note, string>();

/** The `updated_at` exactly as the server wrote it, for conflict checks. */
export function noteServerStamp(note: Note): string {
  return wireStamps.get(note) ?? note.updatedAt.toISOString();
}

export function parseNote(json: unknown): Note {
  const map = asObject(json) ?? {};
  const position = optNum(map.position);
  const updatedRaw = str(map.updated_at);
  const note: Note = {
    id: str(map.id),
    workspaceId: str(map.workspace_id),
    collectionId: optStr(map.collection_id),
    kind: noteKindFromWire(map.kind),
    title: str(map.title),
    content: str(map.content),
    items: asArray(map.items).map(parseChecklistItem),
    color: str(map.color, "default"),
    pattern: notePatternFromWire(map.pattern),
    pinned: bool(map.pinned),
    archived: bool(map.archived),
    trashed: bool(map.trashed),
    position: position ?? 0,
    gridSpan: clamp(Math.trunc(num(map.grid_span, 1)), 1, 3),
    stageId: optStr(map.stage_id),
    // Absent for a cache written before boards existed.
    stagePosition: optNum(map.stage_position) ?? position ?? 0,
    reminderAt: parseDate(map.reminder_at),
    reminderRepeat: reminderRepeatFromWire(map.reminder_repeat),
    itemReminders: parseItemReminders(map.item_reminders),
    transcriptStatus: str(map.transcript_status, "none"),
    summarizingLinks: bool(map.summarizing_links),
    createdAt: parseDate(map.created_at) ?? new Date(),
    updatedAt: parseDate(updatedRaw) ?? new Date(),
    labelIds: [...new Set(strings(map.label_ids))],
    owner: map.owner == null ? null : parseUserRef(map.owner),
    collaborators: asArray(map.collaborators).map(parseUserRef),
    attachments: asArray(map.attachments).map(parseAttachment),
  };
  if (updatedRaw && parseDate(updatedRaw)) {
    wireStamps.set(note, updatedRaw);
  }
  return note;
}

/** Full serialization for the offline cache. `summarizing_links` is left out. */
export function noteToJson(note: Note): JsonObject {
  return {
    id: note.id,
    workspace_id: note.workspaceId,
    collection_id: note.collectionId,
    kind: note.kind,
    title: note.title,
    content: note.content,
    items: itemsToJson(note.items),
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
    item_reminders: itemRemindersToJson(note.itemReminders),
    transcript_status: note.transcriptStatus,
    created_at: note.createdAt.toISOString(),
    updated_at: noteServerStamp(note),
    label_ids: [...note.labelIds],
    owner: note.owner ? userRefToJson(note.owner) : null,
    collaborators: note.collaborators.map(userRefToJson),
    attachments: note.attachments.map(attachmentToJson),
  };
}

// Derived facts, ported from the Dart getters.

export const isChecklist = (note: Note): boolean => note.kind === "checklist";
export const isAudioNote = (note: Note): boolean => note.kind === "audio";
export const isTranscribing = (note: Note): boolean => note.transcriptStatus === "pending";
export const transcriptFailed = (note: Note): boolean => note.transcriptStatus === "failed";

/** The recorded clip of an audio note, if it has one. */
export function audioClip(note: Note): Attachment | null {
  return note.attachments.find(isAudioAttachment) ?? null;
}

/** Whether the note has no user-authored content. */
export function isNoteEmpty(note: Note): boolean {
  return (
    note.title.trim() === "" &&
    note.content.trim() === "" &&
    note.items.every((i) => i.text.trim() === "") &&
    note.attachments.length === 0
  );
}

/** Its own reminder, or one of its items'. */
export function hasReminder(note: Note): boolean {
  return note.reminderAt !== null || Object.keys(note.itemReminders).length > 0;
}

/** Whether closing the editor may silently remove it (store adds sharing). */
export function noteCanAutoDiscard(note: Note): boolean {
  return isNoteEmpty(note) && !hasReminder(note) && note.collaborators.length === 0;
}

export const isNoteShared = (note: Note): boolean => note.collaborators.length > 0;

/** Null owner means a local note, which is the caller's. */
export function isNoteOwnedBy(note: Note, userId: string | null | undefined): boolean {
  return note.owner === null || note.owner.id === userId;
}

/** The soonest reminder of either kind. */
export function nextReminderAt(note: Note): Date | null {
  let soonest = note.reminderAt;
  for (const reminder of Object.values(note.itemReminders)) {
    if (soonest === null || reminder.at.getTime() < soonest.getTime()) {
      soonest = reminder.at;
    }
  }
  return soonest;
}

/** Item reminders in list order. */
export function orderedItemReminders(note: Note): ItemReminder[] {
  const out: ItemReminder[] = [];
  for (const item of note.items) {
    const reminder = note.itemReminders[item.id];
    if (reminder) {
      out.push(reminder);
    }
  }
  return out;
}

/** A past state of a note's content. */
export interface NoteVersion {
  readonly id: string;
  readonly noteId: string;
  readonly kind: NoteKind;
  readonly title: string;
  readonly content: string;
  readonly items: readonly ChecklistItem[];
  /** Null for the original/legacy snapshot. */
  readonly editedBy: UserRef | null;
  readonly createdAt: Date;
}

export function parseNoteVersion(json: unknown): NoteVersion {
  const map = asObject(json) ?? {};
  return {
    id: str(map.id),
    noteId: str(map.note_id),
    kind: noteKindFromWire(map.kind),
    title: str(map.title),
    content: str(map.content),
    items: asArray(map.items).map(parseChecklistItem),
    editedBy: map.edited_by == null ? null : parseUserRef(map.edited_by),
    createdAt: parseDate(map.created_at) ?? new Date(),
  };
}

export interface Label {
  readonly id: string;
  readonly workspaceId: string;
  readonly name: string;
  /** `#RRGGBB`, or null for the theme default. */
  readonly color: string | null;
  /** Key into the curated icon set, or null. */
  readonly icon: string | null;
  readonly position: number;
}

export function parseLabel(json: unknown): Label {
  const map = asObject(json) ?? {};
  return {
    id: str(map.id),
    workspaceId: str(map.workspace_id),
    name: str(map.name),
    color: optStr(map.color),
    icon: optStr(map.icon),
    position: num(map.position),
  };
}

export function labelToJson(label: Label): JsonObject {
  const json: JsonObject = { id: label.id, workspace_id: label.workspaceId, name: label.name };
  if (label.color !== null) {
    json.color = label.color;
  }
  if (label.icon !== null) {
    json.icon = label.icon;
  }
  json.position = label.position;
  return json;
}

/** A board column. Independent of labels by design. */
export interface Stage {
  readonly id: string;
  readonly workspaceId: string;
  readonly collectionId: string | null;
  readonly name: string;
  readonly color: string | null;
  readonly position: number;
}

export function parseStage(json: unknown): Stage {
  const map = asObject(json) ?? {};
  return {
    id: str(map.id),
    workspaceId: str(map.workspace_id),
    collectionId: optStr(map.collection_id),
    name: str(map.name),
    color: optStr(map.color),
    position: num(map.position),
  };
}

export function stageToJson(stage: Stage): JsonObject {
  const json: JsonObject = {
    id: stage.id,
    workspace_id: stage.workspaceId,
    collection_id: stage.collectionId,
    name: stage.name,
  };
  if (stage.color !== null) {
    json.color = stage.color;
  }
  json.position = stage.position;
  return json;
}

export interface AuthUser {
  readonly id: string;
  readonly name: string;
  readonly email: string;
}

export function parseAuthUser(json: unknown): AuthUser {
  const map = asObject(json) ?? {};
  return { id: str(map.id), name: str(map.name, str(map.username)), email: str(map.email) };
}

export function authUserToJson(user: AuthUser): JsonObject {
  return { id: user.id, name: user.name, email: user.email };
}
