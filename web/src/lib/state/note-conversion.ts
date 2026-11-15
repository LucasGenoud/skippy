import { MAX_ITEM_DEPTH, type ChecklistItem, type Note, type NoteKind } from "@/lib/models/note";
import { normalizeDepths } from "./checklist-tree";

// Converts a note's content between text, markdown, and checklist forms.
// Ported from `state/note_conversion.dart`.

/** Title a duplicate carries: "Groceries (copy)", or "(copy)". */
export function copyTitle(title: string): string {
  return `${title} (copy)`.trim();
}

/** Spaces one nesting level is written with. */
const INDENT_WIDTH = 2;

export function convertNoteKind(note: Note, target: NoteKind, newItemId: () => string): Note {
  if (note.kind === target) {
    return note;
  }
  if (target === "checklist") {
    // Rows minted from text are new, so earlier item reminders have nothing to point at.
    return { ...note, kind: target, content: "", items: itemsFromText(note.content, newItemId), itemReminders: {} };
  }
  if (note.kind === "checklist") {
    const itemText = textFromItems(note.items, target === "markdown");
    const content = note.content.trim() === "" ? itemText : `${note.content}\n${itemText}`;
    return { ...note, kind: target, content, items: [], itemReminders: {} };
  }
  // Text and markdown share the same content representation.
  return { ...note, kind: target };
}

function itemsFromText(content: string, newItemId: () => string): readonly ChecklistItem[] {
  const items: ChecklistItem[] = [];
  for (const rawLine of content.split("\n")) {
    if (rawLine.trim() === "") {
      continue;
    }
    // A tab counts as one level, spaces as one per INDENT_WIDTH.
    const indent = /^[ \t]*/.exec(rawLine)?.[0] ?? "";
    const tabs = indent.split("\t").length - 1;
    const spaces = indent.replaceAll("\t", "").length;
    const depth = tabs + Math.floor(spaces / INDENT_WIDTH);
    let line = rawLine.trim();
    let done = false;
    const task = /^[-*+]\s+\[( |x|X)\]\s*/.exec(line);
    if (task) {
      done = (task[1] ?? "").toLowerCase() === "x";
      line = line.slice(task[0].length).trim();
    } else {
      line = line.replace(/^[-*+]\s+/, "");
    }
    if (!line) {
      continue;
    }
    items.push({ id: newItemId(), text: line, done, depth: Math.min(depth, MAX_ITEM_DEPTH) });
  }
  return normalizeDepths(items);
}

function textFromItems(items: readonly ChecklistItem[], markdown: boolean): string {
  return items
    .filter((item) => item.text.trim() !== "")
    .map((item) => `${" ".repeat(item.depth * INDENT_WIDTH)}${markdown ? `- [${item.done ? "x" : " "}] ` : ""}${item.text}`)
    .join("\n");
}
