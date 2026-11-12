"use client";

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { animate, useReducedMotion } from "motion/react";
import { Dialog as DialogPrimitive } from "radix-ui";
import { cn } from "cn";

import { NotePattern } from "@/components/common/note-pattern";
import { isChecklist } from "@/lib/models/note";
import type { NotesStore } from "@/lib/store";
import { useNote, useNotesController, useNotesLoading, useSettings } from "@/lib/store";
import { DURATION, EASE } from "@/lib/theme/motion";
import { noteBackground } from "@/lib/theme/palette";
import { prunedRows } from "./checklist/checklist-view";
import { EditorBody, type EditorBodyHandle } from "./editor-body";
import { WIDE_QUERY, useBrightness, useMediaQuery } from "./lib/hooks";
import { MORPH_REST, boxOf, morphFrom, noteCardBox } from "./lib/morph";

// The note editor's surface (`openNoteEditor`, `EditorMorph`): a centred
// dialog on wide screens, the whole screen on phones, growing out of the
// card that opened it and shrinking back into it. Escape, the back button,
// a tap outside and the close button all close it; the draft is flushed (and
// an empty one discarded) as it unmounts.

const MS = 1000;
/** The editor's face reaches full opacity a quarter of the way into the morph. */
const FACE_SHARE = 0.25;

// Finalizing waits a tick, so a remount of the same note (React's strict
// double mount, a re-key) does not discard a draft that is still open.
const pendingFinalizes = new WeakMap<NotesStore, Map<string, ReturnType<typeof setTimeout>>>();

function pendingFor(notes: NotesStore): Map<string, ReturnType<typeof setTimeout>> {
  let pending = pendingFinalizes.get(notes);
  if (!pending) {
    pending = new Map();
    pendingFinalizes.set(notes, pending);
  }
  return pending;
}

/** What closing the editor does to its note (`_finalize`). */
export function finalizeEditing(notes: NotesStore, noteId: string): void {
  const note = notes.noteById(noteId);
  if (note && isChecklist(note)) {
    // Rows that are only whitespace go before the final save.
    const pruned = prunedRows(note.items);
    if (pruned) {
      notes.updateNoteContent(noteId, { items: pruned });
    }
  }
  notes.finalizeNote(noteId);
  notes.endEditing(noteId);
}

function useEditingLifecycle(notes: NotesStore, noteId: string, exists: boolean): void {
  useEffect(() => {
    if (!exists) {
      return;
    }
    const pendingFinalize = pendingFor(notes);
    const pending = pendingFinalize.get(noteId);
    if (pending !== undefined) {
      clearTimeout(pending);
      pendingFinalize.delete(noteId);
    } else {
      notes.beginEditing(noteId, notes.isDraft(noteId) ? "new" : "existing");
    }
    return () => {
      pendingFinalize.set(
        noteId,
        setTimeout(() => {
          pendingFinalize.delete(noteId);
          finalizeEditing(notes, noteId);
        }, 0),
      );
    };
  }, [notes, noteId, exists]);
}

