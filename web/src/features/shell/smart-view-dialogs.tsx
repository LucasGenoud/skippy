"use client";

import { useState, type FormEvent } from "react";
import { BookmarkCheck, Bookmark, Plus, Trash2 } from "lucide-react";
import { GlyphPicker } from "@/components/common/glyph-picker";
import { IconButton } from "@/components/common/icon-button";
import { showAppSnack } from "@/components/common/snack";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Separator } from "@/components/ui/separator";
import { useNotesController, useSavedViews, useUiController } from "@/lib/store";
import { GlyphBadge, ManageRow, TextField } from "./form-bits";
import { Grip } from "./labels-dialog";
import { useShellDialogs } from "./shell-dialogs";
import { SortableRows } from "./sortable-rows";
import { smartViewNameProblem, smartViewQueryProblem } from "./taxonomy-rules";

/** The open workspace's smart views: create, reorder, edit, delete (`EditSmartViewsDialog`). */
export function SmartViewsDialog({ open, onOpenChange }: { open: boolean; onOpenChange(open: boolean): void }) {
  const views = useSavedViews();
  const notes = useNotesController();
  const dialogs = useShellDialogs();

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="flex max-h-[min(640px,calc(100dvh-2rem))] flex-col">
        <DialogHeader>
          <DialogTitle>Edit smart views</DialogTitle>
          <DialogDescription>A smart view is a saved search everyone in the workspace sees.</DialogDescription>
        </DialogHeader>
        <div className="-mx-2 flex min-h-0 flex-1 flex-col overflow-y-auto px-2">
          <Button variant="ghost" className="justify-start" onClick={() => dialogs.open({ type: "savedView", savedViewId: null })}>
            <Plus />
            Create new smart view
          </Button>
          <Separator className="my-1.5" />
          {views.length === 0 ? <p className="px-2 py-4 text-sm text-on-surface-variant">No smart views yet.</p> : null}
          <SortableRows
            items={views}
            idOf={(v) => v.id}
            onMove={(id, index) => notes.reorderSavedViews(views.findIndex((v) => v.id === id), index)}
            entrance="staggered"
          >
            {(view, handle) => (
              <ManageRow
                dragging={handle.dragging}
                grip={<Grip handleProps={handle.handleProps} />}
                leading={<GlyphBadge icon={view.icon} color={view.color} fallback={Bookmark} />}
                title={view.name}
                subtitle={view.query}
                onOpen={() => dialogs.open({ type: "savedView", savedViewId: view.id })}
                trailing={<IconButton size="sm" label="Delete smart view" icon={<Trash2 />} onClick={() => notes.removeSavedView(view.id)} />}
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

/**
 * Create or edit a smart view: its name, the search it stands for, and its
 * glyph (`SavedViewDialog`). "Save this search" arrives with the box's query
 * and opens the view it made.
 */
export function SavedViewDialog({
  open,
  onOpenChange,
  savedViewId,
  initialQuery,
  afterSave,
}: {
  open: boolean;
  onOpenChange(open: boolean): void;
  savedViewId: string | null;
  initialQuery: string;
  afterSave: "open" | "stay";
}) {
  const notes = useNotesController();
  const ui = useUiController();
  const views = useSavedViews();
  const dialogs = useShellDialogs();
  const [setup] = useState(() => ({
    workspaceId: notes.activeWorkspaceId,
    existing: savedViewId === null ? null : notes.savedViewById(savedViewId),
  }));
  const [name, setName] = useState(setup.existing?.name ?? "");
  const [query, setQuery] = useState(setup.existing?.query ?? initialQuery.trim());
  const [color, setColor] = useState<string | null>(setup.existing?.color ?? null);
  const [icon, setIcon] = useState<string | null>(setup.existing?.icon ?? null);
  const [nameError, setNameError] = useState<string | null>(null);
  const [queryError, setQueryError] = useState<string | null>(null);
  const creating = savedViewId === null;

  // The workspace switched, or the view was deleted on another device.
  const gone = (): boolean => setup.workspaceId === null || notes.activeWorkspaceId !== setup.workspaceId || (!creating && notes.savedViewById(savedViewId) === null);

  const save = (event: FormEvent): void => {
    event.preventDefault();
    if (gone()) {
      setNameError("This smart view is no longer available");
      return;
    }
    const trimmedName = name.trim();
    const trimmedQuery = query.trim();
    const nameProblem = smartViewNameProblem(trimmedName, views, savedViewId);
    const queryProblem = smartViewQueryProblem(trimmedQuery);
    if (nameProblem || queryProblem) {
      setNameError(nameProblem);
      setQueryError(queryProblem);
      return;
    }
    const fields = { name: trimmedName, query: trimmedQuery, icon, color };
    let id = savedViewId;
    if (id === null) {
      id = notes.addSavedView(fields).id;
    } else {
      notes.updateSavedView(id, fields);
    }
    onOpenChange(false);
    if (afterSave === "open") {
      ui.selectDestination({ smartView: id });
      showAppSnack("Smart view saved", { icon: BookmarkCheck });
    }
  };

  const remove = (): void => {
    if (savedViewId === null) {
      return;
    }
    dialogs.open({
      type: "confirm",
      title: `Delete "${name.trim()}"?`,
      description: "The smart view goes away. The notes it showed are untouched.",
      confirmLabel: "Delete",
      tone: "destructive",
      onConfirm: () => {
        if (notes.activeWorkspaceId === setup.workspaceId) {
          notes.removeSavedView(savedViewId);
        }
        onOpenChange(false);
      },
    });
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[min(760px,calc(100dvh-2rem))]">
        <form onSubmit={save} className="flex flex-col gap-5">
          <DialogHeader>
            <DialogTitle>{creating ? "New smart view" : "Edit smart view"}</DialogTitle>
            <DialogDescription className="sr-only">Name, search, colour and icon</DialogDescription>
          </DialogHeader>
          <TextField
            label="Name"
            autoFocus={creating}
            value={name}
            error={nameError}
            onChange={(e) => {
              setName(e.target.value);
              setNameError(null);
            }}
          />
          <TextField
            label="Search"
            value={query}
            className="[&_input]:font-mono [&_input]:text-[13px]"
            placeholder="label:work is:pinned hasnot:reminder"
            hint="Same filters as the search box"
            error={queryError}
            onChange={(e) => {
              setQuery(e.target.value);
              setQueryError(null);
            }}
          />
          <GlyphPicker color={color} onColorChange={setColor} icon={icon} onIconChange={setIcon} defaultIcon={Bookmark} customHex="hidden" />
          <DialogFooter className="items-center">
            {creating ? null : (
              <Button type="button" variant="ghost" className="mr-auto text-error hover:text-error" onClick={remove}>
                Delete
              </Button>
            )}
            <Button type="button" variant="ghost" onClick={() => onOpenChange(false)}>
              Cancel
            </Button>
            <Button type="submit">{creating ? "Save" : "Done"}</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
