"use client";

import { useState, type CSSProperties } from "react";
import { DndContext, KeyboardSensor, MouseSensor, TouchSensor, closestCenter, useSensor, useSensors, type DragEndEvent, type Modifier } from "@dnd-kit/core";
import { SortableContext, sortableKeyboardCoordinates, useSortable, verticalListSortingStrategy } from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import { Archive, Ban, GripVertical, Plus, Trash2 } from "lucide-react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";

import { IconButton } from "@/components/common/icon-button";
import { Reveal } from "@/components/common/reveal";
import { SectionLabel } from "@/components/common/section-label";
import { Swatch, SwatchCheck } from "@/components/common/swatch";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Separator } from "@/components/ui/separator";
import { Switch } from "@/components/ui/switch";
import type { Stage } from "@/lib/models/note";
import { boardExitsFor, listIdentityEqual, useActiveCollection, useNotesController, useSettings, useSettingsController, useStages } from "@/lib/store";
import { ACCENT_PRESETS } from "@/lib/theme/accent";
import { DURATION, EASE, TRANSITION, cssEase, transitionFor } from "@/lib/theme/motion";
import { hexToRgb, isDarkColor } from "@/lib/theme/color";
import { normalizeHex } from "@/lib/theme/palette";

// Manage the board's columns: add, rename, recolour, reorder, remove, plus the
// Archive and Trash drop columns. Parallel to the label editor rather than
// sharing code with it: stages and labels are independent systems.

const STAGGER_S = 0.03;
const STAGGER_MAX_S = 0.15;

/** Why a column name is refused, or null when it is fine (`_validate`). */
export function stageNameError(name: string, stages: readonly Stage[], editingId: string | null): string | null {
  const trimmed = name.trim();
  if (trimmed === "") {
    return "Name a column";
  }
  const lower = trimmed.toLowerCase();
  // The server enforces this too; catching it here keeps the optimistic
  // create from being refused later.
  const clash = stages.some((s) => s.id !== editingId && s.name.toLowerCase() === lower);
  return clash ? "That column already exists" : null;
}

/** The dot that stands for a column in lists: a stage's whole identity. */
export function StageDot({ color, className }: { color: string | null; className?: string }) {
  const hex = normalizeHex(color);
  return (
    <span
      aria-hidden
      className={className ?? "inline-block size-3 shrink-0 rounded-xs"}
      style={{ background: hex ?? "var(--on-surface-variant)" }}
    />
  );
}

/** Create ([stageId] null) or edit one column. */
export function StageEditorDialog({ stageId, open, onOpenChange }: { stageId: string | null; open: boolean; onOpenChange(open: boolean): void }) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-[360px]">
        {/* Mounted per opening, so the form starts from the stage each time. */}
        <StageForm stageId={stageId} onDone={() => onOpenChange(false)} />
      </DialogContent>
    </Dialog>
  );
}

