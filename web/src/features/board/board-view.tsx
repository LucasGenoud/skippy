"use client";

import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
import {
  DndContext,
  DragOverlay,
  KeyboardSensor,
  MeasuringStrategy,
  MouseSensor,
  TouchSensor,
  closestCenter,
  defaultDropAnimationSideEffects,
  pointerWithin,
  rectIntersection,
  useDroppable,
  useSensor,
  useSensors,
  type CollisionDetection,
  type DragEndEvent,
  type DragOverEvent,
  type DragStartEvent,
  type DropAnimation,
} from "@dnd-kit/core";
import { SortableContext, horizontalListSortingStrategy, sortableKeyboardCoordinates, useSortable } from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import { Archive, Plus, SquareKanban, Trash2 } from "lucide-react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { cn } from "cn";

import { EmptyState } from "@/components/common/empty-state";
import { RollingCount } from "@/components/common/rolling-count";
import { moveCardFocus } from "@/features/notes/card-focus";
import { NoteCard } from "@/features/notes/note-card";
import { boardOf, boardExitsFor, listIdentityEqual, semanticSearchAvailable, useActiveCollection, useActiveSort, useNav, useNotesController, useSelectedIds, useSettings, useUiController } from "@/lib/store";
import type { BoardExit } from "@/lib/store";
import { DURATION, EASE, TRANSITION, cssEase, transitionFor } from "@/lib/theme/motion";
import { normalizeHex } from "@/lib/theme/palette";

import { BoardColumnView, COLUMN_WIDTH, columnTitleOf, type ColumnDragHandle } from "./board-column";
import {
  canDropOnExit,
  canDropOnStage,
  columnIdsEqual,
  columnIdsOf,
  columnSelectionOf,
  containerOf,
  dragColumnsOf,
  draggedIdsFor,
  moveToColumn,
  moveWithin,
  pageAt,
  planCardDrop,
  stageIdOfKey,
  type BoardExitKind,
  type ColumnIds,
  type DragColumns,
} from "./board-drag";
import { EditStagesDialog, StageEditorDialog } from "./stage-editor";
import { swallowNextClick } from "./swallow-click";
import { PAGED_BREAKPOINT, useMinWidth } from "./use-viewport";

// The board: one column per stage of the active collection, after Unassigned.
// Wide screens lay the columns side by side and scroll them sideways; phones
// page through them one at a time behind a strip of column chips, because a
// row of 300px columns on a 375px screen is a worse grid, not a board.
//
//   wide                                        phone
//   [Unassigned][Doing][Done][Archive][+ Add]   [Unassigned 3][Doing 2][+]
//    trough      trough trough  /Trash           +----------------------+
//                                                | the open column      |
//
// Dragging: cards reorder within a column and move between columns (one
// `setNoteStage` per card carrying stage and position); on a phone a card is
// carried up to a chip instead of across pages. Stage columns reorder by their
// title on wide screens, and in the column editor everywhere.

/** How far a touch may wander and still count as a stationary long press. */
const STATIONARY_PX = 8;
const TOUCH_HOLD_MS = 250;
const TOUCH_TOLERANCE_PX = 8;
const MOUSE_DISTANCE_PX = 6;
const EXITS_WIDTH = 180;
/** Phone pages leave the neighbours peeking in at either edge. */
const PAGE_FRACTION = 0.86;

const stageSortId = (id: string): string => `stage:${id}`;
const exitId = (exit: BoardExitKind): string => `exit:${exit}`;
const chipId = (key: string): string => `chip:${key}`;

type DragKind = "card" | "stage" | "column" | "exit" | "chip";

function kindOf(id: string | number | undefined, data?: { type?: unknown }): DragKind | null {
  const type = data?.type;
  if (type === "card" || type === "stage" || type === "column" || type === "exit" || type === "chip") {
    return type;
  }
  if (typeof id !== "string") {
    return null;
  }
  if (id.startsWith("column:")) {
    return "column";
  }
  if (id.startsWith("exit:")) {
    return "exit";
  }
  if (id.startsWith("chip:")) {
    return "chip";
  }
  return null;
}