export function NoteEditor({ noteId, onClose }: { noteId: string; onClose(): void }) {
  const notes = useNotesController();
  const note = useNote(noteId);
  const palette = useSettings((s) => s.palette);
  const brightness = useBrightness();
  const wide = useMediaQuery(WIDE_QUERY);
  const reduced = useReducedMotion();
  const panel = useRef<HTMLDivElement>(null);
  const face = useRef<HTMLDivElement>(null);
  const scrim = useRef<HTMLDivElement>(null);
  const body = useRef<EditorBodyHandle>(null);
  const [closing, setClosing] = useState(false);
  const exists = note !== null;
  const loading = useNotesLoading();
  const [opened, setOpened] = useState(false);

  useEditingLifecycle(notes, noteId, exists);

  // A note that is not here once the notes have loaded (a reload on an unsaved
  // draft), or that vanished underneath us (deleted elsewhere, or we left it),
  // closes the editor.
  useEffect(() => {
    if (!exists && !loading && !closing) {
      onClose();
    }
  }, [exists, loading, closing, onClose]);

  // Opening: grow out of the card, or fade in where there is none. Runs once,
  // when the note is first there to show.
  useLayoutEffect(() => {
    const el = panel.current;
    const content = face.current;
    if (opened || !exists || !el || !content) {
      return;
    }
    setOpened(true);
    const done = (): void => body.current?.opened();
    if (scrim.current) {
      animate(scrim.current, { opacity: [0, 1] }, { duration: reduced ? 0 : DURATION.base / MS, ease: [...EASE.standard] });
    }
    const source = reduced ? null : noteCardBox(noteId);
    const frame = source ? morphFrom(source, boxOf(el.getBoundingClientRect())) : null;
    if (reduced) {
      done();
      return;
    }
    if (!frame) {
      void animate(el, { opacity: [0, 1], scale: [0.96, 1] }, { duration: DURATION.base / MS, ease: [...EASE.emphasized] }).then(done);
      return;
    }
    const duration = DURATION.slow / MS;
    animate(content, { opacity: [0, 1] }, { duration: duration * FACE_SHARE, ease: [...EASE.standard] });
    void animate(
      el,
      { transform: [frame.transform, MORPH_REST.transform], clipPath: [frame.clipPath, MORPH_REST.clipPath] },
      { duration, ease: [...EASE.emphasized] },
    ).then(() => {
      el.style.clipPath = "";
      el.style.transform = "";
      done();
    });
    // The morph belongs to the opening only.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [exists]);

  const requestClose = (): void => {
    if (closing) {
      return;
    }
    setClosing(true);
    if (document.activeElement instanceof HTMLElement) {
      document.activeElement.blur();
    }
    const el = panel.current;
    const content = face.current;
    if (!el || !content || reduced) {
      onClose();
      return;
    }
    const duration = DURATION.slow / MS;
    if (scrim.current) {
      animate(scrim.current, { opacity: 0 }, { duration, ease: [...EASE.standard] });
    }
    const source = noteCardBox(noteId);
    const frame = source ? morphFrom(source, boxOf(el.getBoundingClientRect())) : null;
    if (!frame) {
      void animate(el, { opacity: 0, scale: 0.96 }, { duration: DURATION.fast / MS, ease: [...EASE.standard] }).then(onClose);
      return;
    }
    animate(content, { opacity: 0 }, { duration: duration * FACE_SHARE, delay: duration * (1 - FACE_SHARE), ease: [...EASE.standard] });
    void animate(el, { transform: [MORPH_REST.transform, frame.transform], clipPath: [MORPH_REST.clipPath, frame.clipPath] }, { duration, ease: [...EASE.emphasized] }).then(
      onClose,
    );
  };

  if (!note) {
    return null;
  }

  return (
    <DialogPrimitive.Root open onOpenChange={(open) => !open && requestClose()}>
      <DialogPrimitive.Portal>
        <DialogPrimitive.Overlay ref={scrim} className="fixed inset-0 z-50 bg-[#0D101A]/45" />
        <div className={cn("pointer-events-none fixed inset-0 z-50 flex", wide ? "items-center justify-center p-4" : "")}>
          <DialogPrimitive.Content
            ref={panel}
            aria-describedby={undefined}
            // Focus the panel, not its first button: that would pop the Close tooltip on open.
            // A new note's body takes focus itself once the open animation ends.
            onOpenAutoFocus={(event) => {
              event.preventDefault();
              panel.current?.focus({ preventScroll: true });
            }}
            onEscapeKeyDown={(event) => {
              if (body.current?.escape()) {
                event.preventDefault();
              }
            }}
            onPointerDownOutside={(event) => {
              // A toast's Undo is not a tap on the page behind.
              const target = event.target as HTMLElement | null;
              if (target?.closest("[data-sonner-toaster]")) {
                event.preventDefault();
              }
            }}
            onKeyDownCapture={(event) => {
              if (body.current?.shortcut(event.nativeEvent)) {
                event.preventDefault();
                event.stopPropagation();
              }
            }}
            style={{ background: noteBackground(note.color, brightness, palette), transformOrigin: "0 0" }}
            className={cn(
              "pointer-events-auto relative flex flex-col overflow-hidden text-on-surface outline-none transition-[background-color] duration-240 ease-standard",
              wide ? "max-h-[85dvh] w-full max-w-[600px] rounded-md shadow-dialog" : "h-dvh w-full",
            )}
          >
            <DialogPrimitive.Title className="sr-only">{note.title.trim() || "Note"}</DialogPrimitive.Title>
            <NotePattern pattern={note.pattern} />
            <div ref={face} className="relative flex min-h-0 flex-1 flex-col">
              <EditorBody noteId={noteId} wide={wide} onClose={requestClose} handleRef={body} />
            </div>
          </DialogPrimitive.Content>
        </div>
      </DialogPrimitive.Portal>
    </DialogPrimitive.Root>
  );
}
