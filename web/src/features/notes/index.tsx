"use client";

import { useVisibleNoteIds } from "@/lib/store/hooks";

// Placeholder: the NOTES agent replaces these with the grid/list and the menu.
export function NotesView() {
  const { pinned, others } = useVisibleNoteIds();
  return <div data-placeholder="notes-view">{pinned.length + others.length} notes</div>;
}

export function NoteActionsMenu({ noteId, surface }: { noteId: string; surface: "card" | "editor" }) {
  return <div data-placeholder="note-actions" data-note={noteId} data-surface={surface} />;
}
