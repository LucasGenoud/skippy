"use client";

import { Archive, ArchiveArrowUp, CircleAlert, CopyPlus, Trash2, WandSparkles } from "lucide-react";

import { showAppSnack } from "@/components/common/snack";
import { ApiError, errorMessage } from "@/lib/api/errors";
import type { DroppedFile } from "@/lib/models/misc";
import type { Note, NoteRewriteTask } from "@/lib/models/note";
import { navigate } from "@/lib/router";
import type { NotesStore } from "@/lib/store";
import { MAX_UPLOAD_BYTES } from "@/lib/util/mime";
import { noteToPlainText } from "@/lib/util/note-export";

import { rewriteFailureSentence } from "./card-rules";

// What the card, the editor and the home screen all do to a note, written
// once so they cannot drift apart: each changes the store and says what
// happened, with an undo where there is one. Ported from `note_actions.dart`.

const BYTES_PER_MEGABYTE = 1024 * 1024;

/** Archives [note], or brings it back out of the archive, offering an undo. */
export function toggleArchive(store: NotesStore, note: Note): void {
  const wasArchived = note.archived;
  store.setArchived(note.id, !wasArchived);
  showAppSnack(wasArchived ? "Note unarchived" : "Note archived", {
    icon: wasArchived ? ArchiveArrowUp : Archive,
    undo: () => store.setArchived(note.id, wasArchived),
  });
}

/** Moves the note to Trash, offering an undo. */
export function trashNote(store: NotesStore, id: string): void {
  store.moveToTrash(id);
  showAppSnack("Note moved to Trash", { icon: Trash2, kind: "danger", undo: () => store.restoreFromTrash(id) });
}

/** Puts [note] on the clipboard as plain text, labels left out like the Dart client. */
export async function copyNoteText(note: Note): Promise<void> {
  try {
    await navigator.clipboard.writeText(noteToPlainText(note).trimEnd());
  } catch {
    showAppSnack("Couldn't copy the note", { icon: CircleAlert, kind: "danger" });
  }
}

/** Duplicates [id] and names the copy, offering the way in (`_duplicate` in note_card.dart). */
export function duplicateNote(store: NotesStore, id: string): Note | null {
  const copy = store.duplicate(id);
  if (!copy) {
    return null;
  }
  // The copy lands at the front, which is not necessarily where you are
  // looking; opening it outright would get in the way of duplicating a few.
  showAppSnack(`Duplicated as “${copy.title}”`, {
    icon: CopyPlus,
    action: { label: "Open", onClick: () => navigate({ name: "note", noteId: copy.id }) },
  });
  return copy;
}

/** Has the workspace's AI rewrite the note, and says how that went. */
export async function rewriteWithAi(store: NotesStore, id: string, task: NoteRewriteTask): Promise<boolean> {
  try {
    await store.rewriteNote(id, task);
  } catch (error) {
    const reason = error instanceof ApiError ? error.serverMessage : errorMessage(error);
    showAppSnack(`Couldn't rewrite the note. ${rewriteFailureSentence(reason)}`, { icon: CircleAlert, kind: "danger" });
    return false;
  }
  showAppSnack(`${task.name} complete`, { icon: WandSparkles });
  return true;
}

/** [files] without the ones over the upload limit, saying so when any were left out. */
export function filesWithinLimit<T extends { readonly size: number }>(files: readonly T[]): T[] {
  const accepted = files.filter((f) => f.size <= MAX_UPLOAD_BYTES);
  if (accepted.length !== files.length) {
    showAppSnack(`Files are limited to ${MAX_UPLOAD_BYTES / BYTES_PER_MEGABYTE} MB`, { icon: CircleAlert, kind: "warning" });
  }
  return accepted;
}

/** A picked browser file as the store's upload input. */
export function droppedFile(file: File): DroppedFile {
  return { name: file.name || "file", mime: file.type || "application/octet-stream", bytes: file };
}

/** Uploads [files] onto [noteId] one by one, naming each that failed. */
export async function uploadFiles(store: NotesStore, noteId: string, files: readonly File[]): Promise<void> {
  for (const file of files) {
    try {
      await store.uploadFile(noteId, file, file.type || "application/octet-stream", file.name || "file");
    } catch {
      showAppSnack(`Couldn't upload ${file.name || "the file"}`, { icon: CircleAlert, kind: "danger" });
    }
  }
}
