// File type helpers. Ported from `util/mime.dart`.

/** Client-side upload cap; the server allows 30 MB so this one is what shows. */
export const MAX_UPLOAD_BYTES = 25 * 1024 * 1024;

const MIME_BY_EXTENSION: ReadonlyArray<readonly [string, string]> = [
  ["png", "image/png"],
  ["jpg", "image/jpeg"],
  ["jpeg", "image/jpeg"],
  ["gif", "image/gif"],
  ["webp", "image/webp"],
  ["pdf", "application/pdf"],
  ["txt", "text/plain"],
  ["md", "text/markdown"],
  ["csv", "text/csv"],
  ["json", "application/json"],
  ["zip", "application/zip"],
  ["mp3", "audio/mpeg"],
  ["m4a", "audio/mp4"],
  ["wav", "audio/wav"],
  ["mp4", "video/mp4"],
  ["doc", "application/msword"],
  ["docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"],
  ["xls", "application/vnd.ms-excel"],
  ["xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"],
];

export function mimeFromName(name: string): string {
  const dot = name.lastIndexOf(".");
  const ext = dot < 0 ? "" : name.slice(dot + 1).toLowerCase();
  return MIME_BY_EXTENSION.find(([e]) => e === ext)?.[1] ?? "application/octet-stream";
}

/** A file extension (no dot) for a mime type, or null. */
export function extensionFromMime(mime: string): string | null {
  const lower = mime.trim().toLowerCase();
  const known = MIME_BY_EXTENSION.find(([, m]) => m === lower);
  if (known) {
    return known[0];
  }
  const subtype = (lower.split("/").pop() ?? "").split("+")[0] ?? "";
  return /^[a-z0-9]{1,5}$/.test(subtype) ? subtype : null;
}

// Names browsers give clipboard content that has no name of its own.
const GENERIC_PASTED_NAMES = new Set(["image", "file", "blob", "unknown"]);

function pad(value: number): string {
  return String(value).padStart(2, "0");
}

function stampedFileName(prefix: string, mime: string, at?: Date): string {
  const ext = extensionFromMime(mime);
  const t = at ?? new Date();
  const stamp =
    `${t.getFullYear()}${pad(t.getMonth() + 1)}${pad(t.getDate())}` +
    `-${pad(t.getHours())}${pad(t.getMinutes())}${pad(t.getSeconds())}`;
  return `${prefix}-${stamp}${ext === null ? "" : `.${ext}`}`;
}

/** Filename for something pasted onto a note. */
export function pastedFileName(mime: string, suggested?: string, at?: Date): string {
  const name = (suggested ?? "").trim();
  const dot = name.lastIndexOf(".");
  const stem = (dot <= 0 ? name : name.slice(0, dot)).toLowerCase();
  if (name && !GENERIC_PASTED_NAMES.has(stem)) {
    return name;
  }
  return stampedFileName("pasted", mime, at);
}

/** "812 KB", "2.4 MB" (binary units, as the attachment tiles show). */
export function formatBytes(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(0)} KB`;
  }
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/** Files that fit under the upload cap. */
export function withinUploadLimit<T extends { readonly size: number }>(files: readonly T[]): T[] {
  return files.filter((f) => f.size <= MAX_UPLOAD_BYTES);
}
