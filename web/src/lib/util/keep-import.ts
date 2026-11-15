import JSZip from "jszip";
import type { NoteKind } from "@/lib/models/note";
import { asArray, asObject, str } from "@/lib/util/json";
import { MAX_BACKUP_ARCHIVE_BYTES } from "./backup";
import { MAX_UPLOAD_BYTES, mimeFromName } from "./mime";

// Reads a Google Takeout export of Keep: a zip holding one JSON file per note
// next to the files attached to it. Ported from `util/keep_import.dart`.
//
//     Takeout/Keep/Shopping.json   {"title", "textContent" | "listContent",
//     Takeout/Keep/1a2b.jpg         "color", "isPinned", "labels", ...}

const MAX_NOTES = 10_000;
const MICROS_PER_MS = 1000;

/** Keep's note colours, by the nearest one Skippy has. */
const COLORS: Record<string, string> = {
  RED: "red",
  PINK: "red",
  ORANGE: "orange",
  BROWN: "orange",
  YELLOW: "yellow",
  GREEN: "green",
  TEAL: "teal",
  BLUE: "blue",
  CERULEAN: "blue",
  PURPLE: "blue",
  GRAY: "gray",
};

export interface KeepItem {
  readonly text: string;
  readonly done: boolean;
}

export interface KeepAttachment {
  readonly filename: string;
  readonly mime: string;
  readonly bytes: Uint8Array;
}

export interface KeepNote {
  readonly title: string;
  readonly kind: NoteKind;
  readonly content: string;
  readonly items: readonly KeepItem[];
  readonly color: string;
  readonly pinned: boolean;
  readonly archived: boolean;
  readonly trashed: boolean;
  readonly createdAt: Date;
  readonly updatedAt: Date;
  readonly labels: readonly string[];
  readonly attachments: readonly KeepAttachment[];
}

export interface KeepArchive {
  readonly notes: readonly KeepNote[];
  /** Attachments a note names that are missing from the zip or too large. */
  readonly missingFiles: number;
}

/** Whether an import brings along the notes that were in Keep's trash. */
export type KeepTrash = "skip" | "include";

export interface KeepImportResult {
  readonly notes: number;
  readonly attachments: number;
  /** Labels created because the workspace had none by that name. */
  readonly labels: number;
}

/** Thrown for an archive that cannot be imported; the message is for the user. */
export class ImportFormatError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ImportFormatError";
  }
}

function split(path: string): [string, string] {
  const slash = path.lastIndexOf("/");
  return slash < 0 ? ["", path] : [path.slice(0, slash), path.slice(slash + 1)];
}

function stem(name: string): string {
  const dot = name.lastIndexOf(".");
  return dot < 0 ? name : name.slice(0, dot);
}

function time(microseconds: unknown): Date | null {
  if (typeof microseconds !== "number" || microseconds <= 0) {
    return null;
  }
  return new Date(Math.trunc(microseconds / MICROS_PER_MS));
}

