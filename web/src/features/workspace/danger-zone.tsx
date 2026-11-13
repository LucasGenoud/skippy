"use client";

import { useState } from "react";
import { Copy, Lock, LogOut, Trash2 } from "lucide-react";
import { showAppSnack } from "@/components/common/snack";
import {
  AlertDialog,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import type { Workspace } from "@/lib/models";
import { closeTo } from "@/lib/router";
import { useNotesController, useNotesSelector } from "@/lib/store";
import { copyText } from "@/features/settings/kit/files";
import { Hint, SettingsRow } from "@/features/settings/kit/rows";
import { useOpenKey } from "@/features/settings/kit/use-open-key";

/** What deleting a workspace with [noteCount] live notes takes with it. */
export function deletionMessage(noteCount: number): string {
  if (noteCount === 0) {
    return "Its labels and board columns are removed. This can't be undone.";
  }
  if (noteCount === 1) {
    return "1 note and all its attachments will be permanently deleted. This can't be undone.";
  }
  return `${noteCount} notes and all their attachments will be permanently deleted. This can't be undone.`;
}

/** Delete (owner, not the default), leave (member), or why neither applies. */
export function DangerZone({ workspace, isOwner }: { workspace: Workspace; isOwner: boolean }) {
  const notes = useNotesController();
  const canDelete = useNotesSelector(() => notes.canDeleteWorkspace(workspace.id), Object.is, [workspace.id]);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const confirmKey = useOpenKey(confirmOpen);

  if (canDelete) {
    const noteCount = notes.notesInWorkspace(workspace.id).filter((n) => !n.trashed).length;
    return (
      <div className="flex flex-col gap-3 px-3">
        <Hint className="px-0">Permanently removes its notes, labels, and board columns.</Hint>
        <Button variant="outline" className="h-11 border-error text-error hover:text-error" onClick={() => setConfirmOpen(true)}>
          <Trash2 aria-hidden />
          Delete workspace
        </Button>
        <DeleteWorkspaceDialog
          key={confirmKey}
          workspace={workspace}
          noteCount={noteCount}
          open={confirmOpen}
          onOpenChange={setConfirmOpen}
          onConfirm={() => {
            setConfirmOpen(false);
            closeTo({ name: "home" });
            notes.deleteWorkspace(workspace.id);
            showAppSnack(`Deleted "${workspace.name}"`, { icon: Trash2, kind: "danger" });
          }}
        />
      </div>
    );
  }
  if (!isOwner) {
    return (
      <SettingsRow
        icon={LogOut}
        title="Leave workspace"
        subtitle="Its notes stay with everyone else"
        trailing={null}
        onClick={() => {
          const me = notes.currentUserId;
          if (me === null) {
            return;
          }
          closeTo({ name: "home" });
          notes.removeWorkspaceMember(workspace.id, me);
        }}
      />
    );
  }
  // The workspace made with the account has nowhere to hand its notes over to.
  return <SettingsRow icon={Lock} title="Your default workspace" subtitle="It can't be deleted, so notes always have a home" disabled />;
}

/** The name, typed back, confirms a delete that takes every note with it. */
function DeleteWorkspaceDialog({
  workspace,
  noteCount,
  open,
  onOpenChange,
  onConfirm,
}: {
  workspace: Workspace;
  noteCount: number;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onConfirm: () => void;
}) {
  const [typed, setTyped] = useState("");
  const matches = typed === workspace.name;
  return (
    <AlertDialog open={open} onOpenChange={onOpenChange}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>Delete &ldquo;{workspace.name}&rdquo;?</AlertDialogTitle>
          <AlertDialogDescription>{deletionMessage(noteCount)}</AlertDialogDescription>
        </AlertDialogHeader>
        <form
          className="flex flex-col gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            if (matches) {
              onConfirm();
            }
          }}
        >
          <div className="flex flex-wrap items-center gap-1.5 text-xs text-on-surface-variant">
            Type
            <Button type="button" variant="secondary" size="xs" className="max-w-full" onClick={() => void copyText(workspace.name)} title="Copy workspace name">
              <Copy aria-hidden />
              <span className="truncate">{workspace.name}</span>
            </Button>
            to confirm.
          </div>
          <Input aria-label="Workspace name" autoFocus value={typed} onChange={(e) => setTyped(e.target.value)} />
        </form>
        <AlertDialogFooter>
          <AlertDialogCancel>Cancel</AlertDialogCancel>
          <Button variant="destructive" disabled={!matches} onClick={onConfirm}>
            Delete
          </Button>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
