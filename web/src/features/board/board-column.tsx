"use client";

import type { HTMLAttributes, Ref } from "react";
import { useDroppable } from "@dnd-kit/core";
import { SortableContext, verticalListSortingStrategy } from "@dnd-kit/sortable";
import { ChevronsLeft, ChevronsRight, EllipsisVertical, ListChecks, Pencil, Plus, Square, SquareCheckBig, SquareMinus, Trash2 } from "lucide-react";
import { AnimatePresence, LayoutGroup, motion, useReducedMotion } from "motion/react";
import { cn } from "cn";

import { IconButton } from "@/components/common/icon-button";
import { MenuLabel } from "@/components/common/menu-label";
import { Reveal } from "@/components/common/reveal";
import { RollingCount } from "@/components/common/rolling-count";
import { Button } from "@/components/ui/button";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { navigate } from "@/lib/router";
import { useComposeLabelIds, useNotesController } from "@/lib/store";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";
import { normalizeHex } from "@/lib/theme/palette";

import { BoardCard } from "./board-card";
import { UNASSIGNED_KEY, type ColumnIds, type ColumnSelection } from "./board-drag";

// One column of the board: a header on the canvas and the trough its cards
// sit in. The same component serves both layouts, side by side on a wide
// screen and one per page on a phone; only the container differs.
//
//   Title ............ [select] [ 3 ] [...]     header (canvas)
//   +==================================+        stage rule (its colour)
//   |  [ + Add note ]                  |        trough
//   |  card                            |
//   |  card                            |
//   +----------------------------------+

export const COLUMN_WIDTH = 300;
export const COLLAPSED_WIDTH = 52;

export const columnDroppableId = (key: string): string => `column:${key}`;

export function columnTitleOf(column: ColumnIds): string {
  return column.stage?.name ?? "Unassigned";
}

/** Compose a note filed in [stageId] from birth, as composing into a label view does. */
export function useAddNoteToStage(): (stageId: string | null) => void {
  const notes = useNotesController();
  const labelIds = useComposeLabelIds();
  return (stageId) => {
    const draft = notes.createDraft({ stageId, labelIds });
    notes.beginEditing(draft.id, "new");
    navigate({ name: "note", noteId: draft.id });
  };
}

export interface ColumnDragHandle {
  readonly ref: Ref<HTMLElement>;
  readonly props: HTMLAttributes<HTMLElement>;
}

export interface BoardColumnProps {
  readonly column: ColumnIds;
  readonly layout: "wide" | "paged";
  readonly dragEnabled: boolean;
  readonly dragging: boolean;
  readonly dimmedIds: ReadonlySet<string>;
  /** A card from another column hovers this one. */
  readonly highlighted: boolean;
  readonly collapsed: boolean;
  readonly onToggleCollapsed?: () => void;
  readonly selectionMode: boolean;
  readonly selection: ColumnSelection;
  /** Null when the column holds nothing to select. */
  readonly onToggleSelection: (() => void) | null;
  /** The "show the rest" tail of a capped Unassigned column. */
  readonly onShowAll?: () => void;
  readonly onEditStage: (stageId: string) => void;
  readonly onDeleteStage: (stageId: string) => void;
  /** Picks the column up to reorder it (wide, stage columns only). */
  readonly handle?: ColumnDragHandle;
}

