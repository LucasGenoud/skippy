"use client";

import { useState } from "react";
import { Layers } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useNotesController, useWorkspace } from "@/lib/store";
import { FormDialog } from "@/features/settings/kit/form-dialog";
import { useOpenKey } from "@/features/settings/kit/use-open-key";

export const MAX_WORKSPACE_NAME = 60;

export interface WorkspaceDialogProps {
  open: boolean;
  onOpenChange(open: boolean): void;
  /** The workspace being renamed; ignored when creating. */
  workspaceId?: string;
}

/** Names a new workspace and switches to it. */
export function CreateWorkspaceDialog({ open, onOpenChange }: WorkspaceDialogProps) {
  const notes = useNotesController();
  const key = useOpenKey(open);
  return <NameDialog key={key} mode="create" initial="" open={open} onOpenChange={onOpenChange} onSubmit={(name) => notes.createWorkspace(name)} />;
}

/** Renames [workspaceId]. */
export function RenameWorkspaceDialog({ open, onOpenChange, workspaceId }: WorkspaceDialogProps) {
  const notes = useNotesController();
  const workspace = useWorkspace(workspaceId);
  const key = useOpenKey(open);
  return (
    <NameDialog
      key={key}
      mode="rename"
      initial={workspace?.name ?? ""}
      open={open}
      onOpenChange={onOpenChange}
      onSubmit={(name) => workspaceId && notes.renameWorkspace(workspaceId, name)}
    />
  );
}

function NameDialog({
  mode,
  initial,
  open,
  onOpenChange,
  onSubmit,
}: {
  mode: "create" | "rename";
  initial: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSubmit: (name: string) => void;
}) {
  const [name, setName] = useState(initial);
  const creating = mode === "create";

  function submit() {
    const trimmed = name.trim();
    if (!trimmed) {
      return;
    }
    onOpenChange(false);
    onSubmit(trimmed);
  }

  return (
    <FormDialog
      open={open}
      onOpenChange={onOpenChange}
      title={creating ? "New workspace" : "Rename workspace"}
      width="compact"
      onSubmit={submit}
      footer={
        <>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button onClick={submit} disabled={!name.trim()}>
            {creating ? "Create" : "Rename"}
          </Button>
        </>
      }
    >
      <div className="relative">
        <Layers aria-hidden className="pointer-events-none absolute top-2.5 left-3 size-4 text-on-surface-variant" />
        <Input
          aria-label="Workspace name"
          autoFocus
          maxLength={MAX_WORKSPACE_NAME}
          placeholder="Workspace name"
          className="pl-9"
          value={name}
          onChange={(e) => setName(e.target.value)}
        />
      </div>
    </FormDialog>
  );
}
