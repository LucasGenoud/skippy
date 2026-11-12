"use client";

import { useState } from "react";
import { ArchiveRestore } from "lucide-react";
import { Button } from "@/components/ui/button";
import type { BackupBundle } from "@/lib/util/backup";
import { plural } from "../kit/files";
import { CheckRow } from "../kit/check-row";
import { FormDialog } from "../kit/form-dialog";

/** Picks which backed-up workspaces replace the owned ones. */
export default function RestoreBackupDialog({
  backup,
  open,
  onOpenChange,
  onRestore,
}: {
  backup: BackupBundle;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onRestore: (workspaceIds: ReadonlySet<string>) => void;
}) {
  const [selected, setSelected] = useState<ReadonlySet<string>>(() => new Set(backup.workspaces.map((w) => w.id)));

  function toggle(id: string, on: boolean) {
    setSelected((s) => {
      const next = new Set(s);
      if (on) {
        next.add(id);
      } else {
        next.delete(id);
      }
      return next;
    });
  }

  return (
    <FormDialog
      open={open}
      onOpenChange={onOpenChange}
      title="Choose workspaces to restore"
      width="wide"
      footer={
        <>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button
            disabled={selected.size === 0}
            onClick={() => {
              onOpenChange(false);
              onRestore(selected);
            }}
          >
            <ArchiveRestore aria-hidden />
            Replace and restore
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-3">
        <p className="text-sm text-on-surface">
          Restoring replaces all notes, labels, and board columns in the workspaces you own. Workspaces shared with you are not changed. Only the
          selected backup workspaces are recreated.
        </p>
        <div className="flex flex-col">
          {backup.workspaces.map((w) => (
            <CheckRow
              key={w.id}
              title={w.name}
              subtitle={`${plural(w.notes.length, "note")} · ${plural(w.labels.length, "label")} · ${plural(w.stages.length, "column")}`}
              checked={selected.has(w.id)}
              onCheckedChange={(on) => toggle(w.id, on)}
            />
          ))}
        </div>
        <p className="text-sm text-error">This cannot be undone. Create a fresh backup first if you might need the current data.</p>
      </div>
    </FormDialog>
  );
}