function StageForm({ stageId, onDone }: { stageId: string | null; onDone(): void }) {
  const notes = useNotesController();
  const stages = useStages();
  const [initial] = useState(() => (stageId === null ? null : notes.stageById(stageId)));
  const [name, setName] = useState(initial?.name ?? "");
  const [color, setColor] = useState<string | null>(normalizeHex(initial?.color));
  const [error, setError] = useState<string | null>(null);
  const isNew = stageId === null;

  const save = (): void => {
    const problem = stageNameError(name, stages, stageId);
    if (problem !== null) {
      setError(problem);
      return;
    }
    if (isNew) {
      notes.createStage(name.trim(), color);
    } else {
      notes.updateStage(stageId, { name: name.trim(), color });
    }
    onDone();
  };

  return (
    <form
      className="grid gap-4"
      onSubmit={(event) => {
        event.preventDefault();
        save();
      }}
    >
      <DialogHeader>
        <DialogTitle>{isNew ? "Add column" : "Edit column"}</DialogTitle>
        <DialogDescription className="sr-only">Name the column and pick its colour.</DialogDescription>
      </DialogHeader>
      <div className="grid gap-1.5">
        <Label htmlFor="stage-name">Name</Label>
        <Input
          id="stage-name"
          autoFocus
          autoCapitalize="sentences"
          value={name}
          aria-invalid={error !== null || undefined}
          onChange={(event) => {
            setName(event.target.value);
            setError(null);
          }}
        />
        <Reveal>{error ? <p className="text-xs text-error">{error}</p> : null}</Reveal>
      </div>
      <div className="grid gap-2">
        <SectionLabel>Colour</SectionLabel>
        <div role="radiogroup" aria-label="Colour" className="flex flex-wrap gap-2">
          <Swatch label="No colour" size="sm" selected={color === null} onSelect={() => setColor(null)}>
            <Ban className="size-4 text-on-surface-variant" />
          </Swatch>
          {ACCENT_PRESETS.map((preset) => {
            const hex = normalizeHex(preset.hex);
            const selected = hex !== null && hex === color;
            return (
              <Swatch key={preset.hex} label={preset.name} size="sm" fill={preset.hex} selected={selected} ring="strong" onSelect={() => setColor(hex)}>
                {selected ? <SwatchCheck className="size-4" color={checkInkOn(preset.hex)} /> : null}
              </Swatch>
            );
          })}
        </div>
      </div>
      <DialogFooter>
        <Button type="button" variant="ghost" onClick={onDone}>
          Cancel
        </Button>
        <Button type="submit">{isNew ? "Add" : "Save"}</Button>
      </DialogFooter>
    </form>
  );
}

/** A check readable on [hex]: white on dark fills, ink on light ones. */
function checkInkOn(hex: string): string {
  const rgb = hexToRgb(hex);
  return rgb !== null && isDarkColor(rgb) ? "#FFFFFF" : "#1B1A16";
}

const verticalOnly: Modifier = ({ transform }) => ({ ...transform, x: 0 });

/** The board's column manager (`EditStagesDialog`). */
export function EditStagesDialog({ open, onOpenChange }: { open: boolean; onOpenChange(open: boolean): void }) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Edit columns</DialogTitle>
          <DialogDescription className="sr-only">Add, rename, reorder or remove the board&apos;s columns.</DialogDescription>
        </DialogHeader>
        <StageManager />
        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Done
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

type EditorTarget = { stageId: string | null } | null;

