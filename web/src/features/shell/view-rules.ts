import type { ViewSelection } from "@/lib/state/note-collection";

// What the open view is called and what it says when it is empty
// (`_viewTitle` and `_emptyState` in `home_screen.dart`).

export interface ViewNames {
  readonly collection: string | null;
  readonly label: string | null;
  readonly smartView: string | null;
}

export function viewTitle(selection: ViewSelection, names: ViewNames): string {
  switch (selection.view) {
    case "notes":
    case "board":
      return names.collection ?? "Collections";
    case "reminders":
      return "Reminders";
    case "archive":
      return "Archive";
    case "trash":
      return "Trash";
    case "label":
      return names.label ?? "";
    case "smart":
      return names.smartView ?? "Smart view";
  }
}

export type EmptyIcon = "search" | "notes" | "board" | "reminders" | "archive" | "trash" | "label" | "smart";

export interface EmptyCopy {
  readonly icon: EmptyIcon;
  readonly message: string;
  /** A smart view is a query: the way out is to go look at the notes, not write one. */
  readonly action: "browse" | "create" | null;
  readonly mark: "icon" | "logo";
}

/** The empty state of [selection]; [searching] when the box holds a query. */
export function emptyCopy(selection: ViewSelection, searching: boolean): EmptyCopy {
  if (searching) {
    return { icon: "search", message: "No matching notes", action: null, mark: "icon" };
  }
  switch (selection.view) {
    case "notes":
      return { icon: "notes", message: "Notes you add appear here", action: "create", mark: "logo" };
    case "board":
      return { icon: "board", message: "Notes you add appear here", action: "create", mark: "icon" };
    case "reminders":
      return { icon: "reminders", message: "Notes with reminders appear here", action: "create", mark: "icon" };
    case "archive":
      return { icon: "archive", message: "Your archived notes appear here", action: "browse", mark: "icon" };
    case "trash":
      return { icon: "trash", message: "No notes in Trash", action: "browse", mark: "icon" };
    case "label":
      return { icon: "label", message: "No notes with this label yet", action: "create", mark: "icon" };
    case "smart":
      return { icon: "smart", message: "No notes match this smart view", action: "browse", mark: "icon" };
  }
}

/** Trash's standing notice. */
export const TRASH_NOTICE = "Notes in Trash are deleted after 7 days";
