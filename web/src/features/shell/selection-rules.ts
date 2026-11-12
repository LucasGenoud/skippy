import type { Label, Note } from "@/lib/models/note";
import type { Destination } from "@/lib/store";

// What the selection bar offers and does, decided away from the widgets
// (`_selectionActions` and its helpers in `home_screen.dart`).

/** Which bulk controls the open destination shows. */
export interface SelectionOffer {
  /** Archive in most views, unarchive inside the archive. */
  readonly archive: "archive" | "unarchive" | null;
  readonly restore: boolean;
  readonly trash: boolean;
  readonly deleteForever: boolean;
}

export function selectionOffer(destination: Destination): SelectionOffer {
  const inTrash = destination === "trash";
  return {
    archive: inTrash ? null : destination === "archive" ? "unarchive" : "archive",
    restore: inTrash,
    trash: !inTrash,
    deleteForever: inTrash,
  };
}

/** Pin when any selected note is unpinned; unpin when all are pinned. */
export function pinsSelection(notes: readonly Note[]): boolean {
  return notes.length === 0 || !notes.every((n) => n.pinned);
}

/** Whether every visible id is selected (the select-all control flips to deselect). */
export function allSelected(visible: readonly string[], selected: readonly string[]): boolean {
  if (visible.length === 0) {
    return false;
  }
  const set = new Set(selected);
  return visible.every((id) => set.has(id));
}

/** The selected notes the user may trash, and how many were skipped (not theirs). */
export function trashPlan(notes: readonly Note[], canTrash: (id: string) => boolean): { trash: Note[]; skipped: number } {
  const trash = notes.filter((n) => canTrash(n.id));
  return { trash, skipped: notes.length - trash.length };
}

/** The snack after a bulk trash, or null when nothing needs saying. */
export function trashMessage(moved: number, skipped: number): { text: string; kind: "danger" | "warning" } | null {
  if (moved > 0) {
    const noun = moved === 1 ? "note" : "notes";
    return { text: `${moved} ${noun} moved to Trash${skipped > 0 ? "; shared notes were skipped" : ""}`, kind: "danger" };
  }
  if (skipped > 0) {
    return { text: "Only note owners can move notes to Trash", kind: "warning" };
  }
  return null;
}

/** The value every note shares, or [fallback] when they differ (the colour sheet's check). */
export function commonValue<T>(values: readonly T[], fallback: T): T {
  const first = values[0];
  if (first === undefined) {
    return fallback;
  }
  return values.every((v) => v === first) ? first : fallback;
}

/** Labels of [note] that do not exist in [workspaceId], which a move drops. */
export function labelsDroppedByMove(note: Note, workspaceId: string, labelById: (id: string) => Label | null): number {
  return note.labelIds.filter((id) => labelById(id)?.workspaceId !== workspaceId).length;
}

export function selectionLabel(count: number): string {
  return count === 0 ? "Select notes" : `${count} selected`;
}