const suffix = (id: string): string => id.slice(id.indexOf(":") + 1);

/** Columns as ids, so a card's change re-renders the card, not the board. */
function useBoardColumns(showAll: boolean): ColumnIds[] {
  const ranking = useSettings((s) => semanticSearchAvailable(s) && s.semanticRanking);
  return useNav((notes, ui) => columnIdsOf(boardOf(notes, ui, ranking, showAll)), columnIdsEqual, [ranking, showAll]);
}

export function BoardView() {
  const collection = useActiveCollection();
  // Per-visit state (collapsed columns, the Unassigned cap) resets with the collection.
  return <BoardBody key={collection?.id ?? "none"} collectionId={collection?.id ?? null} />;
}

type Dialogs = { kind: "stages" } | { kind: "stage"; stageId: string | null } | null;

function BoardBody({ collectionId }: { collectionId: string | null }) {
  const [showAll, setShowAll] = useState(false);
  const [dialog, setDialog] = useState<Dialogs>(null);
  const [dialogOpen, setDialogOpen] = useState(false);
  const columns = useBoardColumns(showAll);
  const exits = useSettings((s) => boardExitsFor(s, collectionId), listIdentityEqual);
  const wide = useMinWidth(PAGED_BREAKPOINT);
  const notes = useNotesController();

  const open = (next: NonNullable<Dialogs>): void => {
    setDialog(next);
    setDialogOpen(true);
  };
  const dialogs = (
    <>
      {dialog?.kind === "stages" ? <EditStagesDialog open={dialogOpen} onOpenChange={setDialogOpen} /> : null}
      {dialog?.kind === "stage" ? <StageEditorDialog stageId={dialog.stageId} open={dialogOpen} onOpenChange={setDialogOpen} /> : null}
    </>
  );

  // A board that has never been set up is a different thing from an empty one.
  if (columns.every((c) => c.stage === null) && exits.length === 0) {
    return (
      <div className="h-full">
        <EmptyState icon={SquareKanban} message="Add columns to build a board for this workspace" actionLabel="Add a column" onAction={() => open({ kind: "stages" })} />
        {dialogs}
      </div>
    );
  }

  return (
    // Arrow keys move focus between cards, across columns too; Enter opens, Space selects.
    <div
      className="contents"
      data-card-grid
      onKeyDown={(event) => {
        if (moveCardFocus(event.nativeEvent, event.currentTarget)) {
          event.preventDefault();
        }
      }}
    >
      <BoardDnd
        columns={columns}
        exits={exits}
        layout={wide ? "wide" : "paged"}
        onShowAll={() => setShowAll(true)}
        onEditStages={() => open({ kind: "stages" })}
        onEditStage={(stageId) => open({ kind: "stage", stageId })}
        onDeleteStage={(stageId) => notes.deleteStage(stageId)}
      />
      {dialogs}
    </div>
  );
}

interface BoardDndProps {
  readonly columns: readonly ColumnIds[];
  readonly exits: readonly BoardExit[];
  readonly layout: "wide" | "paged";
  readonly onShowAll: () => void;
  readonly onEditStages: () => void;
  readonly onEditStage: (stageId: string) => void;
  readonly onDeleteStage: (stageId: string) => void;
}

interface CardDragState {
  readonly kind: "card";
  readonly activeId: string;
  readonly draggedIds: readonly string[];
  readonly width: number;
  readonly fromKey: string;
}
interface StageDragState {
  readonly kind: "stage";
  readonly stageId: string;
}
type DragState = CardDragState | StageDragState | null;

