"use client";

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { animate, useReducedMotion } from "motion/react";
import { Dialog as DialogPrimitive } from "radix-ui";
import { cn } from "cn";

import { useOverlayPresence } from "@/components/common/overlay-presence";
import { FadingPattern } from "@/features/notes/motion-kit";
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
// card that opened it and shrinking back into it. Escape, the close button,
// a tap outside and the browser's back button all close it through one path;
// the draft is flushed (and an empty one discarded) as it unmounts.
//
//   Esc / close / outside      browser back (route already left)
//            |                            |
//            +------> playClose() <-------+   one morph, shared promise
//                         |
//          route still here? -- yes --> onClose() navigates; the route
//                         |              leaving then finds the morph done
//                         no
//                         v
//                  safeToRemove()  -> unmount -> finalize the draft once

const MS = 1000;
/** The surface is opaque by this share of the opening morph (Flutter's `t * 4` on the emphasized curve). */
const OPEN_FADE_SHARE = 0.12;
/** Closing, the surface starts to dissolve into the card this far in (`t * 4` on the standard curve). */
const CLOSE_FADE_FROM = 0.37;

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
  // The dialog's portal mounts its content a render late, so the opening waits
  // for the panel itself rather than running once against a missing node.
  const [panelNode, setPanelNode] = useState<HTMLDivElement | null>(null);
  const attachPanel = useCallback((node: HTMLDivElement | null) => {
    panel.current = node;
    setPanelNode(node);
  }, []);
  const face = useRef<HTMLDivElement>(null);
  const scrim = useRef<HTMLDivElement>(null);
  const body = useRef<EditorBodyHandle>(null);
  const [closing, setClosing] = useState(false);
  const closingRun = useRef<Promise<void> | null>(null);
  const presence = useOverlayPresence();
  const presenceRef = useRef(presence);
  useLayoutEffect(() => {
    presenceRef.current = presence;
  }, [presence]);
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
    // The growing note reads as one opaque object leaving the grid, not a fade.
    animate(el, { opacity: [0, 1] }, { duration: duration * OPEN_FADE_SHARE, ease: [...EASE.standard] });
    void animate(
      el,
      { transform: [frame.transform, MORPH_REST.transform], clipPath: [frame.clipPath, MORPH_REST.clipPath] },
      { duration, ease: [...EASE.emphasized] },
    ).then(() => {
      // A close that began mid-open owns the transform from here.
      if (closingRun.current) {
        return;
      }
      el.style.clipPath = "";
      el.style.transform = "";
      done();
    });
    // The morph belongs to the opening only.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [exists, panelNode]);

  const closeMorph = async (): Promise<void> => {
    const el = panel.current;
    if (!el || reduced) {
      return;
    }
    const source = noteCardBox(noteId);
    const frame = source ? morphFrom(source, boxOf(el.getBoundingClientRect())) : null;
    // With no card to return to, the note fades out where it is, quicker.
    const duration = (frame ? DURATION.slow : DURATION.fast) / MS;
    if (scrim.current) {
      animate(scrim.current, { opacity: 0 }, { duration, ease: [...EASE.standard] });
    }
    if (!frame) {
      await animate(el, { opacity: 0, scale: 0.96 }, { duration, ease: [...EASE.standard] });
      return;
    }
    // Calmer on the way back in: easing into the card rather than arriving at
    // full speed, and dissolving into it over the second half.
    animate(el, { opacity: [1, 1, 0] }, { duration, times: [0, CLOSE_FADE_FROM, 1], ease: [...EASE.standard] });
    await animate(el, { transform: [MORPH_REST.transform, frame.transform], clipPath: [MORPH_REST.clipPath, frame.clipPath] }, { duration, ease: [...EASE.standard] });
  };

  // The close morph, played once however many ways ask for it.
  const playClose = (): Promise<void> => {
    if (closingRun.current) {
      return closingRun.current;
    }
    setClosing(true);
    if (document.activeElement instanceof HTMLElement) {
      document.activeElement.blur();
    }
    closingRun.current = closeMorph();
    return closingRun.current;
  };

  // Esc, the close button, a tap outside: shrink into the card, then leave the route.
  const requestClose = (): void => {
    if (closingRun.current) {
      return;
    }
    void playClose().then(() => {
      if (presenceRef.current.present) {
        onClose();
      } else {
        presenceRef.current.safeToRemove();
      }
    });
  };

  // The route left first (the browser's back): the same morph, then release.
  useEffect(() => {
    if (presence.present) {
      return;
    }
    void playClose().then(() => presence.safeToRemove());
    // playClose reads refs; the route leaving is the only trigger.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [presence]);

  if (!note) {
    return null;
  }

  return (
    <DialogPrimitive.Root open onOpenChange={(open) => !open && requestClose()}>
      <DialogPrimitive.Portal>
        <DialogPrimitive.Overlay ref={scrim} className="fixed inset-0 z-50 bg-[#0D101A]/45" />
        <div className={cn("pointer-events-none fixed inset-0 z-50 flex", wide ? "items-center justify-center p-4" : "")}>
          <DialogPrimitive.Content
            ref={attachPanel}
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
              "relative flex flex-col overflow-hidden text-on-surface outline-none transition-[background-color] duration-240 ease-standard",
              // A closing editor is on its way out: clicks reach nothing in it.
              closing ? "pointer-events-none" : "pointer-events-auto",
              wide ? "max-h-[85dvh] w-full max-w-[600px] rounded-xl shadow-dialog" : "h-dvh w-full",
            )}
          >
            <DialogPrimitive.Title className="sr-only">{note.title.trim() || "Note"}</DialogPrimitive.Title>
            <FadingPattern pattern={note.pattern} />
            <div ref={face} className="relative flex min-h-0 flex-1 flex-col">
              <EditorBody noteId={noteId} wide={wide} onClose={requestClose} handleRef={body} />
            </div>
          </DialogPrimitive.Content>
        </div>
      </DialogPrimitive.Portal>
    </DialogPrimitive.Root>
  );
}
