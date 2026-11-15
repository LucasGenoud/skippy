import type { Label, Note } from "@/lib/models/note";
import type { Workspace } from "@/lib/models/workspace";
import { plainNoteLinks } from "@/lib/state/note-links";

// Bulk note export to JSON, Markdown or plain text, and the one-note plain
// text the clipboard gets. Ported from `util/note_export.dart`.

export const EXPORT_FORMATS = [
  { id: "json", label: "JSON", extension: "json", mime: "application/json" },
  { id: "markdown", label: "Markdown", extension: "md", mime: "text/markdown" },
  { id: "text", label: "Plain text", extension: "txt", mime: "text/plain" },
] as const;
export type ExportFormat = (typeof EXPORT_FORMATS)[number]["id"];

const two = (v: number): string => String(v).padStart(2, "0");
const isoDay = (d: Date): string => `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())}`;

export function exportFormatSpec(format: ExportFormat): (typeof EXPORT_FORMATS)[number] {
  return EXPORT_FORMATS.find((f) => f.id === format) ?? EXPORT_FORMATS[0];
}

/** `skippy-2026-07-13.md`. */
export function exportFilename(format: ExportFormat, now: Date = new Date()): string {
  return `skippy-${isoDay(now)}.${exportFormatSpec(format).extension}`;
}

function labelNames(n: Note, names: ReadonlyMap<string, string>): string[] {
  return n.labelIds
    .map((id) => names.get(id))
    .filter((name): name is string => name !== undefined)
    .sort();
}

export function exportNotes(
  notes: readonly Note[],
  format: ExportFormat,
  options: { labels?: readonly Label[]; workspaces?: readonly Workspace[]; now?: Date } = {},
): string {
  const names = new Map((options.labels ?? []).map((l) => [l.id, l.name]));
  const workspaceNames = new Map((options.workspaces ?? []).map((w) => [w.id, w.name]));
  const now = options.now ?? new Date();
  switch (format) {
    case "json":
      return toJson(notes, names, workspaceNames, now);
    case "markdown":
      return toMarkdown(notes, names, workspaceNames, now);
    case "text":
      return toText(notes, names, workspaceNames);
  }
}

function toJson(notes: readonly Note[], names: ReadonlyMap<string, string>, workspaceNames: ReadonlyMap<string, string>, now: Date): string {
  const data = {
    exported_at: now.toISOString(),
    version: 1,
    notes: notes.map((n) => {
      const workspace = workspaceNames.get(n.workspaceId);
      return {
        id: n.id,
        ...(workspace !== undefined ? { workspace } : {}),
        kind: n.kind,
        title: n.title,
        content: n.content,
        items: n.items.map((i) => {
          const reminder = n.itemReminders[i.id];
          // Inline: this export drops item ids, so the reminder travels with its row.
          return {
            text: i.text,
            done: i.done,
            ...(reminder ? { reminder_at: reminder.at.toISOString(), reminder_repeat: reminder.repeat } : {}),
          };
        }),
        color: n.color,
        pinned: n.pinned,
        archived: n.archived,
        reminder_at: n.reminderAt?.toISOString() ?? null,
        reminder_repeat: n.reminderRepeat,
        labels: labelNames(n, names),
        created_at: n.createdAt.toISOString(),
        updated_at: n.updatedAt.toISOString(),
      };
    }),
  };
  return JSON.stringify(data, null, 2);
}

function toMarkdown(notes: readonly Note[], names: ReadonlyMap<string, string>, workspaceNames: ReadonlyMap<string, string>, now: Date): string {
  let buf = "# Skippy export\n\n";
  buf += `_Exported ${isoDay(now)} · ${notes.length} ${notes.length === 1 ? "note" : "notes"}_\n\n`;
  for (const n of notes) {
    buf += "---\n\n";
    const workspace = workspaceNames.get(n.workspaceId);
    if (workspace !== undefined) {
      buf += `**Workspace:** ${workspace}\n\n`;
    }
    const title = n.title.trim();
    if (title) {
      buf += `## ${title}\n\n`;
    }
    if (n.kind === "checklist") {
      for (const i of n.items) {
        buf += `${" ".repeat(i.depth * 2)}- [${i.done ? "x" : " "}] ${i.text}\n`;
      }
      buf += "\n";
    } else if (n.content.trim()) {
      buf += `${plainNoteLinks(n.content).trimEnd()}\n\n`;
    }
    const labels = labelNames(n, names);
    if (labels.length > 0) {
      buf += `${labels.map((l) => `\`${l}\``).join(" ")}\n\n`;
    }
  }
  return `${buf.trimEnd()}\n`;
}

/** One note as plain text: title, body, `[x] item` rows, optional labels line. */
export function noteToPlainText(note: Note, labels: readonly string[] = []): string {
  let buf = "";
  const title = note.title.trim();
  if (title) {
    buf += `${title}\n\n`;
  }
  if (note.kind === "checklist") {
    for (const i of note.items) {
      buf += `${" ".repeat(i.depth * 2)}[${i.done ? "x" : " "}] ${i.text}\n`;
    }
    buf += "\n";
  } else if (note.content.trim()) {
    buf += `${plainNoteLinks(note.content).trimEnd()}\n\n`;
  }
  if (labels.length > 0) {
    buf += `Labels: ${labels.join(", ")}\n\n`;
  }
  return buf;
}

function toText(notes: readonly Note[], names: ReadonlyMap<string, string>, workspaceNames: ReadonlyMap<string, string>): string {
  let buf = "";
  notes.forEach((note, idx) => {
    if (idx > 0) {
      buf += `${"—".repeat(40)}\n\n`;
    }
    const workspace = workspaceNames.get(note.workspaceId);
    if (workspace !== undefined) {
      buf += `Workspace: ${workspace}\n\n`;
    }
    buf += noteToPlainText(note, labelNames(note, names));
  });
  return `${buf.trimEnd()}\n`;
}