function BoardDnd(props: BoardDndProps) {
  const { columns, exits, layout } = props;
  const notes = useNotesController();
  const ui = useUiController();
  const reduced = useReducedMotion();
  const sort = useActiveSort();
  const selectedIds = useSelectedIds();
  const selected = new Set(selectedIds);
  const dragEnabled = sort === "custom";
  const [drag, setDrag] = useState<DragState>(null);
  const [overrides, setOverrides] = useState<DragColumns | null>(null);
  const [overKey, setOverKey] = useState<string | null>(null);
  const overridesRef = useRef<DragColumns | null>(null);
  const startColumns = useRef<readonly ColumnIds[]>(columns);
  // Read by collision detection, which runs before the state update renders.
  const fromKeyRef = useRef<string | null>(null);
  const pagerRef = useRef<HTMLDivElement | null>(null);

  const sensors = useSensors(
    useSensor(MouseSensor, { activationConstraint: { distance: MOUSE_DISTANCE_PX } }),
    useSensor(TouchSensor, { activationConstraint: { delay: TOUCH_HOLD_MS, tolerance: TOUCH_TOLERANCE_PX } }),
    // Space picks a card up; Enter stays the card's own "open".
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates, keyboardCodes: { start: ["Space"], cancel: ["Escape"], end: ["Space", "Enter"] } }),
  );

  const setColumns = (next: DragColumns | null): void => {
    overridesRef.current = next;
    setOverrides(next);
  };

  const shown: readonly ColumnIds[] = overrides === null ? columns : columns.map((c) => ({ ...c, ids: overrides[c.key] ?? c.ids }));
  const cardDrag = drag?.kind === "card" ? drag : null;
  const dimmedIds = new Set(cardDrag ? cardDrag.draggedIds.filter((id) => id !== cardDrag.activeId) : []);

  const collision: CollisionDetection = (args) => {
    const activeKind = kindOf(args.active.id, args.active.data.current);
    if (activeKind === "stage") {
      return closestCenter({ ...args, droppableContainers: args.droppableContainers.filter((c) => kindOf(c.id, c.data.current) === "stage") });
    }
    const pointer = pointerWithin(args);
    const target = pointer.find((c) => {
      const kind = kindOf(c.id);
      return kind === "exit" || kind === "chip";
    });
    if (target) {
      return [target];
    }
    const current = overridesRef.current ?? dragColumnsOf(startColumns.current);
    const fromKey = fromKeyRef.current;
    // A phone never carries a card across pages; only the chips move it.
    const allowed = (key: string): boolean => layout === "wide" || key === fromKey;
    const hits = (pointer.length > 0 ? pointer : rectIntersection(args)).filter((c) => kindOf(c.id) === "column" && allowed(suffix(String(c.id))));
    const column = hits[0];
    if (!column) {
      return [];
    }
    const ids = current[suffix(String(column.id))] ?? [];
    const cards = args.droppableContainers.filter((c) => ids.includes(String(c.id)));
    if (cards.length === 0) {
      return [column];
    }
    const closest = closestCenter({ ...args, droppableContainers: cards });
    return closest.length > 0 ? closest : [column];
  };

  const onDragStart = ({ active }: DragStartEvent): void => {
    const id = String(active.id);
    if (id.startsWith("stage:")) {
      setDrag({ kind: "stage", stageId: suffix(id) });
      return;
    }
    startColumns.current = columns;
    const initial = dragColumnsOf(columns);
    setColumns(initial);
    fromKeyRef.current = containerOf(initial, id);
    setDrag({
      kind: "card",
      activeId: id,
      draggedIds: draggedIdsFor(id, selectedIds),
      width: active.rect.current.initial?.width ?? COLUMN_WIDTH,
      fromKey: containerOf(initial, id) ?? "",
    });
  };

  const onDragOver = ({ active, over }: DragOverEvent): void => {
    const activeId = String(active.id);
    const current = overridesRef.current;
    if (!over || !current || kindOf(active.id, active.data.current) !== "card") {
      setOverKey(null);
      return;
    }
    const overId = String(over.id);
    const overKind = kindOf(over.id, over.data.current);
    if (overKind === "exit" || overKind === "chip") {
      setOverKey(null);
      return;
    }
    const activeKey = containerOf(current, activeId);
    const targetKey = overKind === "column" ? suffix(overId) : containerOf(current, overId);
    setOverKey(targetKey !== null && targetKey !== fromKeyRef.current ? targetKey : null);
    if (activeKey === null || targetKey === null || activeKey === targetKey || layout === "paged") {
      return;
    }
    const targetIds = current[targetKey] ?? [];
    let index = targetIds.length;
    if (overKind !== "column") {
      const overIndex = targetIds.indexOf(overId);
      const dragged = active.rect.current.translated;
      const below = dragged !== null && dragged.top > over.rect.top + over.rect.height / 2;
      index = overIndex + (below ? 1 : 0);
    }
    setColumns(moveToColumn(current, activeId, targetKey, index));
  };

  const finish = (): void => {
    fromKeyRef.current = null;
    setDrag(null);
    setColumns(null);
    setOverKey(null);
    swallowNextClick();
  };

  const dropStage = (activeId: string, overId: string | null): void => {
    if (overId === null || !overId.startsWith("stage:") || overId === activeId) {
      return;
    }
    const ordered = columns.filter((c) => c.stage !== null).map((c) => stageSortId(c.stage!.id));
    const to = ordered.indexOf(overId);
    if (to !== -1) {
      notes.moveStage(suffix(activeId), to);
    }
  };

  const dropCard = (event: DragEndEvent, state: CardDragState): void => {
    const { active, over, delta, activatorEvent } = event;
    const activeId = state.activeId;
    const current = overridesRef.current ?? dragColumnsOf(columns);
    if (!over) {
      return;
    }
    const overId = String(over.id);
    const overKind = kindOf(over.id, over.data.current);
    const ids = state.draggedIds;

    if (overKind === "exit") {
      const exit = suffix(overId) as BoardExitKind;
      if (!canDropOnExit(ids.map((id) => notes.noteById(id)), exit, (id) => notes.canTrash(id))) {
        return;
      }
      for (const id of ids) {
        if (exit === "trash") {
          notes.moveToTrash(id);
        } else {
          notes.setArchived(id, true);
        }
      }
      if (selected.has(activeId)) {
        ui.clearSelection();
      }
      return;
    }
    if (overKind === "chip") {
      const stageId = stageIdOfKey(suffix(overId));
      for (const id of ids) {
        const note = notes.noteById(id);
        if (note && note.stageId !== stageId) {
          notes.setNoteStage(id, stageId);
        }
      }
      return;
    }

    const moved = notes.noteById(activeId);
    const key = containerOf(current, activeId);
    if (!moved || moved.archived || moved.trashed || key === null) {
      return;
    }
    let shownIds = current[key] ?? [];
    if (overKind !== "column" && overId !== activeId && shownIds.includes(overId)) {
      shownIds = moveWithin(shownIds, shownIds.indexOf(activeId), shownIds.indexOf(overId));
    }
    const before = (startColumns.current.find((c) => c.key === key)?.ids ?? []).map((id) => notes.noteById(id)).filter((n) => n !== null);
    const writes = planCardDrop({ moved, draggedIds: ids, targetStageId: stageIdOfKey(key), shownIds, before, noteById: (id) => notes.noteById(id) });
    for (const write of writes) {
      notes.setNoteStage(write.noteId, write.stageId, write.position);
    }

    // A long press that never moved is the touch gesture for selecting.
    const touch = typeof TouchEvent !== "undefined" && activatorEvent instanceof TouchEvent;
    if (touch && writes.length === 0 && Math.hypot(delta.x, delta.y) < STATIONARY_PX && String(active.id) === activeId) {
      ui.toggleSelected(activeId);
    }
  };

  const onDragEnd = (event: DragEndEvent): void => {
    const state = drag;
    if (state?.kind === "stage") {
      dropStage(String(event.active.id), event.over ? String(event.over.id) : null);
    } else if (state?.kind === "card") {
      dropCard(event, state);
    }
    finish();
  };

  const dropAnimation: DropAnimation | null = reduced
    ? null
    : { duration: DURATION.base, easing: cssEase(EASE.emphasized), sideEffects: defaultDropAnimationSideEffects({ styles: { active: { opacity: "0.4" } } }) };

  const toggleSelection = (column: ColumnIds): (() => void) | null => (column.ids.length === 0 ? null : () => ui.toggleSelectAll(column.ids));
  const shared = {
    dragEnabled,
    dragging: cardDrag !== null,
    dimmedIds,
    selectionMode: selectedIds.length > 0,
    onEditStage: props.onEditStage,
    onDeleteStage: props.onDeleteStage,
  };

  return (
    <DndContext
      sensors={sensors}
      collisionDetection={collision}
      measuring={{ droppable: { strategy: MeasuringStrategy.Always } }}
      // Paging under the finger is what the chip strip exists to avoid.
      autoScroll={{ canScroll: (element) => element !== pagerRef.current }}
      onDragStart={onDragStart}
      onDragOver={onDragOver}
      onDragEnd={onDragEnd}
      onDragCancel={finish}
    >
      {layout === "wide" ? (
        <WideBoard
          columns={shown}
          exits={exits}
          draggedIds={cardDrag?.draggedIds ?? null}
          renderColumn={(column, extra) => (
            <BoardColumnView
              column={column}
              layout="wide"
              highlighted={overKey === column.key}
              selection={columnSelectionOf(column.ids, selected)}
              onToggleSelection={toggleSelection(column)}
              onShowAll={column.stage === null ? props.onShowAll : undefined}
              {...shared}
              {...extra}
            />
          )}
          onEditStages={props.onEditStages}
        />
      ) : (
        <PagedBoard
          columns={shown}
          exits={exits}
          pagerRef={pagerRef}
          draggedIds={cardDrag?.draggedIds ?? null}
          renderColumn={(column) => (
            <BoardColumnView
              column={column}
              layout="paged"
              highlighted={false}
              collapsed={false}
              selection={columnSelectionOf(column.ids, selected)}
              onToggleSelection={toggleSelection(column)}
              onShowAll={column.stage === null ? props.onShowAll : undefined}
              {...shared}
            />
          )}
          onEditStages={props.onEditStages}
        />
      )}
      <DragOverlay dropAnimation={dropAnimation}>
        {cardDrag ? <CardOverlay noteId={cardDrag.activeId} width={cardDrag.width} count={cardDrag.draggedIds.length} /> : null}
        {drag?.kind === "stage" ? <StageOverlay column={columns.find((c) => c.stage?.id === drag.stageId) ?? null} /> : null}
      </DragOverlay>
    </DndContext>
  );
}

