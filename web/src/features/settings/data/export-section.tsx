"use client";

import { lazy, Suspense, useState } from "react";
import { ArchiveRestore, CircleAlert, CircleCheck, Download, Inbox, Package } from "lucide-react";
import { Reveal } from "@/components/common/reveal";
import { showAppSnack } from "@/components/common/snack";
import { Button } from "@/components/ui/button";
import { Progress } from "@/components/ui/progress";
import type { Attachment } from "@/lib/models";
import { useNotesController, useNotesSelector } from "@/lib/store";
import type { BackupBundle } from "@/lib/util/backup";
import type { KeepArchive } from "@/lib/util/keep-import";
import { EXPORT_FORMATS, exportFilename, exportFormatSpec, exportNotes, type ExportFormat } from "@/lib/util/note-export";
import { downloadFile, pickFile, plural } from "../kit/files";
import { SettingsRow } from "../kit/rows";
import { useDialog } from "../kit/use-dialog";
import { importedMessage, partialMessage, progressText, restoredMessage } from "./data-messages";
import type { KeepImportChoice } from "./keep-import-dialog";

// Zip handling (jszip) and the two choosers load only when used.
const RestoreBackupDialog = lazy(() => import("./restore-backup-dialog"));
const KeepImportDialog = lazy(() => import("./keep-import-dialog"));

const ATTACHMENT_TIMEOUT_MS = 60_000;
const HTTP_OK = 200;
const ZIP_ACCEPT = ".zip,application/zip";

interface Job {
  readonly status: string;
  /** 0..100, or null while the length is unknown. */
  readonly progress: number | null;
}

const fraction = (done: number, total: number): number | null => (total === 0 ? null : (done / total) * 100);

const failure = (error: unknown, fallback: string): string => (error instanceof Error && error.message ? error.message : fallback);

/**
 * Readable exports, a portable zip backup with attachment bytes, restore, and
 * a Google Keep import. Restore and import are awaited server writes, which
 * the store refuses while offline.
 */
