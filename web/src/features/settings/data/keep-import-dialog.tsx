"use client";

import { useState } from "react";
import { Inbox } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import type { Workspace } from "@/lib/models";
import type { KeepArchive, KeepTrash } from "@/lib/util/keep-import";
import { CheckRow } from "../kit/check-row";
import { plural } from "../kit/files";
import { Field, FormDialog } from "../kit/form-dialog";

export interface KeepImportChoice {
  readonly workspaceId: string;
  readonly collectionId: string;
  readonly trash: KeepTrash;
}

/** The open workspace when it is a choice, else the first. */
export function initialKeepWorkspace(workspaces: readonly Workspace[], preferred: string | null): string | null {
  return workspaces.some((w) => w.id === preferred) ? preferred : (workspaces[0]?.id ?? null);
}

/** Where a Google Keep import goes, and whether Keep's trash comes too. */
export default function KeepImportDialog({
  archive,
  workspaces,
  initialWorkspaceId,
  open,
  onOpenChange,
  onImport,
}: {
  archive: KeepArchive;
  workspaces: readonly Workspace[];
  initialWorkspaceId: string | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onImport: (choice: KeepImportChoice) => void;
}) {
  const firstCollection = (id: string | null): string | null => workspaces.find((w) => w.id === id)?.collections[0]?.id ?? null;
  const [workspaceId, setWorkspaceId] = useState(() => initialKeepWorkspace(workspaces, initialWorkspaceId));
  const [collectionId, setCollectionId] = useState(() => firstCollection(workspaceId));
  const [includeTrash, setIncludeTrash] = useState(false);

  const trashed = archive.notes.filter((n) => n.trashed).length;
  const kept = archive.notes.length - trashed;
  const files = archive.notes.reduce((n, note) => n + note.attachments.length, 0);
  const collections = workspaces.find((w) => w.id === workspaceId)?.collections ?? [];

  function submit() {
    if (workspaceId === null || collectionId === null) {
      return;
    }
    onOpenChange(false);
    onImport({ workspaceId, collectionId, trash: includeTrash ? "include" : "skip" });
  }

  return (
    <FormDialog
      open={open}
      onOpenChange={onOpenChange}
      title="Import from Google Keep"
      width="wide"
      footer={
        <>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button onClick={submit} disabled={workspaceId === null || collectionId === null}>
            <Inbox aria-hidden />
            Import
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        <div className="flex flex-col gap-2">
          <p className="text-sm text-on-surface">
            {plural(kept, "note")} and {plural(files, "file")} will be added. Existing notes are not changed, and labels with the same name are shared.
          </p>
          {archive.missingFiles > 0 ? (
            <p className="text-sm text-on-surface-variant">
              {archive.missingFiles} attached {archive.missingFiles === 1 ? "file is" : "files are"} missing from the export or larger than 25 MB, and will be
              skipped.
            </p>
          ) : null}
        </div>
        <Field label="Workspace" htmlFor="keep-workspace">
          <Select
            value={workspaceId ?? undefined}
            onValueChange={(id) => {
              setWorkspaceId(id);
              setCollectionId(firstCollection(id));
            }}
          >
            <SelectTrigger id="keep-workspace" className="w-full">
              <SelectValue placeholder="Choose a workspace" />
            </SelectTrigger>
            <SelectContent>
              {workspaces.map((w) => (
                <SelectItem key={w.id} value={w.id}>
                  {w.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </Field>
        <Field label="Collection" htmlFor="keep-collection">
          <Select key={workspaceId ?? "none"} value={collectionId ?? undefined} onValueChange={setCollectionId}>
            <SelectTrigger id="keep-collection" className="w-full">
              <SelectValue placeholder="Choose a collection" />
            </SelectTrigger>
            <SelectContent>
              {collections.map((c) => (
                <SelectItem key={c.id} value={c.id}>
                  {c.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </Field>
        {trashed > 0 ? (
          <CheckRow
            title={`Also import ${plural(trashed, "note")} from Keep's trash`}
            subtitle="They go to the trash here too"
            checked={includeTrash}
            onCheckedChange={setIncludeTrash}
          />
        ) : null}
      </div>
    </FormDialog>
  );
}