function CardOverlay({ noteId, width, count }: { noteId: string; width: number; count: number }) {
  return (
    <div className="relative cursor-grabbing rounded-md shadow-raised" style={{ width }}>
      <NoteCard noteId={noteId} variant="board" />
      {count > 1 ? (
        <span className="absolute -top-2 -right-2 rounded-md bg-primary-container px-1.5 py-0.5 text-2xs font-medium text-on-primary-container shadow-card">Move {count} cards</span>
      ) : null}
    </div>
  );
}

function StageOverlay({ column }: { column: ColumnIds | null }) {
  if (!column) {
    return null;
  }
  return (
    <div className="flex h-11 cursor-grabbing items-center gap-2 rounded-md border border-trough-border bg-surface px-3 shadow-raised" style={{ width: COLUMN_WIDTH }}>
      <span className="min-w-0 flex-1 truncate text-sm font-semibold text-on-surface">{columnTitleOf(column)}</span>
      <span className="text-2xs text-on-surface-variant">{column.totalCount}</span>
    </div>
  );
}

type ColumnExtra = { collapsed: boolean; onToggleCollapsed: () => void; handle?: ColumnDragHandle };

function WideBoard({
  columns,
  exits,
  draggedIds,
  renderColumn,
  onEditStages,
}: {
  columns: readonly ColumnIds[];
  exits: readonly BoardExit[];
  draggedIds: readonly string[] | null;
  renderColumn: (column: ColumnIds, extra: ColumnExtra) => ReactNode;
  onEditStages: () => void;
}) {
  const [collapsed, setCollapsed] = useState<ReadonlySet<string>>(() => new Set());
  const toggle = (key: string): void =>
    setCollapsed((prev) => {
      const next = new Set(prev);
      if (!next.delete(key)) {
        next.add(key);
      }
      return next;
    });
  const stageIds = columns.filter((c) => c.stage !== null).map((c) => stageSortId(c.stage!.id));
  const ordered: BoardExitKind[] = (["archive", "trash"] as const).filter((e) => exits.includes(e));

  return (
    <motion.div layoutScroll className="flex h-full min-h-0 gap-3 overflow-x-auto overflow-y-hidden px-4 py-3">
      <SortableContext items={stageIds} strategy={horizontalListSortingStrategy}>
        {/* A column added or deleted opens or closes its slot; the rest slide over. */}
        <AnimatePresence initial={false}>
          {columns.map((column) => {
            const extra = { collapsed: collapsed.has(column.key), onToggleCollapsed: () => toggle(column.key) };
            return (
              <PresenceColumn key={column.key}>
                {column.stage === null ? (
                  <div className="h-full shrink-0">{renderColumn(column, extra)}</div>
                ) : (
                  <SortableStageColumn stageId={column.stage.id} disabled={extra.collapsed}>
                    {(handle) => renderColumn(column, { ...extra, handle })}
                  </SortableStageColumn>
                )}
              </PresenceColumn>
            );
          })}
        </AnimatePresence>
      </SortableContext>
      {ordered.length > 0 ? (
        // Both exits share one slot, stacked, so they read as a pair of
        // destinations rather than two more columns.
        <div className="flex h-full shrink-0 flex-col gap-3" style={{ width: EXITS_WIDTH }}>
          {ordered.map((exit) => (
            <ExitTarget key={exit} exit={exit} draggedIds={draggedIds} variant="large" />
          ))}
        </div>
      ) : null}
      <button
        type="button"
        onClick={onEditStages}
        // A half-strength trough: a column that is not there yet.
        className="flex h-full shrink-0 items-center justify-center gap-2 rounded-md border border-trough-border bg-trough/50 text-sm font-medium text-on-surface-variant transition-colors duration-150 ease-standard outline-none hover:bg-trough hover:text-on-surface focus-visible:ring-[3px] focus-visible:ring-ring/50"
        style={{ width: COLUMN_WIDTH }}
      >
        <Plus className="size-4" />
        Add column
      </button>
    </motion.div>
  );
}

