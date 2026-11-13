"use client";

import type { ReactNode } from "react";
import { motion, useReducedMotion } from "motion/react";
import {
  Archive,
  ArchiveRestore,
  CheckCheck,
  Columns3,
  EllipsisVertical,
  FolderInput,
  Palette,
  Pin,
  PinOff,
  SquareDashed,
  Tag,
  Trash2,
  Undo2,
  X,
  ArrowRightLeft,
} from "lucide-react";
import { IconButton } from "@/components/common/icon-button";
import { MenuLabel } from "@/components/common/menu-label";
import { RollingCount } from "@/components/common/rolling-count";
import { showAppSnack } from "@/components/common/snack";
import { Button } from "@/components/ui/button";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { NoteLabelPicker } from "@/features/editor/label-picker";
import type { Note } from "@/lib/models/note";
import { useActiveLayout, useBoard, useNotesController, useNotesSelector, useSelectedIds, useUi, useUiController, useVisibleNoteIds } from "@/lib/store";
import { EASE, DURATION } from "@/lib/theme/motion";
import { allSelected, pinsSelection, selectionOffer, trashMessage, trashPlan } from "./selection-rules";
import { useShellDialogs } from "./shell-dialogs";

function notesEqual(a: readonly Note[], b: readonly Note[]): boolean {
  return a.length === b.length && a.every((n, i) => n === b[i]);
}

/**
 * The top bar while notes are selected (`_SelectionBar`): the count, select
 * all, and what the open view lets you do to them. Controls drop in from
 * above, staggered left to right, once per stint in selection mode.
 */
export function SelectionBar({ variant }: { variant: "wide" | "compact" }) {
  const layout = useActiveLayout();
  const destination = useUi((s) => s.destination);
  const board = destination === "notes" && layout === "board";
  return board ? <BoardSelection variant={variant} /> : <GridSelection variant={variant} />;
}

function GridSelection({ variant }: { variant: "wide" | "compact" }) {
  const { pinned, others } = useVisibleNoteIds();
  return <Bar variant={variant} visible={[...pinned, ...others]} board={false} />;
}

function BoardSelection({ variant }: { variant: "wide" | "compact" }) {
  const board = useBoard();
  const visible = board.columns.flatMap((c) => c.notes.map((n) => n.id));
  return <Bar variant={variant} visible={visible} board />;
}

