"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { ArrowLeft, CloudOff, History, RotateCcw } from "lucide-react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { cn } from "cn";

import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/common/empty-state";
import { IconButton } from "@/components/common/icon-button";
import { useOverlayPresence } from "@/components/common/overlay-presence";
import { CrossFade } from "@/components/common/reveal";
import { showAppSnack } from "@/components/common/snack";
import { StaggeredEntrance } from "@/components/common/staggered-entrance";
import type { ChecklistItem, NoteKind, NoteVersion } from "@/lib/models/note";
import { formatClock, formatDate, useNote, useNotesController, useSession, useSettings } from "@/lib/store";
import { TRANSITION, pageVariants, transitionFor } from "@/lib/theme/motion";

// A note's version timeline (`history_screen.dart`): the current state on top,
// then every earlier version newest first, each restorable. The server saves
// the current state before restoring, so a restore can itself be undone here.

const PREVIEW_ROWS = 8;

type Load = { state: "loading" } | { state: "failed" } | { state: "ready"; versions: readonly NoteVersion[] };

function CheckMark({ checked }: { checked: boolean }) {
  return (
    <span
      aria-hidden
      className={
        checked
          ? "mt-[3px] inline-flex size-3.5 shrink-0 items-center justify-center rounded-check bg-primary-container text-[9px] leading-none text-on-primary-container"
          : "mt-[3px] inline-block size-3.5 shrink-0 rounded-check border-[1.5px] border-on-surface-variant/70"
      }
    >
      {checked ? "✓" : null}
    </span>
  );
}

function VersionPreview({ kind, title, content, items }: { kind: NoteKind; title: string; content: string; items: readonly ChecklistItem[] }) {
  const hasTitle = title.trim() !== "";
  const shown = items.slice(0, PREVIEW_ROWS);
  const empty = !hasTitle && (kind === "checklist" ? items.length === 0 : content.trim() === "");
  if (empty) {
    return <p className="text-sm text-on-surface-variant italic">Empty note</p>;
  }
  return (
    <div className="flex flex-col gap-1">
      {hasTitle ? <p className="line-clamp-2 text-sm font-semibold text-on-surface">{title}</p> : null}
      {kind === "checklist" ? (
        <>
          {shown.map((item) => (
            <div key={item.id} className="flex items-start gap-1.5" style={{ paddingLeft: item.depth * 16 }}>
              <CheckMark checked={item.done} />
              <span className={item.done ? "line-clamp-2 text-sm text-on-surface-variant line-through" : "line-clamp-2 text-sm text-on-surface"}>
                {item.text || " "}
              </span>
            </div>
          ))}
          {items.length > shown.length ? <p className="text-2xs text-on-surface-variant">+{items.length - shown.length} more</p> : null}
        </>
      ) : content.trim() !== "" ? (
        <p className="line-clamp-[8] text-sm whitespace-pre-wrap text-on-surface">{content}</p>
      ) : null}
    </div>
  );
}

function VersionCard({
  stamp,
  author,
  current,
  children,
  onRestore,
  restoring,
}: {
  stamp: string;
  author: string | null;
  current: boolean;
  children: React.ReactNode;
  onRestore: (() => void) | null;
  restoring: boolean;
}) {
  return (
    <article className="flex flex-col gap-2 rounded-md bg-surface p-4 shadow-card">
      <header className="flex items-center gap-2">
        <p className="min-w-0 flex-1 truncate text-sm font-medium text-on-surface">
          {stamp}
          {author ? <span className="font-normal text-on-surface-variant">{`  ·  ${author}`}</span> : null}
        </p>
        {current ? <span className="rounded-md bg-secondary-container px-2 py-0.5 text-2xs font-medium text-on-secondary-container">Current</span> : null}
      </header>
      {children}
      {onRestore || restoring ? (
        <div className="flex justify-end">
          <CrossFade stateKey={restoring}>
            {restoring ? (
              <span aria-label="Restoring" className="m-2 size-[18px] animate-spin rounded-full border-2 border-on-surface-variant/30 border-t-primary" />
            ) : (
              <Button variant="ghost" size="sm" onClick={() => onRestore?.()}>
                <RotateCcw />
                Restore
              </Button>
            )}
          </CrossFade>
        </div>
      ) : null}
    </article>
  );
}

