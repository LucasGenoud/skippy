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

/** What "Share this view" publishes: the request, its name and what a reader can see. */
export interface ViewLink {
  readonly request: {
    readonly target: "notes" | "board" | "label";
    readonly workspaceId?: string;
    readonly collectionId?: string | null;
    readonly labelId?: string;
  };
  readonly title: string;
  readonly scope: string;
}

export interface ViewLinkContext {
  readonly workspace: { readonly id: string; readonly name: string; readonly owned: boolean } | null;
  readonly collection: { readonly id: string; readonly name: string } | null;
  readonly label: { readonly id: string; readonly name: string } | null;
}

/**
 * The link "Share this view" would publish, or null when the view is not
 * publishable (`_shareViewTarget`). Archive, trash, reminders and smart views
 * stay private, and only the workspace's owner may publish its views.
 */
export function viewLink(selection: ViewSelection, { workspace, collection, label }: ViewLinkContext): ViewLink | null {
  if (!workspace?.owned) {
    return null;
  }
  const where = collection?.name ?? workspace.name;
  switch (selection.view) {
    case "notes":
      return {
        request: { target: "notes", workspaceId: workspace.id, collectionId: collection?.id ?? null },
        title: where,
        scope: `Anyone with the link can read every live note in "${where}", including notes other members wrote. Archived and trashed notes stay private.`,
      };
    case "board":
      return {
        request: { target: "board", workspaceId: workspace.id, collectionId: collection?.id ?? null },
        title: `${where} board`,
        scope: `Anyone with the link can read the board of "${where}": its columns and the cards in them, including cards other members wrote.`,
      };
    case "label":
      return label
        ? {
            request: { target: "label", labelId: label.id, collectionId: collection?.id ?? null },
            title: label.name,
            scope: `Anyone with the link can read every live note labelled "${label.name}" in this collection, including notes other members wrote.`,
          }
        : null;
    default:
      return null;
  }
}
