"use client";

import { useEffect, useRef, useState } from "react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { FileText, ListChecks, Mic, PenLine, Plus, type LucideIcon } from "lucide-react";
import type { NoteKind } from "@/lib/models/note";
import { composeLabelIdsOf, useUiController } from "@/lib/store";
import { DURATION, EASE, TRANSITION, transitionFor } from "@/lib/theme/motion";
import { useNewNote } from "./shell-actions";
import { useShellDialogs } from "./shell-dialogs";

// The note-creation button (`NewNoteFabs`). One button at rest, so nothing
// covers the grid; tapping it unfolds the kinds of note above it:
//
//         [ mic  Audio     ]
//         [ doc  Markdown  ]
//         [ box  Checklist ]
//         [ pen  Note      ]
//                       [+]

/** How far into the unfold each kind starts after the one below it. */
const STAGGER_S = 0.035;

const KINDS: readonly { kind: NoteKind | "audio-recording"; icon: LucideIcon; label: string }[] = [
  { kind: "audio-recording", icon: Mic, label: "Audio" },
  { kind: "markdown", icon: FileText, label: "Markdown" },
  { kind: "checklist", icon: ListChecks, label: "Checklist" },
  { kind: "text", icon: PenLine, label: "Note" },
];

export function HomeFabs() {
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  const reduced = useReducedMotion();
  const newNote = useNewNote();
  const dialogs = useShellDialogs();
  const ui = useUiController();

  // A tap anywhere else folds the menu.
  useEffect(() => {
    if (!open) {
      return;
    }
    const onDown = (event: PointerEvent): void => {
      if (root.current && !root.current.contains(event.target as Node)) {
        setOpen(false);
      }
    };
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === "Escape") {
        setOpen(false);
      }
    };
    document.addEventListener("pointerdown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("pointerdown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  const pick = (kind: NoteKind | "audio-recording"): void => {
    setOpen(false);
    if (kind === "audio-recording") {
      dialogs.open({ type: "recording", labelIds: composeLabelIdsOf(ui.state) });
      return;
    }
    newNote(kind);
  };

  return (
    <div ref={root} className="pointer-events-none flex flex-col items-end gap-2">
      <AnimatePresence>
        {open
          ? KINDS.map((entry, i) => {
              const fromButton = KINDS.length - 1 - i;
              return (
                <motion.button
                  key={entry.kind}
                  type="button"
                  onClick={() => pick(entry.kind)}
                  className="pointer-events-auto inline-flex h-12 items-center gap-3 rounded-md border border-outline-variant bg-surface px-4 text-sm font-semibold text-on-surface shadow-raised outline-none transition-colors duration-150 ease-standard hover:bg-[color-mix(in_srgb,var(--surface),var(--on-surface)_6%)] focus-visible:ring-[3px] focus-visible:ring-ring/50"
                  initial={reduced ? { opacity: 0 } : { opacity: 0, y: 12 }}
                  animate={{ opacity: 1, y: 0, transition: { duration: DURATION.base / 1000, ease: EASE.emphasized, delay: reduced ? 0 : fromButton * STAGGER_S } }}
                  exit={{ opacity: 0, y: reduced ? 0 : 12, transition: { duration: DURATION.fast / 1000, ease: EASE.standard, delay: reduced ? 0 : i * STAGGER_S * 0.5 } }}
                >
                  <entry.icon aria-hidden className="size-[18px] text-on-surface-variant" />
                  {entry.label}
                </motion.button>
              );
            })
          : null}
      </AnimatePresence>
      <motion.button
        type="button"
        aria-label={open ? "Close" : "New note"}
        aria-expanded={open}
        title={open ? "Close" : "New note"}
        onClick={() => setOpen((v) => !v)}
        whileHover={reduced ? undefined : { scale: 1.06 }}
        transition={transitionFor(TRANSITION.fast, reduced)}
        className="pointer-events-auto mt-1 inline-flex size-14 items-center justify-center rounded-md bg-primary-container text-on-primary-container shadow-raised outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50"
      >
        <motion.span animate={{ rotate: open ? 45 : 0 }} transition={transitionFor(TRANSITION.base, reduced)} className="inline-flex">
          <Plus className="size-7" />
        </motion.span>
      </motion.button>
    </div>
  );
}
