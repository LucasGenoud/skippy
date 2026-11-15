"use client";

import { useEffect, useRef } from "react";
import { useRoute } from "@/lib/router";
import { useNotesController, useUiController } from "@/lib/store";
import { useNewNote } from "./shell-actions";
import { useShellDialogs } from "./shell-dialogs";
import { isEditableTarget, shortcutFor, type ShortcutAction } from "./shortcuts";
import { useToggleGridLayout } from "./top-bar-controls";

/** A dialog, menu or popover is up: its own keys win. */
function overlayOpen(): boolean {
  return document.querySelector('[role="dialog"][data-state="open"], [role="alertdialog"][data-state="open"], [data-radix-popper-content-wrapper]') !== null;
}

/**
 * The notes screen's keyboard shortcuts, live while the home view is the
 * page (not under an open note) and nothing modal is up. A key another
 * handler already consumed (the quick-add composer's Escape) is left alone.
 */
export function useHomeShortcuts(): void {
  const route = useRoute();
  const ui = useUiController();
  const notes = useNotesController();
  const dialogs = useShellDialogs();
  const newNote = useNewNote();
  const toggleGrid = useToggleGridLayout();
  const home = route.name === "home";

  // Read through a ref so the listener is installed once per page, not per render.
  const run = useRef<(action: ShortcutAction) => boolean>(() => false);
  const perform = (action: ShortcutAction): boolean => {
    switch (action.type) {
      case "newNote":
        newNote(action.kind);
        return true;
      case "focusSearch":
        ui.requestSearchFocus();
        return true;
      case "help":
        dialogs.open({ type: "shortcuts" });
        return true;
      case "toggleLayout": {
        if (toggleGrid) {
          toggleGrid();
          return true;
        }
        // A board switches through its collection's settings.
        const collection = notes.activeCollection;
        if (collection) {
          dialogs.open({ type: "collection", workspaceId: collection.workspaceId, collectionId: collection.id });
          return true;
        }
        return false;
      }
      case "escape": {
        // Selection first (the more modal of the two), then the search.
        if (ui.state.selectedIds.length > 0) {
          ui.clearSelection();
          return true;
        }
        const active = document.activeElement;
        if (ui.state.query !== "") {
          ui.clearQuery();
          if (active instanceof HTMLElement) {
            active.blur();
          }
          return true;
        }
        if (active instanceof HTMLElement && active.getAttribute("role") === "searchbox") {
          active.blur();
          return true;
        }
        return false;
      }
    }
  };

  useEffect(() => {
    run.current = perform;
  });

  useEffect(() => {
    if (!home) {
      return;
    }
    const onKey = (event: KeyboardEvent): void => {
      if (event.defaultPrevented || event.isComposing || overlayOpen()) {
        return;
      }
      const action = shortcutFor(event, isEditableTarget(event.target) ? "typing" : "idle");
      if (action && run.current(action)) {
        event.preventDefault();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [home]);
}
