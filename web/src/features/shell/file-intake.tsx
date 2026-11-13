"use client";

import { useEffect, useRef, useState } from "react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { CircleAlert, FileUp } from "lucide-react";
import { showAppSnack } from "@/components/common/snack";
import type { DroppedFile } from "@/lib/models";
import { useRoute } from "@/lib/router";
import { composeLabelIdsOf, useNotesController, useUiController } from "@/lib/store";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";
import { DragDepth, clipboardHandles, dragHasFiles, droppedHandles, toDroppedFiles, type FileSource } from "./browser-files";
import { isEditableTarget } from "./shortcuts";

// Files dropped anywhere on the window, or pasted while nothing that takes
// text has focus, become one new note in the open view (`FileDropArea`,
// `_createNoteFromDrop`). An open editor or dialog owns its own drops and
// pastes, so the shell stands aside while one is up.

/** Whether a modal surface (dialog, sheet) is open over the shell. */
function modalOpen(): boolean {
  return document.querySelector('[role="dialog"][data-state="open"], [role="alertdialog"][data-state="open"]') !== null;
}

/** Listens on the window and returns whether a file drag is over it. */
export function useFileIntake(): boolean {
  const route = useRoute();
  const notes = useNotesController();
  const ui = useUiController();
  const [dragging, setDragging] = useState(false);
  const depth = useRef(new DragDepth());
  const home = route.name === "home";

  useEffect(() => {
    if (!home) {
      return;
    }
    const counter = depth.current;
    const accepts = (): boolean => !modalOpen();

    const create = async (handles: File[], source: FileSource): Promise<void> => {
      const files: DroppedFile[] = toDroppedFiles(handles, source);
      if (files.length === 0) {
        showAppSnack("Files over 25 MB can't be attached", { kind: "warning", icon: CircleAlert });
        return;
      }
      const id = await notes.createNoteWithFiles(files, composeLabelIdsOf(ui.state));
      if (id === null) {
        showAppSnack(source === "drop" ? "Couldn't upload the dropped files" : "Couldn't upload the pasted files", { kind: "danger", icon: CircleAlert });
      }
    };

    const onEnter = (e: DragEvent): void => {
      if (!dragHasFiles(e.dataTransfer) || !accepts()) {
        return;
      }
      e.preventDefault();
      counter.enter();
      setDragging(true);
    };
    const onOver = (e: DragEvent): void => {
      if (!dragHasFiles(e.dataTransfer) || !accepts()) {
        return;
      }
      // preventDefault is what makes the page a valid drop target.
      e.preventDefault();
      if (e.dataTransfer) {
        e.dataTransfer.dropEffect = "copy";
      }
    };
    const onLeave = (e: DragEvent): void => {
      if (!dragHasFiles(e.dataTransfer)) {
        return;
      }
      if (!counter.leave()) {
        setDragging(false);
      }
    };
    const onDrop = (e: DragEvent): void => {
      if (!dragHasFiles(e.dataTransfer)) {
        return;
      }
      counter.reset();
      setDragging(false);
      if (e.defaultPrevented || !accepts()) {
        return;
      }
      e.preventDefault();
      void create(droppedHandles(e.dataTransfer), "drop");
    };
    const onPaste = (e: ClipboardEvent): void => {
      if (e.defaultPrevented || isEditableTarget(e.target) || isEditableTarget(document.activeElement) || !accepts()) {
        return;
      }
      const handles = clipboardHandles(e.clipboardData);
      if (handles.length === 0) {
        return;
      }
      e.preventDefault();
      void create(handles, "paste");
    };

    window.addEventListener("dragenter", onEnter);
    window.addEventListener("dragover", onOver);
    window.addEventListener("dragleave", onLeave);
    window.addEventListener("drop", onDrop);
    document.addEventListener("paste", onPaste);
    return () => {
      window.removeEventListener("dragenter", onEnter);
      window.removeEventListener("dragover", onOver);
      window.removeEventListener("dragleave", onLeave);
      window.removeEventListener("drop", onDrop);
      document.removeEventListener("paste", onPaste);
      counter.reset();
      setDragging(false);
    };
  }, [home, notes, ui]);

  return dragging && home;
}

/** The veil and hint while files are dragged over the window. */
export function FileDropOverlay({ visible }: { visible: boolean }) {
  const reduced = useReducedMotion();
  return (
    <AnimatePresence>
      {visible ? (
        <motion.div
          key="drop"
          aria-hidden
          className="pointer-events-none fixed inset-0 z-40 flex items-center justify-center bg-[#0D101A]/35"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={transitionFor(TRANSITION.fast, reduced)}
        >
          <motion.div
            className="flex items-center gap-3 rounded-xl border border-outline-variant bg-surface-container-high px-6 py-4 shadow-dialog"
            initial={{ scale: 0.96 }}
            animate={{ scale: 1 }}
            exit={{ scale: 0.96 }}
            transition={transitionFor(TRANSITION.base, reduced)}
          >
            <FileUp className="size-5 text-primary" />
            <span className="text-base font-medium text-on-surface">Drop files to create a note</span>
          </motion.div>
        </motion.div>
      ) : null}
    </AnimatePresence>
  );
}