/** The board's gap between columns, which a column arriving or leaving takes with it. */
const COLUMN_GAP_PX = 12;

/**
 * A wide board's column slot: opens from nothing as a stage is added and
 * closes as one is deleted, so its neighbours glide instead of jumping. It
 * clips only while its width is moving.
 */
function PresenceColumn({ children }: { children: ReactNode }) {
  const reduced = useReducedMotion();
  const ref = useRef<HTMLDivElement | null>(null);
  const clip = (on: boolean): void => {
    if (ref.current) {
      ref.current.style.overflow = on ? "hidden" : "";
    }
  };
  return (
    <motion.div
      ref={ref}
      className="h-full shrink-0"
      initial={{ width: 0, marginLeft: -COLUMN_GAP_PX, opacity: 0 }}
      animate={{ width: "auto", marginLeft: 0, opacity: 1, transition: transitionFor(TRANSITION.base, reduced) }}
      exit={{ width: 0, marginLeft: -COLUMN_GAP_PX, opacity: 0, transition: transitionFor(TRANSITION.base, reduced) }}
      onAnimationStart={() => clip(true)}
      onAnimationComplete={() => clip(false)}
    >
      {children}
    </motion.div>
  );
}

function SortableStageColumn({ stageId, disabled, children }: { stageId: string; disabled: boolean; children: (handle: ColumnDragHandle) => ReactNode }) {
  const reduced = useReducedMotion();
  const { attributes, listeners, setNodeRef, setActivatorNodeRef, transform, transition, isDragging } = useSortable({
    id: stageSortId(stageId),
    data: { type: "stage" },
    disabled,
    transition: reduced ? null : { duration: DURATION.base, easing: cssEase(EASE.emphasized) },
  });
  const style: CSSProperties = { transform: CSS.Translate.toString(transform), transition };
  return (
    <div ref={setNodeRef} style={style} className={cn("h-full shrink-0 transition-opacity duration-150 ease-standard", isDragging && "opacity-40")}>
      {children({ ref: setActivatorNodeRef, props: { ...attributes, ...listeners } })}
    </div>
  );
}