export default function HistoryScreen({ noteId, onClose }: { noteId: string; onClose(): void }) {
  const notes = useNotesController();
  const { userId } = useSession();
  const note = useNote(noteId);
  const dateFormat = useSettings((s) => s.dateFormat);
  const use24h = useSettings((s) => s.use24hTime);
  const reduced = useReducedMotion();
  const [load, setLoad] = useState<Load>({ state: "loading" });
  const [restoringId, setRestoringId] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<NoteVersion | null>(null);
  const presence = useOverlayPresence();
  const closed = useRef(false);

  // Back, Escape and a restore all leave through here, once: the route then
  // leaving is what plays the exit, so browser back looks the same.
  const close = useCallback(() => {
    if (closed.current || !presence.present) {
      return;
    }
    closed.current = true;
    onClose();
  }, [onClose, presence.present]);

  useEffect(() => {
    if (!presence.present && reduced) {
      presence.safeToRemove();
    }
  }, [presence, reduced]);

  const stamp = useCallback(
    (t: Date) => `${formatDate(t, dateFormat, t.getFullYear() !== new Date().getFullYear())} · ${formatClock(t, use24h)}`,
    [dateFormat, use24h],
  );

  const fetchVersions = useCallback(() => {
    setLoad({ state: "loading" });
    notes.noteVersions(noteId).then(
      (versions) => setLoad({ state: "ready", versions }),
      () => setLoad({ state: "failed" }),
    );
  }, [notes, noteId]);

  useEffect(() => {
    let live = true;
    notes.noteVersions(noteId).then(
      (versions) => live && setLoad({ state: "ready", versions }),
      () => live && setLoad({ state: "failed" }),
    );
    return () => {
      live = false;
    };
  }, [notes, noteId]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === "Escape" && confirm === null) {
        close();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [close, confirm]);

  const restore = async (version: NoteVersion): Promise<void> => {
    setRestoringId(version.id);
    try {
      await notes.restoreNoteVersion(noteId, version.id);
      close();
      showAppSnack(`Restored version from ${stamp(version.createdAt)}`, { icon: History });
    } catch {
      setRestoringId(null);
      showAppSnack("Couldn't restore this version");
    }
  };

  const canRestore = note !== null && !note.trashed;
  const authorOf = (version: NoteVersion): string | null =>
    version.editedBy === null || version.editedBy.id === userId ? null : version.editedBy.name;

  let body;
  if (load.state === "loading") {
    body = (
      <div key="loading" className="flex flex-col gap-3">
        {[0, 1, 2].map((i) => (
          <Skeleton key={i} className="h-28 w-full" />
        ))}
      </div>
    );
  } else if (load.state === "failed") {
    body = (
      <div key="failed" className="pt-16">
        <EmptyState icon={CloudOff} message="Couldn't load history" actionLabel="Try again" onAction={fetchVersions} />
      </div>
    );
  } else {
    body = (
      <div key="ready" className="flex flex-col gap-3">
        {note ? (
          <VersionCard stamp={stamp(note.updatedAt)} author={null} current onRestore={null} restoring={false}>
            <VersionPreview kind={note.kind} title={note.title} content={note.content} items={note.items} />
          </VersionCard>
        ) : null}
        {load.versions.length === 0 ? (
          <p className="py-8 text-center text-sm text-on-surface-variant">
            No earlier versions yet.
            <br />
            Edits you make from now on are saved here automatically.
          </p>
        ) : null}
        {load.versions.map((version, index) => (
          <StaggeredEntrance key={version.id} index={index + 1}>
            <VersionCard
              stamp={stamp(version.createdAt)}
              author={authorOf(version)}
              current={false}
              onRestore={canRestore && restoringId === null ? () => setConfirm(version) : null}
              restoring={restoringId === version.id}
            >
              <VersionPreview kind={version.kind} title={version.title} content={version.content} items={version.items} />
            </VersionCard>
          </StaggeredEntrance>
        ))}
      </div>
    );
  }

  return (
    <motion.div
      role="dialog"
      aria-modal="true"
      aria-label="Version history"
      // A page pushed over the note, leaving the way it came (also on browser back).
      variants={pageVariants(reduced)}
      initial="enter"
      animate={presence.present ? "shown" : "leave"}
      onAnimationComplete={(definition) => {
        if (definition === "leave") {
          presence.safeToRemove();
        }
      }}
      className={cn("fixed inset-0 z-50 flex flex-col bg-canvas", !presence.present && "pointer-events-none")}
    >
      <header className="flex h-14 shrink-0 items-center gap-2 border-b border-hairline bg-surface px-2">
        <IconButton label="Back" icon={<ArrowLeft />} onClick={close} />
        <h1 className="text-base font-semibold text-on-surface">Version history</h1>
      </header>
      <div className="min-h-0 flex-1 overflow-y-auto">
        <div className="mx-auto w-full max-w-[680px] px-4 pt-3 pb-6">
          <AnimatePresence mode="wait" initial={false}>
            <motion.div
              key={load.state}
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              transition={transitionFor(TRANSITION.base, reduced)}
            >
              {body}
            </motion.div>
          </AnimatePresence>
        </div>
      </div>
      <AlertDialog open={confirm !== null} onOpenChange={(open) => !open && setConfirm(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Restore this version?</AlertDialogTitle>
            <AlertDialogDescription>
              {confirm
                ? `The note will roll back to how it was on ${stamp(confirm.createdAt)}. The current version is saved to history first, so you can undo this.`
                : null}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                const version = confirm;
                setConfirm(null);
                if (version) {
                  void restore(version);
                }
              }}
            >
              Restore
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </motion.div>
  );
}
