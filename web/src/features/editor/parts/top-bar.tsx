"use client";

import { useEffect, useRef, type ReactNode } from "react";
import {
  Archive,
  ArchiveRestore,
  ArrowLeft,
  ChevronDown,
  ChevronUp,
  Eye,
  ListChecks,
  MoreVertical,
  NotebookText,
  Pencil,
  RotateCcw,
  Search,
  SquareCode,
  Trash2,
  UserPlus,
  WandSparkles,
  X,
} from "lucide-react";
import { cn } from "cn";

import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { TooltipProvider } from "@/components/ui/tooltip";
import { IconButton } from "@/components/common/icon-button";
import { MenuLabel } from "@/components/common/menu-label";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { CrossFade } from "@/components/common/reveal";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";
import type { NoteKind, NoteRewriteTask } from "@/lib/models/note";
import { NoteActionsMenu } from "@/features/notes";
import { PinIcon } from "@/features/notes/pin-icon";
import { Spinner } from "@/features/notes/link-summary-indicator";
import { isApplePlatform } from "../lib/hooks";

// The editor's top bar (`_buildAppBar` in editor_screen.dart). Find-in-note
// swaps every action for its own field; a trashed note offers restore and
// delete; a live one pin, archive, collaborators, the editing tools, and the
// note's own menu. The bar's two halves cross-fade when the mode changes.

const KIND_LABELS: Record<Exclude<NoteKind, "audio">, { label: string; icon: ReactNode }> = {
  text: { label: "Text", icon: <NotebookText /> },
  checklist: { label: "Checklist", icon: <ListChecks /> },
  markdown: { label: "Markdown", icon: <SquareCode /> },
};

export interface TopBarProps {
  noteId: string;
  wide: boolean;
  onClose(): void;
  kind: NoteKind;
  trashed: boolean;
  pinned: boolean;
  archived: boolean;
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
  rewriteTasks: readonly NoteRewriteTask[];
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

function ToolsMenu(props: TopBarProps) {
  const targets = (["text", "checklist", "markdown"] as const).filter((k) => k !== props.kind);
  const rewrite = props.onRewrite && props.rewriteTasks.length > 0 && props.kind !== "audio";
  const mod = isApplePlatform() ? "⌘" : "Ctrl+";
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <IconButton label="Editing tools" icon={props.rewriting ? <Spinner className="size-4" /> : <WandSparkles />} />
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-64">
        <DropdownMenuItem onSelect={props.onOpenFind}>
          <Search />
          <MenuLabel label="Find in note" hint={`${mod}F`} />
        </DropdownMenuItem>
        {props.onConvert ? (
          <>
            <DropdownMenuSeparator />
            <DropdownMenuLabel>Turn into</DropdownMenuLabel>
            {targets.map((kind) => (
              <DropdownMenuItem key={kind} onSelect={() => props.onConvert?.(kind)}>
                {KIND_LABELS[kind].icon}
                <MenuLabel label={KIND_LABELS[kind].label} />
              </DropdownMenuItem>
            ))}
          </>
        ) : null}
        {rewrite ? (
          <>
            <DropdownMenuSeparator />
            <DropdownMenuLabel>Rewrite with AI</DropdownMenuLabel>
            {props.rewriteTasks.map((task) => (
              <DropdownMenuItem key={task.id} disabled={props.rewriting} onSelect={() => props.onRewrite?.(task)}>
                <WandSparkles />
                <MenuLabel label={task.name} />
              </DropdownMenuItem>
            ))}
          </>
        ) : null}
      </DropdownMenuContent>
    </DropdownMenu>
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
                <>
                  <IconButton label={props.pinned ? "Unpin" : "Pin"} icon={<PinIcon pinned={props.pinned} />} active={props.pinned} onClick={props.onTogglePin} />
                  {props.onArchive ? (
                    <IconButton label={props.archived ? "Unarchive" : "Archive"} icon={props.archived ? <ArchiveRestore /> : <Archive />} onClick={props.onArchive} />
                  ) : null}
                  {props.onShare ? <IconButton label="Collaborators" icon={<UserPlus />} onClick={props.onShare} /> : null}
                  <ToolsMenu {...props} />
                </>
              )}
              <NoteActionsMenu noteId={props.noteId} surface="editor">
                <IconButton label="Note actions" icon={<MoreVertical />} />
              </NoteActionsMenu>
            </motion.div>
          )}
        </AnimatePresence>
      </header>
    </TooltipProvider>
  );
}