const EXIT_COPY: Record<BoardExitKind, { title: string; icon: typeof Archive }> = {
  archive: { title: "Archive", icon: Archive },
  trash: { title: "Trash", icon: Trash2 },
};

/**
 * Archive and Trash as drop targets, not stages: filing a card away keeps its
 * stage, so restoring it puts it back in the same column.
 */
function ExitTarget({ exit, draggedIds, variant }: { exit: BoardExitKind; draggedIds: readonly string[] | null; variant: "large" | "compact" }) {
  const notes = useNotesController();
  const { setNodeRef, isOver } = useDroppable({ id: exitId(exit), data: { type: "exit" } });
  const allowed = draggedIds !== null && canDropOnExit(draggedIds.map((id) => notes.noteById(id)), exit, (id) => notes.canTrash(id));
  const active = isOver && allowed;
  const { title, icon: Icon } = EXIT_COPY[exit];
  // Trash lights up red: the drop is destructive.
  const tone = exit === "trash" ? "border-error bg-error-container text-on-error-container" : "border-primary bg-primary-container text-on-primary-container";

  if (variant === "compact") {
    return (
      <div
        ref={setNodeRef}
        className={cn("flex h-8 shrink-0 items-center gap-1.5 rounded-md border px-3 text-sm font-medium transition-colors duration-150 ease-standard", active ? tone : "border-trough-border bg-trough text-on-surface-variant")}
      >
        <Icon className="size-4" />
        {title}
      </div>
    );
  }
  return (
    <div
      ref={setNodeRef}
      className={cn(
        "flex flex-1 flex-col items-center justify-center gap-1 rounded-md border p-4 text-center transition-colors duration-150 ease-standard",
        active ? tone : "border-trough-border bg-trough text-on-surface-variant",
      )}
    >
      <Icon className="mb-2 size-8" strokeWidth={1.5} />
      <span className="text-sm font-semibold text-on-surface">{title}</span>
      <span className="text-xs">Drop notes here</span>
    </div>
  );
}

