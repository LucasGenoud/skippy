"use client";

import { useState, type FormEvent } from "react";
import { GripVertical, Plus, Trash2 } from "lucide-react";
import { GlyphPicker } from "@/components/common/glyph-picker";
import { IconButton } from "@/components/common/icon-button";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Separator } from "@/components/ui/separator";
import { useLabels, useNotesController } from "@/lib/store";
import { GlyphBadge, ManageRow, TextField } from "./form-bits";
import { useShellDialogs } from "./shell-dialogs";
import { SortableRows } from "./sortable-rows";
import { labelNameProblem } from "./taxonomy-rules";

/** The labels of the open workspace: create, reorder, edit, delete (`EditLabelsDialog`). */
export function LabelsDialog({ open, onOpenChange }: { open: boolean; onOpenChange(open: boolean): void }) {
  const labels = useLabels();
  const notes = useNotesController();
  const dialogs = useShellDialogs();

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="flex max-h-[min(640px,calc(100dvh-2rem))] flex-col">
        <DialogHeader>
          <DialogTitle>Edit labels</DialogTitle>
          <DialogDescription>Labels are shared by everyone in this workspace.</DialogDescription>
        </DialogHeader>
        <div className="-mx-2 flex min-h-0 flex-1 flex-col overflow-y-auto px-2">
          <Button variant="ghost" className="justify-start" onClick={() => dialogs.open({ type: "labelEditor", labelId: null })}>
            <Plus />
            Create new label
          </Button>
          <Separator className="my-1.5" />
          {labels.length === 0 ? <p className="px-2 py-4 text-sm text-on-surface-variant">No labels yet.</p> : null}
          <SortableRows items={labels} idOf={(l) => l.id} onMove={(id, index) => notes.moveLabel(id, index)} entrance="staggered">
            {(label, handle) => (
              <ManageRow
                dragging={handle.dragging}
                grip={<Grip handleProps={handle.handleProps} />}
                leading={<GlyphBadge icon={label.icon} color={label.color} />}
                title={label.name}
                onOpen={() => dialogs.open({ type: "labelEditor", labelId: label.id })}
                trailing={<IconButton size="sm" label="Delete label" icon={<Trash2 />} onClick={() => notes.deleteLabel(label.id)} />}
              />
            )}
          </SortableRows>
        </div>
        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Done
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/** The drag grip at a management row's start. */
export function Grip({ handleProps }: { handleProps: Record<string, unknown> }) {
  return (
    <span
      {...handleProps}
      aria-label="Drag to reorder"
      className="inline-flex size-7 shrink-0 cursor-grab touch-none items-center justify-center rounded-md text-on-surface-variant/70 outline-none hover:text-on-surface-variant focus-visible:ring-[3px] focus-visible:ring-ring/50 active:cursor-grabbing"
    >
      <GripVertical className="size-4" />
    </span>
  );
}

/** Create (null id) or edit one label: name, colour, icon (`LabelEditorDialog`). */
export function LabelEditorDialog({ open, onOpenChange, labelId }: { open: boolean; onOpenChange(open: boolean): void; labelId: string | null }) {
  const notes = useNotesController();
  const labels = useLabels();
  const [initial] = useState(() => (labelId === null ? null : notes.labelById(labelId)));
  const [name, setName] = useState(initial?.name ?? "");
  const [color, setColor] = useState<string | null>(initial?.color ?? null);
  const [icon, setIcon] = useState<string | null>(initial?.icon ?? null);
  const [error, setError] = useState<string | null>(null);
  const creating = labelId === null;

  const save = (event: FormEvent): void => {
    event.preventDefault();
    const trimmed = name.trim();
    const problem = labelNameProblem(trimmed, labels, labelId);
    if (problem) {
      setError(problem);
      return;
    }
    if (creating) {
      notes.createLabel(trimmed, { color, icon });
    } else {
      notes.updateLabel(labelId, { name: trimmed, color, icon });
    }
    onOpenChange(false);
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[min(720px,calc(100dvh-2rem))]">
        <form onSubmit={save} className="flex flex-col gap-5">
          <DialogHeader>
            <DialogTitle>{creating ? "New label" : "Edit label"}</DialogTitle>
            <DialogDescription className="sr-only">Name, colour and icon</DialogDescription>
          </DialogHeader>
          <TextField
            label="Name"
            autoFocus={creating}
            value={name}
            error={error}
            onChange={(e) => {
              setName(e.target.value);
              setError(null);
            }}
          />
          <GlyphPicker color={color} onColorChange={setColor} icon={icon} onIconChange={setIcon} />
          <DialogFooter>
            <Button type="button" variant="ghost" onClick={() => onOpenChange(false)}>
              Cancel
            </Button>
            <Button type="submit">{creating ? "Create" : "Save"}</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
