"use client";

import { useState } from "react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { Archive, Bell, Bookmark, CloudOff, Kanban, LoaderCircle, SearchX, StickyNote, Tag, Trash2, type LucideIcon } from "lucide-react";
import { EmptyState } from "@/components/common/empty-state";
import { PageHeader } from "@/components/common/page-header";
import { CrossFade } from "@/components/common/reveal";
import { showAppSnack } from "@/components/common/snack";
import { Button } from "@/components/ui/button";
import {
  semanticSearchAvailable,
  useNotesController,
  useNotesLoading,
  useNotesSelector,
  useSavedViews,
  useSemanticActive,
  useSettings,
  useUi,
  useViewSelection,
  useVisibleNoteIds,
} from "@/lib/store";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";
import { useTitledBar } from "./responsive";
import { useNewNote, useOpenDestination } from "./shell-actions";
import { useShellDialogs } from "./shell-dialogs";
import { TRASH_NOTICE, emptyCopy, type EmptyIcon } from "./view-rules";

/** Which views the shell frames: the grid ones (the board and reminders lay out their own). */
export type GridFrame = "grid" | "other";

/**
 * The block a destination opens with (`_ViewHeader`). Wide, the top bar
 * names the view, so the block keeps only what the bar cannot say: Trash's
 * notice and "Empty trash".
 */
export function ViewHeader() {
  const selection = useViewSelection();
  const titled = useTitledBar();
  const views = useSavedViews();
  const label = useNotesSelector((s) => (selection.labelId ? (s.labels.find((l) => l.id === selection.labelId)?.name ?? null) : null), Object.is, [selection.labelId]);
  const reduced = useReducedMotion();

  let header: { key: string; title?: string; subtitle?: string; trailing?: React.ReactNode } | null = null;
  switch (selection.view) {
    case "trash":
      header = { key: "trash", title: titled ? undefined : "Trash", subtitle: TRASH_NOTICE, trailing: <EmptyTrashButton /> };
      break;
    case "archive":
      header = titled ? null : { key: "archive", title: "Archive" };
      break;
    case "label":
      header = titled || label === null ? null : { key: `label-${selection.labelId}`, title: label };
      break;
    case "smart": {
      const view = views.find((v) => v.id === selection.savedViewId);
      header = titled || !view ? null : { key: `smart-${view.id}`, title: view.name };
      break;
    }
    default:
      header = null;
  }

  return (
    <AnimatePresence initial={false} mode="popLayout">
      {header ? (
        <motion.div
          key={header.key}
          initial={{ opacity: 0, height: 0 }}
          animate={{ opacity: 1, height: "auto" }}
          exit={{ opacity: 0, height: 0 }}
          transition={transitionFor(TRANSITION.base, reduced)}
        >
          <PageHeader title={header.title} subtitle={header.subtitle} trailing={header.trailing} />
        </motion.div>
      ) : null}
    </AnimatePresence>
  );
}

function EmptyTrashButton() {
  const notes = useNotesController();
  const dialogs = useShellDialogs();
  const { others } = useVisibleNoteIds();
  const reduced = useReducedMotion();
  return (
    <AnimatePresence initial={false}>
      {others.length > 0 ? (
        <motion.span key="empty" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={transitionFor(TRANSITION.fast, reduced)}>
          <Button
            variant="ghost"
            size="sm"
            className="text-error hover:text-error"
            onClick={() =>
              dialogs.open({
                type: "confirm",
                title: "Empty trash?",
                description: "All notes in Trash will be permanently deleted.",
                confirmLabel: "Empty trash",
                tone: "destructive",
                onConfirm: () => {
                  notes.emptyTrash();
                  showAppSnack("Trash emptied", { icon: Trash2, kind: "danger" });
                },
              })
            }
          >
            <Trash2 />
            Empty trash
          </Button>
        </motion.span>
      ) : null}
    </AnimatePresence>
  );
}

