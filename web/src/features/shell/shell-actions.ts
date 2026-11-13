"use client";

import { createContext, useContext, type RefObject } from "react";
import type { NoteKind } from "@/lib/models/note";
import { navigate } from "@/lib/router";
import { destinationsEqual } from "@/lib/state/notes-cache-doc";
import { chatAvailability } from "@/features/chat/chat-availability";
import { composeLabelIdsOf, useAiIn, useNotesController, useSettings, useUi, useUiController, type Destination } from "@/lib/store";
import { prefersReducedMotion } from "@/lib/theme/motion";
import { useShellDialogs } from "./shell-dialogs";

// Actions several shell surfaces share: open a destination, start a note.

/** The element the shell's content scrolls in. */
export const ScrollRootContext = createContext<RefObject<HTMLElement | null> | null>(null);

/**
 * The shell's scroll container, for a view that virtualises against it or
 * restores a position. Null outside the shell.
 */
export function useShellScrollRoot(): RefObject<HTMLElement | null> | null {
  return useContext(ScrollRootContext);
}

/**
 * Open a sidebar destination (`_selectView`): a new view starts at its top;
 * picking the one already shown glides back up instead. Clears the search
 * and the selection, and remembers the choice for the workspace.
 */
export function useOpenDestination(): (destination: Destination, collectionId?: string) => void {
  const ui = useUiController();
  const notes = useNotesController();
  const scroll = useContext(ScrollRootContext);
  return (destination, collectionId) => {
    const sameCollection = collectionId === undefined || collectionId === notes.activeCollection?.id;
    const same = sameCollection && destinationsEqual(destination, ui.state.destination);
    const element = scroll?.current;
    if (element) {
      if (same) {
        element.scrollTo?.({ top: 0, behavior: prefersReducedMotion() ? "auto" : "smooth" });
      } else {
        element.scrollTo?.({ top: 0 });
      }
    }
    if (collectionId !== undefined) {
      notes.selectCollection(collectionId);
    }
    ui.selectDestination(destination);
  };
}

/**
 * Start a note of [kind] in the open collection, carrying the open label so
 * it stays in view (`_newNote`). With no collection to write into, offer to
 * create one instead.
 */
export function useNewNote(): (kind: NoteKind) => void {
  const notes = useNotesController();
  const ui = useUiController();
  const dialogs = useShellDialogs();
  return (kind) => {
    if (notes.activeCollection === null) {
      const workspaceId = notes.activeWorkspaceId;
      if (workspaceId !== null) {
        dialogs.open({ type: "collection", workspaceId });
      }
      return;
    }
    const draft = notes.createDraft({ kind, labelIds: composeLabelIdsOf(ui.state) });
    notes.beginEditing(draft.id, "new");
    navigate({ name: "note", noteId: draft.id });
  };
}

/** Whether to offer notes chat for the open workspace, by the chat screen's own rule. */
export function useChatAvailable(): boolean {
  const workspaceId = useUi((s) => s.activeWorkspaceId);
  const ai = useAiIn(workspaceId);
  const settingsLoaded = useSettings((s) => s.loaded);
  const semanticSearchCapable = useSettings((s) => s.semanticSearchCapable);
  return chatAvailability({ settingsLoaded, semanticSearchCapable, ai }) === "ready";
}
