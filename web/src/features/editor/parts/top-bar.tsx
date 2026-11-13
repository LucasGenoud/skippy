import { useEffect, useRef } from "react";
import { ArrowLeft, ChevronDown, ChevronUp, Eye, MoreVertical, Pencil, RotateCcw, Search, Trash2, X } from "lucide-react";
import { cn } from "cn";

import { TooltipProvider } from "@/components/ui/tooltip";
import { IconButton } from "@/components/common/icon-button";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { CrossFade } from "@/components/common/reveal";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";
import type { NoteKind, NoteRewriteTask } from "@/lib/models/note";
import { NoteActionsMenu } from "@/features/notes";
import { PinIcon } from "@/features/notes/pin-icon";
import { Spinner } from "@/features/notes/link-summary-indicator";

// The editor's top bar (`_buildAppBar` in editor_screen.dart). Find-in-note
// swaps every action for its own field; a trashed note offers restore and
// delete; a live one pin and the note's actions, which hold find, archive,
// sharing, conversion and rewrites. The bar's two halves cross-fade when the
// mode changes.

export interface TopBarProps {
  noteId: string;
  wide: boolean;
  onClose(): void;
  trashed: boolean;
  pinned: boolean;
  rewriting: boolean;
  finding: boolean;
  findQuery: string;
  matchCount: number;
  matchIndex: number;
  onFindQuery(query: string): void;
  onFindStep(step: 1 | -1): void;
  onOpenFind(): void;
  onCloseFind(): void;
  preview: boolean | null;
  onTogglePreview(): void;
  onTogglePin(): void;
  onArchive: (() => void) | null;
  onShare: (() => void) | null;
  onRestore(): void;
  onDeleteForever(): void;
  onConvert: ((kind: NoteKind) => void) | null;
  onRewrite: ((task: NoteRewriteTask) => void) | null;
}

function FindField(props: TopBarProps) {
  const input = useRef<HTMLInputElement>(null);
  useEffect(() => {
    input.current?.focus();
  }, []);
  const hasQuery = props.findQuery.trim() !== "";
  return (
    <div className="flex min-w-0 flex-1 items-center gap-1">
      <Search aria-hidden className="size-4 shrink-0 text-on-surface-variant" />
      <input
        ref={input}
        value={props.findQuery}
        onChange={(e) => props.onFindQuery(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            props.onFindStep(e.shiftKey ? -1 : 1);
          }
        }}
        placeholder="Find in note"
        aria-label="Find in note"
        className="h-9 min-w-0 flex-1 bg-transparent px-1 text-sm text-on-surface outline-none placeholder:text-on-surface-variant/70"
      />
      {hasQuery ? (
        <span className="shrink-0 text-xs text-on-surface-variant tabular-nums" aria-live="polite">
          {props.matchCount === 0 ? "0 found" : `${props.matchIndex + 1} of ${props.matchCount}`}
        </span>
      ) : null}
      <IconButton size="sm" label="Previous match" icon={<ChevronUp />} disabled={props.matchCount === 0} onClick={() => props.onFindStep(-1)} />
      <IconButton size="sm" label="Next match" icon={<ChevronDown />} disabled={props.matchCount === 0} onClick={() => props.onFindStep(1)} />
      <IconButton size="sm" label="Close search" icon={<X />} onClick={props.onCloseFind} />
    </div>
  );
}

export function TopBar(props: TopBarProps) {
  const reduced = useReducedMotion();
  return (
    <TooltipProvider>
      <header className={cn("flex h-14 shrink-0 items-center gap-1 px-2", !props.wide && "border-b border-hairline")}>
        <IconButton label={props.wide ? "Close" : "Back"} icon={props.wide ? <X /> : <ArrowLeft />} onClick={props.onClose} />
        <div className="grid min-w-0 flex-1 grid-cols-1">
          <CrossFade stateKey={props.finding} className="col-start-1 row-start-1 min-w-0 justify-self-stretch">
            {props.finding ? <FindField {...props} /> : <span />}
          </CrossFade>
        </div>
        {/* Find and the note's actions trade one slot: the actions fade out over the field, not off a cliff. */}
        <AnimatePresence initial={false} mode="popLayout">
          {props.finding ? null : (
            <motion.div
              key="actions"
              className="flex items-center gap-0.5"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0, pointerEvents: "none" }}
              transition={transitionFor(TRANSITION.fast, reduced)}
            >
              {props.preview !== null && !props.trashed ? (
                <CrossFade stateKey={props.preview}>
                  <IconButton
                    label={props.preview ? "Edit markdown" : "Preview"}
                    icon={props.preview ? <Pencil /> : <Eye />}
                    onClick={props.onTogglePreview}
                  />
                </CrossFade>
              ) : null}
              {props.trashed ? (
                <>
                  <IconButton label="Restore" icon={<RotateCcw />} onClick={props.onRestore} />
                  <IconButton label="Delete forever" icon={<Trash2 />} onClick={props.onDeleteForever} />
                </>
              ) : (
                <IconButton label={props.pinned ? "Unpin" : "Pin"} icon={<PinIcon pinned={props.pinned} />} active={props.pinned} onClick={props.onTogglePin} />
              )}
              <NoteActionsMenu
                noteId={props.noteId}
                surface="editor"
                onFind={props.onOpenFind}
                onArchive={props.onArchive ?? undefined}
                onShare={props.onShare ?? undefined}
                onConvert={props.onConvert ?? undefined}
                onRewrite={props.onRewrite ?? undefined}
              >
                <IconButton label="Note actions" icon={props.rewriting ? <Spinner className="size-4" /> : <MoreVertical />} />
              </NoteActionsMenu>
            </motion.div>
          )}
        </AnimatePresence>
      </header>
    </TooltipProvider>
  );
}