export function BoardColumnView(props: BoardColumnProps) {
  const { column, layout, collapsed, highlighted } = props;
  const reduced = useReducedMotion();
  const { setNodeRef } = useDroppable({ id: columnDroppableId(column.key), data: { type: "column", key: column.key } });
  const fade = transitionFor(TRANSITION.base, reduced);
  const width = layout === "paged" ? undefined : collapsed ? COLLAPSED_WIDTH : COLUMN_WIDTH;

  return (
    <motion.section
      ref={setNodeRef}
      aria-label={columnTitleOf(column)}
      initial={false}
      animate={width === undefined ? undefined : { width }}
      transition={fade}
      className={cn("relative h-full shrink-0 overflow-hidden rounded-md", layout === "paged" && "w-full")}
      style={width === undefined ? undefined : { width }}
    >
      {/* The tint sits behind the trough, the ring above it, so the stage
          rule reaches the edges whether or not a card is hovering. */}
      <div aria-hidden className={cn("pointer-events-none absolute inset-0 rounded-md bg-primary/8 transition-opacity duration-150 ease-standard", highlighted ? "opacity-100" : "opacity-0")} />
      <AnimatePresence initial={false}>
        {collapsed ? (
          <motion.div key="collapsed" className="absolute inset-y-0 left-0" style={{ width: COLLAPSED_WIDTH }} initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={fade}>
            <CollapsedRail column={column} onExpand={props.onToggleCollapsed} />
          </motion.div>
        ) : (
          <motion.div
            key="expanded"
            className={cn("flex h-full flex-col", layout === "wide" && "absolute inset-y-0 left-0")}
            // A fixed width while the column grows, so its contents do not reflow.
            style={layout === "wide" ? { width: COLUMN_WIDTH } : undefined}
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={fade}
          >
            {layout === "wide" ? (
              <ColumnHeader {...props} />
            ) : (
              // The phone's strip names the column, so only the selection toggle needs a row.
              <Reveal>
                {props.selectionMode && props.onToggleSelection ? (
                  <div className="flex justify-end px-2 pb-1">
                    <Button variant="ghost" size="sm" onClick={props.onToggleSelection}>
                      <SelectionIcon selection={props.selection} />
                      {props.selection === "all" ? "Deselect all" : "Select all"}
                    </Button>
                  </div>
                ) : null}
              </Reveal>
            )}
            <Trough {...props} />
          </motion.div>
        )}
      </AnimatePresence>
      <div aria-hidden className={cn("pointer-events-none absolute inset-0 rounded-md ring-2 ring-primary ring-inset transition-opacity duration-150 ease-standard", highlighted ? "opacity-100" : "opacity-0")} />
    </motion.section>
  );
}

/** The stage's colour, capping the trough; uncoloured columns use the trough's edge. */
function StageRule({ column }: { column: ColumnIds }) {
  const hex = normalizeHex(column.stage?.color);
  return <div aria-hidden className="h-[3px] shrink-0 bg-trough-border" style={hex ? { background: hex } : undefined} />;
}

function Trough(props: BoardColumnProps) {
  const { column, dragEnabled, dragging, dimmedIds } = props;
  const addNote = useAddNoteToStage();
  const hidden = column.totalCount - column.ids.length;
  const stageId = column.key === UNASSIGNED_KEY ? null : column.key;

  return (
    <div className="flex min-h-0 flex-1 flex-col overflow-hidden rounded-md border border-trough-border bg-trough">
      <StageRule column={column} />
      <div className="px-2 pt-2">
        {/* Quiet grey, not the accent: every column has one. */}
        <button
          type="button"
          onClick={() => addNote(stageId)}
          className="flex h-8 w-full items-center justify-center gap-1.5 rounded-md bg-on-surface/7 text-sm font-medium text-on-surface-variant transition-colors duration-150 ease-standard outline-none hover:bg-on-surface/10 hover:text-on-surface active:bg-on-surface/12 focus-visible:ring-[3px] focus-visible:ring-ring/50"
        >
          <Plus className="size-4" />
          Add note
        </button>
      </div>
      <motion.div layoutScroll className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-2 pt-2 pb-24">
        <SortableContext id={column.key} items={column.ids as string[]} strategy={verticalListSortingStrategy}>
          <LayoutGroup id={column.key}>
            <div className="flex flex-col gap-2">
              <AnimatePresence initial={false} custom={dragging}>
                {column.ids.map((id) => (
                  <BoardCard key={id} noteId={id} dragEnabled={dragEnabled} dragging={dragging} dimmed={dimmedIds.has(id)} />
                ))}
              </AnimatePresence>
            </div>
          </LayoutGroup>
        </SortableContext>
        {column.ids.length === 0 ? (
          <p className="px-4 py-6 text-center text-xs text-on-surface-variant">
            {column.stage === null ? "Notes you have not placed yet appear here" : "Drop notes here"}
          </p>
        ) : null}
        {hidden > 0 ? (
          // Says how much is held back, so nothing is silently missing.
          <Button variant="outline" size="sm" className="mt-2 w-full text-on-surface-variant" onClick={props.onShowAll}>
            Show {hidden} more
          </Button>
        ) : null}
      </motion.div>
    </div>
  );
}