function Bar({ variant, visible, board }: { variant: "wide" | "compact"; visible: readonly string[]; board: boolean }) {
  const ui = useUiController();
  const notes = useNotesController();
  const dialogs = useShellDialogs();
  const selectedIds = useSelectedIds();
  const destination = useUi((s) => s.destination);
  const selected = useNotesSelector((s) => selectedIds.map((id) => s.notes[id]).filter((n): n is Note => n !== undefined), notesEqual, [selectedIds.join("|")]);
  const offer = selectionOffer(destination);
  const everything = allSelected(visible, selectedIds);
  const pins = pinsSelection(selected);
  const none = selectedIds.length === 0;
  const inTrash = destination === "trash";
  const ids = [...selectedIds];

  const done = (): void => ui.clearSelection();

  const setPinned = (): void => {
    for (const note of selected) {
      if (note.pinned !== pins) {
        notes.togglePin(note.id);
      }
    }
  };

  const setArchived = (archived: boolean): void => {
    for (const note of selected) {
      if (note.archived !== archived) {
        notes.setArchived(note.id, archived);
      }
    }
    done();
  };

  const trash = (): void => {
    const plan = trashPlan(selected, (id) => notes.canTrash(id));
    for (const note of plan.trash) {
      notes.moveToTrash(note.id);
    }
    done();
    const message = trashMessage(plan.trash.length, plan.skipped);
    if (!message) {
      return;
    }
    const moved = plan.trash.map((n) => n.id);
    showAppSnack(message.text, {
      icon: message.kind === "danger" ? Trash2 : undefined,
      kind: message.kind,
      undo: moved.length > 0 ? () => moved.forEach((id) => notes.restoreFromTrash(id)) : undefined,
    });
  };

  // A note whose collection is gone needs a new home picked before it can come back.
  const restore = (): void => {
    const homeless: Note[] = [];
    for (const note of selected.filter((n) => n.trashed)) {
      const workspace = notes.workspaceById(note.workspaceId);
      const exists = workspace?.collections.some((c) => c.id === note.collectionId) ?? false;
      if (exists) {
        notes.restoreFromTrash(note.id);
      } else {
        homeless.push(note);
      }
    }
    done();
    const first = homeless[0];
    if (first) {
      dialogs.open({ type: "restorePicker", noteIds: homeless.filter((n) => n.workspaceId === first.workspaceId).map((n) => n.id), workspaceId: first.workspaceId });
    }
  };

  const deleteForever = (): void => {
    const deletable = selected.filter((n) => notes.canTrash(n.id));
    const count = deletable.length;
    if (count === 0) {
      showAppSnack("Only note owners can delete notes forever", { kind: "warning" });
      return;
    }
    dialogs.open({
      type: "confirm",
      title: count === 1 ? "Delete this note forever?" : `Delete ${count} notes forever?`,
      description: "They are removed with their attachments. This cannot be undone.",
      confirmLabel: "Delete forever",
      tone: "destructive",
      onConfirm: () => {
        deletable.forEach((n) => notes.deleteForever(n.id));
        done();
      },
    });
  };

  const openThenClear = (open: () => void): void => {
    open();
    done();
  };

  const labelButton = inTrash ? null : (
    <NoteLabelPicker noteIds={ids}>
      {/* A plain button: the picker's trigger needs a DOM element, which a tooltip root is not. */}
      <Button variant="ghost" size="icon" aria-label="Add label to selected notes" title="Add label" disabled={none}>
        <Tag />
      </Button>
    </NoteLabelPicker>
  );

  const actions: { key: string; node: ReactNode }[] = [];
  const overflow: { key: string; icon: ReactNode; label: string; run(): void }[] = [];

  if (board) {
    const item = { key: "stage", icon: <Columns3 />, label: "Move to column", run: () => openThenClear(() => dialogs.open({ type: "moveToStage", noteIds: ids })) };
    if (variant === "wide") {
      actions.push({ key: item.key, node: <IconButton label="Move selected notes to a column" icon={item.icon} disabled={none} onClick={item.run} /> });
    } else {
      overflow.push(item);
    }
  }
  if (labelButton) {
    actions.push({ key: "label", node: labelButton });
  }
  if (!inTrash) {
    const color = { key: "color", icon: <Palette />, label: "Change color", run: () => dialogs.open({ type: "bulkColor", noteIds: ids }) };
    const pin = { key: "pin", icon: pins ? <Pin /> : <PinOff />, label: pins ? "Pin notes" : "Unpin notes", run: setPinned };
    const collection = { key: "collection", icon: <FolderInput />, label: "Move to collection", run: () => openThenClear(() => dialogs.open({ type: "moveToCollection", noteIds: ids })) };
    const workspace = { key: "workspace", icon: <ArrowRightLeft />, label: "Move to workspace", run: () => openThenClear(() => dialogs.open({ type: "moveToWorkspace", noteIds: ids })) };
    if (variant === "wide") {
      actions.push({ key: "color", node: <IconButton label="Change selected note colors" icon={color.icon} disabled={none} onClick={color.run} /> });
      actions.push({ key: "pin", node: <IconButton label={pins ? "Pin selected notes" : "Unpin selected notes"} icon={pin.icon} disabled={none} onClick={pin.run} /> });
      overflow.push(collection, workspace);
    } else {
      overflow.push(pin, color, collection, workspace);
    }
  }
  if (offer.archive) {
    const archiving = offer.archive === "archive";
    actions.push({
      key: "archive",
      node: (
        <IconButton
          label={archiving ? "Archive selected notes" : "Unarchive selected notes"}
          icon={archiving ? <Archive /> : <ArchiveRestore />}
          disabled={none}
          onClick={() => setArchived(archiving)}
        />
      ),
    });
  }
  if (offer.restore) {
    actions.push({ key: "restore", node: <IconButton label="Restore selected notes" icon={<Undo2 />} disabled={none} onClick={restore} /> });
  }
  if (offer.deleteForever) {
    actions.push({ key: "forever", node: <IconButton label="Delete selected notes forever" icon={<Trash2 className="text-error" />} disabled={none} onClick={deleteForever} /> });
  }
  if (offer.trash) {
    actions.push({ key: "trash", node: <IconButton label="Move selected notes to Trash" icon={<Trash2 className="text-error" />} disabled={none} onClick={trash} /> });
  }
  if (overflow.length > 0) {
    actions.push({
      key: "more",
      node: (
        <DropdownMenu>
          <Tooltip>
            <TooltipTrigger asChild>
              <DropdownMenuTrigger asChild disabled={none}>
                <button
                  type="button"
                  aria-label="More actions for selected notes"
                  className="inline-flex size-9 items-center justify-center rounded-md text-on-surface-variant transition-colors duration-150 ease-standard outline-none hover:bg-hover focus-visible:ring-[3px] focus-visible:ring-ring/50 disabled:opacity-50 data-[state=open]:bg-hover"
                >
                  <EllipsisVertical className="size-5" />
                </button>
              </DropdownMenuTrigger>
            </TooltipTrigger>
            <TooltipContent>More actions</TooltipContent>
          </Tooltip>
          <DropdownMenuContent align="end">
            {overflow.map((item) => (
              <DropdownMenuItem key={item.key} onSelect={item.run}>
                {item.icon}
                <MenuLabel label={item.label} />
              </DropdownMenuItem>
            ))}
          </DropdownMenuContent>
        </DropdownMenu>
      ),
    });
  }

  const all = [
    {
      key: "all",
      node: (
        <IconButton
          label={everything ? "Deselect all" : "Select all"}
          icon={everything ? <SquareDashed /> : <CheckCheck />}
          onClick={() => ui.toggleSelectAll(visible)}
        />
      ),
    },
    ...actions,
  ];

  return (
    <div className="flex h-full min-w-0 flex-1 items-center gap-1">
      <DropIn index={0} count={all.length + 1}>
        <IconButton label="Cancel selection" icon={<X />} onClick={done} />
      </DropIn>
      <motion.span
        className="min-w-0 flex-1 truncate pl-1 text-base font-semibold text-on-surface"
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ duration: DURATION.base / 1000, ease: EASE.standard }}
        aria-live="polite"
      >
        {selectedIds.length === 0 ? "Select notes" : (
          <>
            <RollingCount count={selectedIds.length} /> selected
          </>
        )}
      </motion.span>
      {all.map((action, i) => (
        <DropIn key={action.key} index={i + 1} count={all.length + 1}>
          {action.node}
        </DropIn>
      ))}
    </div>
  );
}

/** One control dropping in from above, a beat after the one before it; the last lands within BASE. */
function DropIn({ index, count, children }: { index: number; count: number; children: ReactNode }) {
  const reduced = useReducedMotion();
  const step = count <= 1 ? 0 : 0.5 / (count - 1);
  const total = DURATION.base / 1000;
  return (
    <motion.span
      className="inline-flex shrink-0"
      initial={reduced ? false : { opacity: 0, y: -16 }}
      animate={{ opacity: 1, y: 0 }}
      exit={reduced ? undefined : { opacity: 0, y: -16 }}
      transition={{ duration: total * 0.5, delay: total * step * index, ease: EASE.emphasized }}
    >
      {children}
    </motion.span>
  );
}