function PagedBoard({
  columns,
  exits,
  pagerRef,
  draggedIds,
  renderColumn,
  onEditStages,
}: {
  columns: readonly ColumnIds[];
  exits: readonly BoardExit[];
  pagerRef: React.RefObject<HTMLDivElement | null>;
  draggedIds: readonly string[] | null;
  renderColumn: (column: ColumnIds) => ReactNode;
  onEditStages: () => void;
}) {
  const reduced = useReducedMotion();
  const [rawPage, setPage] = useState(0);
  // A stage deleted while the board is open can leave the page past the end.
  const page = Math.max(0, Math.min(rawPage, columns.length - 1));
  const ordered: BoardExitKind[] = (["archive", "trash"] as const).filter((e) => exits.includes(e));

  const pageWidth = (): number => (pagerRef.current?.clientWidth ?? 0) * PAGE_FRACTION;
  const showPage = (index: number): void => {
    pagerRef.current?.scrollTo({ left: index * pageWidth(), behavior: reduced ? "auto" : "smooth" });
  };

  return (
    <div className="flex h-full min-h-0 flex-col">
      <StageStrip columns={columns} current={page} onSelect={showPage} draggedIds={draggedIds} exits={ordered} onEditStages={onEditStages} />
      <div
        ref={pagerRef}
        onScroll={(event) => setPage(pageAt(event.currentTarget.scrollLeft, pageWidth(), columns.length))}
        className="flex min-h-0 flex-1 snap-x snap-mandatory overflow-x-auto overflow-y-hidden overscroll-x-contain [scrollbar-width:none]"
        style={{ paddingInline: `${((1 - PAGE_FRACTION) / 2) * 100}%` }}
      >
        {columns.map((column) => (
          // The pager's padding already leaves the neighbours their edges, so a
          // page is the whole padded box: PAGE_FRACTION of the screen.
          <div key={column.key} className="h-full w-full shrink-0 snap-center px-1 pb-3">
            {renderColumn(column)}
          </div>
        ))}
      </div>
    </div>
  );
}