/**
 * Shown once an outage is confirmed: what the user is looking at (their own
 * saved notes), that edits are not lost, and a retry now. Always mounted, so
 * going on- or offline grows and shrinks it instead of jolting the grid.
 */
export function OfflineBanner() {
  const offline = useNotesSelector((s) => s.offline);
  const notes = useNotesController();
  const [retrying, setRetrying] = useState(false);
  const reduced = useReducedMotion();

  const retry = async (): Promise<void> => {
    if (retrying) {
      return;
    }
    setRetrying(true);
    try {
      await notes.retryNow();
    } finally {
      setRetrying(false);
    }
  };

  return (
    <AnimatePresence initial={false}>
      {offline ? (
        <motion.div
          key="offline"
          initial={{ height: 0, opacity: 0 }}
          animate={{ height: "auto", opacity: 1 }}
          exit={{ height: 0, opacity: 0 }}
          transition={transitionFor(TRANSITION.base, reduced)}
          className="overflow-hidden"
        >
          <div role="status" className="mt-2 flex items-center gap-3 rounded-md bg-surface-container-highest px-4 py-1.5">
            <CloudOff aria-hidden className="size-5 shrink-0 text-on-surface-variant" />
            <p className="min-w-0 flex-1 text-xs text-on-surface-variant">Can&apos;t reach the server, showing your saved notes. Changes sync when the connection is back.</p>
            <Button variant="ghost" size="sm" disabled={retrying} onClick={() => void retry()} aria-label={retrying ? "Retrying" : "Retry"}>
              <CrossFade stateKey={retrying} className="justify-items-center">
                {retrying ? <LoaderCircle className="size-4 animate-spin" /> : "Retry"}
              </CrossFade>
            </Button>
          </div>
        </motion.div>
      ) : null}
    </AnimatePresence>
  );
}

const EMPTY_ICONS: Record<EmptyIcon, LucideIcon> = {
  search: SearchX,
  notes: StickyNote,
  board: Kanban,
  reminders: Bell,
  archive: Archive,
  trash: Trash2,
  label: Tag,
  smart: Bookmark,
};

/**
 * What an empty grid view says, and the one step it offers out of it
 * (`_emptyState`). Hidden while the first load or a first semantic search
 * is still on its way, when the grid shows skeletons instead.
 */
export function ViewEmptyState() {
  const selection = useViewSelection();
  const { pinned, others } = useVisibleNoteIds();
  const loading = useNotesLoading();
  const query = useUi((s) => s.query);
  const semanticActive = useSemanticActive();
  const rankedPending = useUi((s) => s.semantic.busy && s.semantic.ids === null);
  const ranking = useSettings(semanticSearchAvailable);
  const newNote = useNewNote();
  const open = useOpenDestination();

  const reduced = useReducedMotion();

  const waitingForRanking = ranking && semanticActive && rankedPending;
  const empty = !(loading || waitingForRanking || pinned.length + others.length > 0);
  const copy = emptyCopy(selection, query.trim() !== "");
  const action =
    copy.action === "browse"
      ? { label: "Browse notes", icon: StickyNote, run: () => open("notes") }
      : copy.action === "create"
        ? { label: "Create note", icon: undefined, run: () => newNote("text") }
        : null;
  // The first note to arrive fades the empty state out (lifted out of the
  // flow, so the grid does not wait under it) instead of cutting it.
  return (
    <AnimatePresence initial={false} mode="popLayout">
      {empty ? (
        // Fills what the scroll area has left, so the empty state sits centred in the view.
        <motion.div key="empty" className="flex flex-1 flex-col" exit={{ opacity: 0 }} transition={transitionFor(TRANSITION.fast, reduced)}>
          <EmptyState
            icon={EMPTY_ICONS[copy.icon]}
            message={copy.message}
            mark={copy.mark}
            actionLabel={action?.label}
            actionIcon={action?.icon}
            onAction={action?.run}
          />
        </motion.div>
      ) : null}
    </AnimatePresence>
  );
}
