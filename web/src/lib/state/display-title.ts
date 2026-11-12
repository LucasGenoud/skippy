import type { Note } from "@/lib/models/note";

// What a note is called where it needs a one-line name: links, reminders,
// pickers. Ported from `widgetDisplayTitle` in `util/widget_payload.dart`.

const MAX_TITLE_CHARS = 60;

function cap(value: string, max: number): string {
  const chars = Array.from(value);
  return chars.length <= max ? value : `${chars.slice(0, max).join("")}…`;
}

export function noteDisplayTitle(note: Note): string {
  const title = note.title.trim();
  if (title) {
    return title;
  }
  for (const line of note.content.split("\n")) {
    const trimmed = line.trim();
    if (trimmed) {
      return cap(trimmed, MAX_TITLE_CHARS);
    }
  }
  for (const item of note.items) {
    const trimmed = item.text.trim();
    if (trimmed) {
      return cap(trimmed, MAX_TITLE_CHARS);
    }
  }
  return "Untitled note";
}