function StageManager() {
  const notes = useNotesController();
  const settings = useSettingsController();
  const stages = useStages();
  const collection = useActiveCollection();
  const collectionId = collection?.id ?? null;
  const exits = useSettings((s) => boardExitsFor(s, collectionId), listIdentityEqual);
  const [editor, setEditor] = useState<EditorTarget>(null);
  const [editorOpen, setEditorOpen] = useState(false);
  const sensors = useSensors(
    useSensor(MouseSensor, { activationConstraint: { distance: 4 } }),
    useSensor(TouchSensor, { activationConstraint: { delay: 200, tolerance: 6 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  );

  const openEditor = (stageId: string | null): void => {
    setEditor({ stageId });
    setEditorOpen(true);
  };

  const onDragEnd = ({ active, over }: DragEndEvent): void => {
    if (!over || active.id === over.id) {
      return;
    }
    const to = stages.findIndex((s) => s.id === over.id);
    if (to !== -1) {
      notes.moveStage(String(active.id), to);
    }
  };

  return (
    <div className="-mx-2 grid gap-1">
      <button
        type="button"
        onClick={() => openEditor(null)}
        className="flex h-10 items-center gap-3 rounded-md px-2 text-left text-sm text-on-surface transition-colors duration-150 ease-standard outline-none hover:bg-hover active:bg-pressed focus-visible:ring-[3px] focus-visible:ring-ring/50"
      >
        <Plus className="size-4 text-on-surface-variant" />
        Add column
      </button>
      <Separator className="my-1" />
      <DndContext sensors={sensors} collisionDetection={closestCenter} modifiers={[verticalOnly]} onDragEnd={onDragEnd}>
        <SortableContext items={stages.map((s) => s.id)} strategy={verticalListSortingStrategy}>
          <ul className="grid">
            <AnimatePresence initial={false}>
              {stages.map((stage, index) => (
                <StageRow key={stage.id} stage={stage} index={index} onEdit={() => openEditor(stage.id)} onDelete={() => notes.deleteStage(stage.id)} />
              ))}
            </AnimatePresence>
          </ul>
        </SortableContext>
      </DndContext>
      {stages.length === 0 ? <p className="px-2 py-2 text-xs text-on-surface-variant">No columns yet. Notes you have not placed sit in Unassigned.</p> : null}
      <Separator className="my-1" />
      {(
        [
          { id: "archive", label: "Archive", icon: Archive },
          { id: "trash", label: "Trash", icon: Trash2 },
        ] as const
      ).map(({ id, label, icon: Icon }) => (
        <label key={id} className="flex min-h-12 cursor-pointer items-center gap-3 rounded-md px-2 py-1.5 transition-colors duration-150 ease-standard hover:bg-hover active:bg-pressed">
          <Icon className="size-4 text-on-surface-variant" />
          <span className="grid flex-1">
            <span className="text-sm text-on-surface">{label}</span>
            <span className="text-xs text-on-surface-variant">Show as a board drop column</span>
          </span>
          <Switch
            checked={exits.includes(id)}
            disabled={collectionId === null}
            onCheckedChange={(visible) => {
              if (collectionId !== null) {
                settings.setBoardExitColumn(collectionId, id, visible);
              }
            }}
          />
        </label>
      ))}
      {editor ? <StageEditorDialog stageId={editor.stageId} open={editorOpen} onOpenChange={setEditorOpen} /> : null}
    </div>
  );
}

function StageRow({ stage, index, onEdit, onDelete }: { stage: Stage; index: number; onEdit(): void; onDelete(): void }) {
  const reduced = useReducedMotion();
  const { attributes, listeners, setNodeRef, setActivatorNodeRef, transform, transition, isDragging } = useSortable({
    id: stage.id,
    transition: reduced ? null : { duration: DURATION.base, easing: cssEase(EASE.emphasized) },
  });
  const style: CSSProperties = { transform: CSS.Translate.toString(transform), transition, zIndex: isDragging ? 1 : undefined };
  const enter = transitionFor({ ...TRANSITION.base, delay: Math.min(index * STAGGER_S, STAGGER_MAX_S) }, reduced);

  return (
    <motion.li
      initial={{ opacity: 0, y: 6 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0, height: 0 }}
      transition={enter}
      className="overflow-hidden"
    >
      <div
        ref={setNodeRef}
        style={style}
        className={
          "flex h-10 items-center gap-1 rounded-md bg-surface pr-1 transition-shadow duration-150 ease-standard hover:bg-hover active:bg-pressed " +
          (isDragging ? "shadow-raised" : "")
        }
      >
        <button
          type="button"
          ref={setActivatorNodeRef}
          aria-label={`Reorder ${stage.name}`}
          className="flex size-8 shrink-0 cursor-grab touch-none items-center justify-center rounded-md text-on-surface-variant outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50 active:cursor-grabbing"
          {...attributes}
          {...listeners}
        >
          <GripVertical className="size-4" />
        </button>
        <button type="button" onClick={onEdit} className="flex h-full min-w-0 flex-1 items-center gap-3 rounded-md px-1 text-left text-sm text-on-surface outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50">
          <StageDot color={stage.color} />
          <span className="truncate">{stage.name}</span>
        </button>
        <IconButton label="Delete column" size="sm" icon={<Trash2 />} onClick={onDelete} />
      </div>
    </motion.li>
  );
}