export function ExportSection() {
  const notes = useNotesController();
  const count = useNotesSelector(() => notes.notesForExport.length);
  const restoring = useNotesSelector((s) => s.restoringBackup);
  const [job, setJob] = useState<Job | null>(null);
  const restore = useDialog<BackupBundle>();
  const keep = useDialog<KeepArchive>();
  const busy = job !== null || restoring;
  const update = setJob;

  function exportText(format: ExportFormat) {
    const list = notes.notesForExport;
    if (list.length === 0) {
      showAppSnack("No notes to export");
      return;
    }
    const spec = exportFormatSpec(format);
    downloadFile(exportFilename(format), exportNotes(list, format, { labels: notes.labelsForBackup, workspaces: notes.ownedWorkspaces }), spec.mime);
    showAppSnack(`Exported ${plural(list.length, "note")} as ${spec.label}`);
  }

  async function readAttachment(attachment: Attachment): Promise<Uint8Array> {
    const response = await fetch(notes.fileUrl(attachment), { signal: AbortSignal.timeout(ATTACHMENT_TIMEOUT_MS) });
    if (response.status !== HTTP_OK) {
      throw new Error(`Couldn't download ${attachment.filename || "an attachment"}`);
    }
    return new Uint8Array(await response.arrayBuffer());
  }

  async function createBackup() {
    const workspaces = notes.ownedWorkspaces;
    const list = notes.notesForBackup;
    if (workspaces.length === 0) {
      showAppSnack("Nothing to back up");
      return;
    }
    update({ status: "Preparing backup…", progress: null });
    try {
      const { createBackupArchive, backupFilename } = await import("@/lib/util/backup");
      const bytes = await createBackupArchive({
        workspaces,
        notes: list,
        labels: notes.labelsForBackup,
        stages: notes.stagesForBackup,
        readAttachment,
        onProgress: (done, total) => update({ status: progressText("Adding files", done, total), progress: fraction(done, total) }),
      });
      update({ status: "Saving backup…", progress: null });
      downloadFile(backupFilename(), bytes as BlobPart, "application/zip");
      showAppSnack(`Backup created with ${plural(list.length, "note")}`, { icon: Package });
    } catch (error) {
      showAppSnack(failure(error, "Couldn't create the backup"), { icon: CircleAlert, kind: "danger" });
    } finally {
      update(null);
    }
  }

  async function chooseBackup() {
    const file = await pickFile(ZIP_ACCEPT);
    if (!file) {
      return;
    }
    try {
      const { parseBackupArchive } = await import("@/lib/util/backup");
      restore.show(await parseBackupArchive(new Uint8Array(await file.arrayBuffer())));
    } catch (error) {
      showAppSnack(failure(error, "This file is not a readable Skippy backup"), { icon: CircleAlert, kind: "danger" });
    }
  }

  async function runRestore(bundle: BackupBundle, workspaceIds: ReadonlySet<string>) {
    update({ status: "Restoring backup…", progress: 0 });
    try {
      const result = await notes.restoreBackup(bundle, {
        workspaceIds,
        onProgress: (done, total) => update({ status: progressText("Restoring", done, total), progress: fraction(done, total) }),
      });
      showAppSnack(restoredMessage(result), { icon: CircleCheck, kind: "success" });
    } catch (error) {
      const done = (error as { restoredNotes?: number }).restoredNotes ?? 0;
      showAppSnack(partialMessage(failure(error, "Couldn't restore the backup"), done, "restored"), { icon: CircleAlert, kind: "danger" });
    } finally {
      update(null);
    }
  }

  async function chooseKeep() {
    const file = await pickFile(ZIP_ACCEPT);
    if (!file) {
      return;
    }
    try {
      const { parseKeepArchive } = await import("@/lib/util/keep-import");
      keep.show(await parseKeepArchive(new Uint8Array(await file.arrayBuffer())));
    } catch (error) {
      showAppSnack(failure(error, "This file is not a Google Takeout export"), { icon: CircleAlert, kind: "danger" });
    }
  }

  async function runKeep(archive: KeepArchive, choice: KeepImportChoice) {
    update({ status: "Importing from Google Keep…", progress: 0 });
    try {
      const result = await notes.importKeep(archive, {
        ...choice,
        onProgress: (done, total) => update({ status: progressText("Importing", done, total), progress: fraction(done, total) }),
      });
      showAppSnack(importedMessage(result), { icon: CircleCheck, kind: "success" });
    } catch (error) {
      const done = (error as { restoredNotes?: number }).restoredNotes ?? 0;
      showAppSnack(partialMessage(failure(error, "Couldn't import from Google Keep"), done, "imported"), { icon: CircleAlert, kind: "danger" });
    } finally {
      update(null);
    }
  }

  return (
    <>
      <SettingsRow
        icon={Package}
        title="Create backup"
        subtitle="A zip of every workspace you own: notes, labels, board columns, reminders, trash, and attached files"
        disabled={busy}
        onClick={() => void createBackup()}
        trailing={null}
      />
      <SettingsRow
        icon={ArchiveRestore}
        title="Restore backup"
        subtitle="Replaces the workspaces you pick with their backed-up copy"
        disabled={busy}
        onClick={() => void chooseBackup()}
        trailing={null}
      />
      <SettingsRow
        icon={Inbox}
        title="Import from Google Keep"
        subtitle="Adds the notes from a Google Takeout export, replacing nothing"
        disabled={busy}
        onClick={() => void chooseKeep()}
        trailing={null}
      />
      <SettingsRow icon={Download} title="Export notes" subtitle="A readable copy, without trash or attached files" disabled={busy || count === 0} />
      <div className="flex flex-wrap gap-2 pb-1 pl-12">
        {EXPORT_FORMATS.map((f) => (
          <Button key={f.id} variant="outline" size="sm" disabled={busy || count === 0} onClick={() => exportText(f.id)}>
            {f.label}
          </Button>
        ))}
      </div>
      <Reveal>
        {job ? (
          <div className="flex flex-col gap-2 px-3 pt-4" aria-live="polite">
            <span className="text-xs text-on-surface-variant">{job.status}</span>
            <Progress aria-label={job.status} value={job.progress ?? 8} className={job.progress === null ? "animate-pulse" : undefined} />
          </div>
        ) : null}
      </Reveal>
      <Suspense fallback={null}>
        {restore.value ? (
          <RestoreBackupDialog
            key={restore.key}
            backup={restore.value}
            open={restore.open}
            onOpenChange={restore.onOpenChange}
            onRestore={(ids) => restore.value && void runRestore(restore.value, ids)}
          />
        ) : null}
        {keep.value ? (
          <KeepImportDialog
            key={keep.key}
            archive={keep.value}
            workspaces={notes.workspaces}
            initialWorkspaceId={notes.activeWorkspaceId}
            open={keep.open}
            onOpenChange={keep.onOpenChange}
            onImport={(choice) => keep.value && void runKeep(keep.value, choice)}
          />
        ) : null}
      </Suspense>
    </>
  );
}
