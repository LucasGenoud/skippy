// The markdown toolbar's edits (`widgets/markdown_toolbar.dart`): each one
// rewrites the body around the selection and says where the selection lands,
// so the change goes through the editor's ordinary save and undo path.

export interface TextSelectionEdit {
  readonly text: string;
  readonly start: number;
  readonly end: number;
}

const LINK_PLACEHOLDER = "url";
const LINK_LABEL_PLACEHOLDER = "text";
const HEADING_MARKER = /^#{1,6}\s*/;

function clampRange(text: string, start: number, end: number): [number, number] {
  const a = Math.max(0, Math.min(start, text.length));
  const b = Math.max(a, Math.min(end, text.length));
  return [a, b];
}

/** Wrap the selection in [left]/[right]; an empty one parks the caret between them. */
export function wrapSelection(edit: TextSelectionEdit, left: string, right: string): TextSelectionEdit {
  const [start, end] = clampRange(edit.text, edit.start, edit.end);
  const selected = edit.text.slice(start, end);
  const text = `${edit.text.slice(0, start)}${left}${selected}${right}${edit.text.slice(end)}`;
  const inner = start + left.length;
  return { text, start: inner, end: inner + selected.length };
}

/** Rewrite every line the selection touches through [transform]. */
export function rewriteLines(edit: TextSelectionEdit, transform: (line: string) => string): TextSelectionEdit {
  const [start, end] = clampRange(edit.text, edit.start, edit.end);
  const lineStart = start === 0 ? 0 : edit.text.lastIndexOf("\n", start - 1) + 1;
  let lineEnd = edit.text.indexOf("\n", end);
  if (lineEnd < 0) {
    lineEnd = edit.text.length;
  }
  const rewritten = edit.text.slice(lineStart, lineEnd).split("\n").map(transform).join("\n");
  const text = `${edit.text.slice(0, lineStart)}${rewritten}${edit.text.slice(lineEnd)}`;
  const caret = lineStart + rewritten.length;
  return { text, start: caret, end: caret };
}

/** A heading of [level], replacing any marker already there so levels swap rather than stack. */
export function headingLine(level: number, line: string): string {
  return `${"#".repeat(level)} ${line.replace(HEADING_MARKER, "")}`;
}

/** Add [marker] to the line, or strip it when it is already there. */
export function togglePrefix(marker: string, line: string): string {
  return line.startsWith(marker) ? line.slice(marker.length) : `${marker}${line}`;
}

/** `[label](url)` with the "url" placeholder selected, so the address is typed next. */
export function insertLink(edit: TextSelectionEdit): TextSelectionEdit {
  const [start, end] = clampRange(edit.text, edit.start, edit.end);
  const label = start === end ? LINK_LABEL_PLACEHOLDER : edit.text.slice(start, end);
  const text = `${edit.text.slice(0, start)}[${label}](${LINK_PLACEHOLDER})${edit.text.slice(end)}`;
  // Past `[label](`.
  const urlStart = start + label.length + 3;
  return { text, start: urlStart, end: urlStart + LINK_PLACEHOLDER.length };
}

export type MarkdownAction =
  | "h1"
  | "h2"
  | "h3"
  | "bold"
  | "italic"
  | "strike"
  | "code"
  | "codeBlock"
  | "bullets"
  | "numbers"
  | "quote"
  | "link";

export function applyMarkdownAction(edit: TextSelectionEdit, action: MarkdownAction): TextSelectionEdit {
  switch (action) {
    case "h1":
      return rewriteLines(edit, (line) => headingLine(1, line));
    case "h2":
      return rewriteLines(edit, (line) => headingLine(2, line));
    case "h3":
      return rewriteLines(edit, (line) => headingLine(3, line));
    case "bold":
      return wrapSelection(edit, "**", "**");
    case "italic":
      return wrapSelection(edit, "_", "_");
    case "strike":
      return wrapSelection(edit, "~~", "~~");
    case "code":
      return wrapSelection(edit, "`", "`");
    case "codeBlock":
      return wrapSelection(edit, "```\n", "\n```");
    case "bullets":
      return rewriteLines(edit, (line) => togglePrefix("- ", line));
    case "numbers":
      return rewriteLines(edit, (line) => togglePrefix("1. ", line));
    case "quote":
      return rewriteLines(edit, (line) => togglePrefix("> ", line));
    case "link":
      return insertLink(edit);
  }
}

const TASK_LINE = /^(\s*[-*+]\s+\[)([ xX])(\])/;

/** The source with the task on [lineIndex] ticked or unticked (a tap in the preview). */
export function setTaskLine(source: string, lineIndex: number, done: boolean): string {
  const lines = source.split("\n");
  const line = lines[lineIndex];
  if (line === undefined || !TASK_LINE.test(line)) {
    return source;
  }
  lines[lineIndex] = line.replace(TASK_LINE, `$1${done ? "x" : " "}$3`);
  return lines.join("\n");
}
