"use client";

import { useId, useState } from "react";
import { Folder, Trash2 } from "lucide-react";
import { GlyphPicker } from "@/components/common/glyph-picker";
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
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import type { CollectionLayout, NoteCollection } from "@/lib/models";
import { useNotesController, useWorkspace } from "@/lib/store";
import { newId } from "@/lib/util/id";
import { Field, FormDialog, FormSectionLabel } from "@/features/settings/kit/form-dialog";
import { Segmented } from "@/features/settings/kit/segmented";
import { useOpenKey } from "@/features/settings/kit/use-open-key";
import { COLLECTION_POSITION_STEP, LAYOUT_OPTIONS, SORT_OPTIONS } from "./collection-labels";

const MAX_COLLECTION_NAME = 60;

/** Create (no collectionId) or edit one collection of [workspaceId]. */
export interface CollectionSettingsDialogProps {
  workspaceId: string;
  collectionId?: string;
  open: boolean;
  onOpenChange(open: boolean): void;
}

/** "3 notes will move to workspace trash…": what deleting a collection does. */
export function deleteCollectionMessage(count: number): string {
  return `${count} ${count === 1 ? "note will" : "notes will"} move to workspace trash. You can restore them to another collection for 7 days.`;
}

/**
 * One collection's shared settings: name, layout, default sort, colour and
 * icon, and deleting it (its notes go to the workspace trash).
 */
export function CollectionSettingsDialog(props: CollectionSettingsDialogProps) {
  const key = useOpenKey(props.open);
  return <CollectionForm key={key} {...props} />;
}

function CollectionForm({ workspaceId, collectionId, open, onOpenChange }: CollectionSettingsDialogProps) {
  const notes = useNotesController();
  const workspace = useWorkspace(workspaceId);
  const original = collectionId === undefined ? null : (workspace?.collections.find((c) => c.id === collectionId) ?? null);
  const ids = useId();
  const [name, setName] = useState(original?.name ?? "");
  const [layout, setLayout] = useState<string>(original?.layout ?? "masonry");
  const [sort, setSort] = useState<string>(original?.sort ?? "custom");
  const [color, setColor] = useState<string | null>(original?.color ?? null);
  const [icon, setIcon] = useState<string | null>(original?.icon ?? null);
  const [nameError, setNameError] = useState<string | null>(null);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const editing = collectionId !== undefined;

  function save() {
    const trimmed = name.trim();
    if (!trimmed) {
      setNameError("Enter a collection name");
      return;
    }
    const collection: NoteCollection = {
      id: original?.id ?? collectionId ?? newId(),
      workspaceId,
      name: trimmed,
      layout,
      sort,
      icon,
      color,
      position: original?.position ?? (workspace?.collections.length ?? 0) * COLLECTION_POSITION_STEP,
    };
    notes.saveCollection(collection);
    if (notes.activeWorkspaceId === workspaceId) {
      notes.selectCollection(collection.id);
    }
    onOpenChange(false);
  }

  function remove() {
    if (collectionId === undefined) {
      return;
    }
    notes.deleteCollection(collectionId);
    onOpenChange(false);
  }

  const noteCount = () => notes.notesInWorkspace(workspaceId).filter((n) => n.collectionId === collectionId && !n.trashed).length;

  return (
    <FormDialog
      open={open}
      onOpenChange={onOpenChange}
      title={editing ? "Collection settings" : "New collection"}
      onSubmit={save}
      footer={
        <>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button onClick={save}>Save</Button>
        </>
      }
    >
      <div className="flex flex-col gap-5">
        <Field label="Name" htmlFor={`${ids}-name`} error={nameError}>
          <Input
            id={`${ids}-name`}
            autoFocus={!editing}
            maxLength={MAX_COLLECTION_NAME}
            value={name}
            aria-invalid={nameError !== null || undefined}
            onChange={(e) => {
              setName(e.target.value);
              setNameError(null);
            }}
          />
        </Field>
        <div className="flex flex-col gap-2">
          <FormSectionLabel>Layout</FormSectionLabel>
          <Segmented<CollectionLayout>
            label="Layout"
            className="w-full"
            value={(LAYOUT_OPTIONS.some((o) => o.value === layout) ? layout : "masonry") as CollectionLayout}
            onChange={setLayout}
            options={LAYOUT_OPTIONS.map((o) => ({ value: o.value, label: o.label, icon: <o.icon aria-hidden /> }))}
          />
          <p className="text-xs text-on-surface-variant">Layout and sorting are shared with everyone in the workspace.</p>
        </div>
        <Field label="Default sorting" htmlFor={`${ids}-sort`}>
          <Select value={sort} onValueChange={setSort}>
            <SelectTrigger id={`${ids}-sort`} className="w-full">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {SORT_OPTIONS.map((o) => (
                <SelectItem key={o.value} value={o.value}>
                  {o.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </Field>
        <div className="border-t border-hairline pt-5">
          <GlyphPicker color={color} onColorChange={setColor} icon={icon} onIconChange={setIcon} defaultIcon={Folder} />
        </div>
        {editing ? (
          <div className="border-t border-hairline pt-4">
            <Button variant="ghost" className="text-error hover:text-error" onClick={() => setConfirmOpen(true)}>
              <Trash2 aria-hidden />
              Delete collection
            </Button>
          </div>
        ) : null}
      </div>
      <AlertDialog open={confirmOpen} onOpenChange={setConfirmOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete {original?.name ?? "collection"}?</AlertDialogTitle>
            <AlertDialogDescription>{confirmOpen ? deleteCollectionMessage(noteCount()) : ""}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction variant="destructive" onClick={remove}>
              Delete collection
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </FormDialog>
  );
}