function SelectionIcon({ selection }: { selection: ColumnSelection }) {
  switch (selection) {
    case "none":
      return <Square />;
    case "some":
      return <SquareMinus />;
    case "all":
      return <SquareCheckBig />;
  }
}

function ColumnHeader(props: BoardColumnProps) {
  const { column, selection, onToggleSelection, selectionMode, handle } = props;
  const title = columnTitleOf(column);
  const stage = column.stage;
  const hasMenu = stage !== null || onToggleSelection !== null;
  const all = selection === "all";

  return (
    <div className="group/header flex h-11 shrink-0 items-center gap-1 pb-1">
      {props.onToggleCollapsed ? <IconButton label={`Collapse ${title}`} size="sm" icon={<ChevronsLeft />} onClick={props.onToggleCollapsed} /> : null}
      <h2
        ref={handle?.ref as Ref<HTMLHeadingElement> | undefined}
        {...handle?.props}
        className={cn("min-w-0 flex-1 truncate rounded-xs pl-1 text-sm font-semibold text-on-surface outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50", handle && "cursor-grab touch-none active:cursor-grabbing")}
      >
        {title}
      </h2>
      {onToggleSelection ? (
        <IconButton
          label={all ? `Deselect all in ${title}` : `Select all in ${title}`}
          size="sm"
          icon={<SelectionIcon selection={selection} />}
          onClick={onToggleSelection}
          className={cn(
            "transition-opacity duration-150 ease-standard focus-visible:opacity-100 [@media(hover:none)]:opacity-100",
            selectionMode || selection !== "none" ? "opacity-100" : "opacity-0 group-hover/header:opacity-100",
            all && "text-primary",
          )}
        />
      ) : null}
      <span className="ml-1 inline-flex min-w-10 justify-center rounded-md border border-trough-border bg-surface px-1.5 py-0.5 text-2xs text-on-surface-variant">
        <RollingCount count={column.totalCount} />
      </span>
      {hasMenu ? (
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <IconButton label={`${title} options`} size="sm" icon={<EllipsisVertical />} />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className="min-w-56">
            {onToggleSelection && !all ? (
              <DropdownMenuItem onSelect={onToggleSelection}>
                <ListChecks />
                <MenuLabel label="Select all cards" />
              </DropdownMenuItem>
            ) : null}
            {stage ? (
              <>
                <DropdownMenuItem onSelect={() => props.onEditStage(stage.id)}>
                  <Pencil />
                  <MenuLabel label="Edit column" hint="Name and colour" />
                </DropdownMenuItem>
                <DropdownMenuItem variant="destructive" onSelect={() => props.onDeleteStage(stage.id)}>
                  <Trash2 />
                  <MenuLabel label="Delete column" hint="Its notes go back to Unassigned" tone="destructive" />
                </DropdownMenuItem>
              </>
            ) : null}
          </DropdownMenuContent>
        </DropdownMenu>
      ) : (
        <span className="w-2" />
      )}
    </div>
  );
}

function CollapsedRail({ column, onExpand }: { column: ColumnIds; onExpand?: () => void }) {
  const title = columnTitleOf(column);
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <button
          type="button"
          onClick={onExpand}
          aria-label={`Expand ${title}`}
          className="flex h-full w-full flex-col overflow-hidden rounded-md border border-trough-border bg-trough text-on-surface-variant outline-none transition-colors duration-150 ease-standard hover:text-on-surface focus-visible:ring-[3px] focus-visible:ring-ring/50"
        >
          <StageRule column={column} />
          <span className="flex flex-1 flex-col items-center justify-center gap-2 py-4">
            <ChevronsRight className="size-5" />
            <span className="rotate-180 text-sm font-medium whitespace-nowrap [writing-mode:vertical-rl]">
              {title} ({column.totalCount})
            </span>
            <span className="rotate-180 text-2xs [writing-mode:vertical-rl]">Expand</span>
          </span>
        </button>
      </TooltipTrigger>
      <TooltipContent side="right">Expand {title}</TooltipContent>
    </Tooltip>
  );
}