/**
 * The phone board's column switcher: names and counts, the open one filled.
 * Doubles as the phone's drop target: a card is carried up to a chip rather
 * than across pages, so nothing turns under the finger.
 */
function StageStrip({
  columns,
  current,
  onSelect,
  draggedIds,
  exits,
  onEditStages,
}: {
  columns: readonly ColumnIds[];
  current: number;
  onSelect: (index: number) => void;
  draggedIds: readonly string[] | null;
  exits: readonly BoardExitKind[];
  onEditStages: () => void;
}) {
  const reduced = useReducedMotion();
  const chips = useRef<Map<number, HTMLElement>>(new Map());

  // Keep the open column's chip on screen: off the edge it is unreachable as
  // a drop target, because the strip cannot scroll while a card is held.
  useEffect(() => {
    chips.current.get(current)?.scrollIntoView?.({ inline: "center", block: "nearest", behavior: reduced ? "auto" : "smooth" });
  }, [current, reduced]);

  return (
    <div className="flex h-11 shrink-0 items-center gap-2 overflow-x-auto px-3 [scrollbar-width:none]" role="tablist" aria-label="Board columns">
      {columns.map((column, index) => (
        <StageChip
          key={column.key}
          column={column}
          selected={index === current}
          draggedIds={draggedIds}
          onSelect={() => onSelect(index)}
          chipRef={(node) => {
            if (node) {
              chips.current.set(index, node);
            } else {
              chips.current.delete(index);
            }
          }}
        />
      ))}
      {exits.map((exit) => (
        <ExitTarget key={exit} exit={exit} draggedIds={draggedIds} variant="compact" />
      ))}
      <button
        type="button"
        onClick={onEditStages}
        className="flex h-8 shrink-0 items-center gap-1.5 rounded-md border border-hairline px-3 text-sm font-medium text-on-surface-variant transition-colors duration-150 ease-standard outline-none hover:bg-hover active:bg-pressed focus-visible:ring-[3px] focus-visible:ring-ring/50"
      >
        <Plus className="size-4" />
        Add column
      </button>
    </div>
  );
}

function StageChip({
  column,
  selected,
  draggedIds,
  onSelect,
  chipRef,
}: {
  column: ColumnIds;
  selected: boolean;
  draggedIds: readonly string[] | null;
  onSelect: () => void;
  chipRef: (node: HTMLElement | null) => void;
}) {
  const notes = useNotesController();
  const { setNodeRef, isOver } = useDroppable({ id: chipId(column.key), data: { type: "chip" } });
  const stageId = column.stage?.id ?? null;
  // A chip does not light up for the column the card is already in.
  const hovered = isOver && draggedIds !== null && canDropOnStage(draggedIds.map((id) => notes.noteById(id)), stageId);
  const hex = normalizeHex(column.stage?.color);

  return (
    <button
      ref={(node) => {
        setNodeRef(node);
        chipRef(node);
      }}
      type="button"
      role="tab"
      aria-selected={selected}
      onClick={onSelect}
      className={cn(
        "flex h-8 shrink-0 items-center gap-2 rounded-md border px-3 text-sm font-medium transition-[background-color,border-color,color] duration-150 ease-standard outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50",
        hovered
          ? "border-primary bg-primary-container text-on-primary-container ring-1 ring-primary"
          : selected
            ? "border-transparent bg-secondary-container text-on-secondary-container"
            : "border-hairline text-on-surface-variant hover:bg-hover active:bg-pressed",
      )}
    >
      <span aria-hidden className="size-2 rounded-xs" style={{ background: hex ?? "var(--on-surface-variant)" }} />
      <span className="max-w-40 truncate">{columnTitleOf(column)}</span>
      <RollingCount count={column.totalCount} className="text-2xs text-on-surface-variant" />
    </button>
  );
}

