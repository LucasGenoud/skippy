"use client";

import { ChevronRight, Folder, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Separator } from "@/components/ui/separator";
import { useCollections, useNotesController } from "@/lib/store";
import { layoutLabel } from "@/features/workspace/collection-labels";
import { GlyphBadge, ManageRow } from "./form-bits";
import { Grip } from "./labels-dialog";
import { useShellDialogs } from "./shell-dialogs";
import { SortableRows } from "./sortable-rows";

/**
 * The open workspace's collections: create, reorder, and open one's settings
 * (`ManageCollectionsDialog`). Settings open on top, as the labels list does.
 */
export function CollectionsDialog({ open, onOpenChange }: { open: boolean; onOpenChange(open: boolean): void }) {
  const collections = useCollections();
  const notes = useNotesController();
  const dialogs = useShellDialogs();
  const workspaceId = notes.activeWorkspaceId;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="flex max-h-[min(640px,calc(100dvh-2rem))] flex-col">
        <DialogHeader>
          <DialogTitle>Manage collections</DialogTitle>
          <DialogDescription>Collections are shared by everyone in this workspace.</DialogDescription>
        </DialogHeader>
        <div className="-mx-2 flex min-h-0 flex-1 flex-col overflow-y-auto px-2">
          {workspaceId !== null ? (
            <Button variant="ghost" className="justify-start" onClick={() => dialogs.open({ type: "collection", workspaceId })}>
              <Plus />
              Create new collection
            </Button>
          ) : null}
          <Separator className="my-1.5" />
          <SortableRows items={collections} idOf={(c) => c.id} onMove={(id, index) => notes.moveCollection(id, index)} entrance="staggered">
            {(collection, handle) => (
              <ManageRow
                dragging={handle.dragging}
                grip={<Grip handleProps={handle.handleProps} />}
                leading={<GlyphBadge icon={collection.icon} color={collection.color} fallback={Folder} />}
                title={collection.name}
                subtitle={layoutLabel(collection.layout)}
                subtitleFont="sans"
                onOpen={() => dialogs.open({ type: "collection", workspaceId: collection.workspaceId, collectionId: collection.id })}
                trailing={<ChevronRight aria-hidden className="mr-1.5 size-4 shrink-0 text-on-surface-variant" />}
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
