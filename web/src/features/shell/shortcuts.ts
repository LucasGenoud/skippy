import type { NoteKind } from "@/lib/models/note";

// The notes screen's keyboard shortcuts (`_homeShortcuts` in
// `home_screen.dart`), as a pure decision over one keydown.
//
// Printable keys match the character the keystroke produced, so "/" works
// where it is Shift+7 (Swiss layouts), and they stay quiet while a text field
// has focus: the letter is typed instead. Chords and Escape fire while typing.

export type ShortcutAction =
  | { readonly type: "newNote"; readonly kind: NoteKind }
  | { readonly type: "focusSearch" }
  | { readonly type: "toggleLayout" }
  | { readonly type: "escape" }
  | { readonly type: "help" };

/** The parts of a KeyboardEvent the decision reads. */
export interface ShortcutKey {
  readonly key: string;
  readonly ctrlKey: boolean;
  readonly metaKey: boolean;
  readonly altKey: boolean;
  readonly shiftKey: boolean;
}

/** Whether focus is in something that takes text. */
export type FocusContext = "typing" | "idle";

const CHARACTER_SHORTCUTS: Readonly<Record<string, ShortcutAction>> = {
  c: { type: "newNote", kind: "text" },
  n: { type: "newNote", kind: "text" },
  l: { type: "newNote", kind: "checklist" },
  m: { type: "newNote", kind: "markdown" },
  "/": { type: "focusSearch" },
  "?": { type: "help" },
};

const CHORD_SHORTCUTS: Readonly<Record<string, ShortcutAction>> = {
  k: { type: "focusSearch" },
  g: { type: "toggleLayout" },
};

/** The action [event] asks for, or null to let the key through. */
export function shortcutFor(event: ShortcutKey, focus: FocusContext): ShortcutAction | null {
  if (event.key === "Escape") {
    return event.ctrlKey || event.metaKey || event.altKey ? null : { type: "escape" };
  }

  // Ctrl on every platform and Cmd on a Mac both count, as the Dart bindings do.
  const chord = event.ctrlKey || event.metaKey;
  if (chord) {
    if (event.altKey || event.shiftKey || (event.ctrlKey && event.metaKey)) {
      return null;
    }
    return CHORD_SHORTCUTS[event.key.toLowerCase()] ?? null;
  }

  if (focus === "typing" || event.altKey) {
    return null;
  }
  // A character key matches what it typed; Shift is part of producing "?".
  return CHARACTER_SHORTCUTS[event.key] ?? null;
}

/** Whether [target] is a field that takes text (where printable keys must type). */
export function isEditableTarget(target: EventTarget | null): boolean {
  if (typeof Element === "undefined" || !(target instanceof Element)) {
    return false;
  }
  if (target instanceof HTMLElement && target.isContentEditable) {
    return true;
  }
  if (target instanceof HTMLTextAreaElement || target instanceof HTMLSelectElement) {
    return true;
  }
  if (target instanceof HTMLInputElement) {
    return !NON_TEXT_INPUTS.has(target.type);
  }
  return target.closest("[contenteditable=''], [contenteditable='true']") !== null;
}

const NON_TEXT_INPUTS = new Set(["button", "checkbox", "radio", "range", "color", "file", "submit", "reset", "image"]);

/** "Cmd" on Apple platforms, "Ctrl" elsewhere: words, which every font covers. */
export function modifierName(platform: string): "Cmd" | "Ctrl" {
  return /mac|iphone|ipad|ipod/i.test(platform) ? "Cmd" : "Ctrl";
}

/** The rows of the shortcut reference (`shortcut_help.dart`). */
export function shortcutSections(mod: string): readonly { title: string; rows: readonly { keys: readonly string[]; description: string }[] }[] {
  return [
    {
      title: "Notes screen",
      rows: [
        { keys: ["C", "N"], description: "New note" },
        { keys: ["L"], description: "New checklist" },
        { keys: ["M"], description: "New markdown note" },
        { keys: ["/", `${mod} K`], description: "Search" },
        { keys: ["Esc"], description: "Exit selection / clear search" },
        { keys: [`${mod} G`], description: "Switch grid / list" },
        { keys: ["?"], description: "Show this help" },
      ],
    },
    {
      title: "Editor",
      rows: [
        { keys: [`${mod} Z`], description: "Undo" },
        { keys: [`Shift ${mod} Z`], description: "Redo" },
        { keys: ["Esc"], description: "Close and save" },
      ],
    },
    {
      title: "Quick add",
      rows: [{ keys: ["Esc"], description: "Save and close" }],
    },
  ];
}