export async function parseKeepArchive(bytes: Uint8Array): Promise<KeepArchive> {
  if (bytes.length === 0 || bytes.length > MAX_BACKUP_ARCHIVE_BYTES) {
    throw new ImportFormatError("The export must be a zip under 512 MB");
  }
  let zip: JSZip;
  try {
    zip = await JSZip.loadAsync(bytes);
  } catch {
    throw new ImportFormatError("This file is not a readable zip");
  }

  // Files by folder, then name, so a note only picks up its own attachments.
  const folders = new Map<string, Map<string, JSZip.JSZipObject>>();
  const noteFiles: JSZip.JSZipObject[] = [];
  for (const entry of Object.values(zip.files)) {
    if (entry.dir) {
      continue;
    }
    const [folder, name] = split(entry.name);
    const files = folders.get(folder) ?? new Map<string, JSZip.JSZipObject>();
    files.set(name, entry);
    folders.set(folder, files);
    if (name.toLowerCase().endsWith(".json")) {
      noteFiles.push(entry);
    }
  }

  let expandedBytes = 0;
  const account = (size: number): void => {
    expandedBytes += size;
    if (expandedBytes > MAX_BACKUP_ARCHIVE_BYTES) {
      throw new ImportFormatError("The unpacked export is larger than 512 MB");
    }
  };

  const notes: KeepNote[] = [];
  let missingFiles = 0;
  for (const file of noteFiles) {
    const text = await file.async("string");
    account(text.length);
    const json = decodeNote(text);
    if (!json) {
      continue;
    }
    if (notes.length === MAX_NOTES) {
      throw new ImportFormatError("The export has more than 10,000 notes");
    }
    const folder = folders.get(split(file.name)[0]) ?? new Map<string, JSZip.JSZipObject>();
    const attachments: KeepAttachment[] = [];
    for (const raw of asArray(json.attachments)) {
      const attachment = await readAttachment(raw, folder, account);
      if (!attachment) {
        missingFiles++;
        continue;
      }
      attachments.push(attachment);
    }
    notes.push(toNote(json, attachments));
  }
  if (notes.length === 0) {
    throw new ImportFormatError("No Google Keep notes were found in this zip");
  }
  return { notes, missingFiles };
}

/** The note in [text], or null when it is not a Keep note. */
function decodeNote(text: string): Record<string, unknown> | null {
  let decoded: unknown;
  try {
    decoded = JSON.parse(text);
  } catch {
    return null;
  }
  const map = asObject(decoded);
  if (!map) {
    return null;
  }
  const isKeep = "isTrashed" in map && ("textContent" in map || "listContent" in map);
  return isKeep ? map : null;
}

function toNote(json: Record<string, unknown>, attachments: KeepAttachment[]): KeepNote {
  const isList = "listContent" in json;
  const updatedAt = time(json.userEditedTimestampUsec) ?? new Date();
  // Keep keeps a note's web links beside its text; Skippy finds them in it.
  let content = isList ? "" : str(json.textContent);
  for (const annotation of asArray(json.annotations)) {
    const url = asObject(annotation)?.url;
    if (typeof url === "string" && !content.includes(url)) {
      content = content ? `${content}\n\n${url}` : url;
    }
  }
  const items: KeepItem[] = [];
  for (const raw of asArray(json.listContent)) {
    const item = asObject(raw);
    if (item) {
      items.push({ text: str(item.text), done: item.isChecked === true });
    }
  }
  const labels: string[] = [];
  for (const raw of asArray(json.labels)) {
    const name = str(asObject(raw)?.name).trim();
    if (name) {
      labels.push(name);
    }
  }
  return {
    title: str(json.title),
    kind: isList ? "checklist" : "text",
    content,
    items,
    color: COLORS[str(json.color)] ?? "default",
    pinned: json.isPinned === true,
    archived: json.isArchived === true,
    trashed: json.isTrashed === true,
    createdAt: time(json.createdTimestampUsec) ?? updatedAt,
    updatedAt,
    labels,
    attachments,
  };
}

/** The file a Keep attachment names, found beside its note (`.jpeg` may be `.jpg`). */
async function readAttachment(raw: unknown, folder: Map<string, JSZip.JSZipObject>, account: (size: number) => void): Promise<KeepAttachment | null> {
  const map = asObject(raw);
  if (!map) {
    return null;
  }
  const path = str(map.filePath);
  if (!path) {
    return null;
  }
  let file = folder.get(path);
  if (!file) {
    const wanted = stem(path);
    for (const [key, value] of folder) {
      if (stem(key) === wanted && !key.toLowerCase().endsWith(".json")) {
        file = value;
        break;
      }
    }
  }
  if (!file) {
    return null;
  }
  const bytes = await file.async("uint8array");
  account(bytes.length);
  if (bytes.length > MAX_UPLOAD_BYTES) {
    return null;
  }
  const declared = str(map.mimetype);
  return { filename: split(file.name)[1], mime: declared || mimeFromName(file.name), bytes };
}
