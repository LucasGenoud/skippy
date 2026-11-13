"use client";

import { createContext, lazy, Suspense, useCallback, useContext, useMemo, useRef, useState, type ReactNode } from "react";
import { DURATION } from "@/lib/theme/motion";
import { CollectionSettingsDialog } from "@/features/workspace/collection-settings-dialog";
import { DuplicateWorkspaceDialog } from "@/features/workspace/duplicate-workspace-dialog";
import { CreateWorkspaceDialog, RenameWorkspaceDialog } from "@/features/workspace/workspace-dialogs";
import { MoveToStageDialog } from "@/features/board/move-to-stage-dialog";

// The shell's dialogs, held above the sidebar drawer so closing the drawer
// never unmounts a dialog it opened. Dialogs stack: the labels list opens a
// label's editor on top of itself.

const LabelsDialog = lazy(() => import("./labels-dialog").then((m) => ({ default: m.LabelsDialog })));
const CollectionsDialog = lazy(() => import("./collections-dialog").then((m) => ({ default: m.CollectionsDialog })));
const LabelEditorDialog = lazy(() => import("./labels-dialog").then((m) => ({ default: m.LabelEditorDialog })));
const SmartViewsDialog = lazy(() => import("./smart-view-dialogs").then((m) => ({ default: m.SmartViewsDialog })));
const SavedViewDialog = lazy(() => import("./smart-view-dialogs").then((m) => ({ default: m.SavedViewDialog })));
const ShortcutHelpDialog = lazy(() => import("./shortcut-help").then((m) => ({ default: m.ShortcutHelpDialog })));
const SyncSheet = lazy(() => import("./sync-sheet").then((m) => ({ default: m.SyncSheet })));
const SearchFiltersSurface = lazy(() => import("./search-filters").then((m) => ({ default: m.SearchFiltersSurface })));
const RecordingDialog = lazy(() => import("./recording-dialog").then((m) => ({ default: m.RecordingDialog })));
const BulkColorSurface = lazy(() => import("./bulk-dialogs").then((m) => ({ default: m.BulkColorSurface })));
const MoveToCollectionSurface = lazy(() => import("./bulk-dialogs").then((m) => ({ default: m.MoveToCollectionSurface })));
const MoveToWorkspaceSurface = lazy(() => import("./bulk-dialogs").then((m) => ({ default: m.MoveToWorkspaceSurface })));
const RestorePickerSurface = lazy(() => import("./bulk-dialogs").then((m) => ({ default: m.RestorePickerSurface })));
const ConfirmDialog = lazy(() => import("./confirm-dialog").then((m) => ({ default: m.ConfirmDialog })));

export type ShellDialog =
  | { readonly type: "labels" }
  | { readonly type: "collections" }
  | { readonly type: "labelEditor"; readonly labelId: string | null }
  | { readonly type: "smartViews" }
  | { readonly type: "savedView"; readonly savedViewId: string | null; readonly initialQuery?: string; readonly afterSave?: "open" | "stay" }
  | { readonly type: "collection"; readonly workspaceId: string; readonly collectionId?: string }
  | { readonly type: "createWorkspace" }
  | { readonly type: "renameWorkspace"; readonly workspaceId: string }
  | { readonly type: "duplicateWorkspace"; readonly workspaceId: string }
  | { readonly type: "shortcuts" }
  | { readonly type: "sync" }
  | { readonly type: "filters" }
  | { readonly type: "recording"; readonly labelIds: readonly string[] }
  | { readonly type: "bulkColor"; readonly noteIds: readonly string[] }
  | { readonly type: "moveToCollection"; readonly noteIds: readonly string[] }
  | { readonly type: "moveToWorkspace"; readonly noteIds: readonly string[] }
  | { readonly type: "moveToStage"; readonly noteIds: readonly string[] }
  | { readonly type: "restorePicker"; readonly noteIds: readonly string[]; readonly workspaceId: string }
  | {
      readonly type: "confirm";
      readonly title: string;
      readonly description: string;
      readonly confirmLabel: string;
      readonly tone: "default" | "destructive";
      readonly onConfirm: () => void;
    };

interface Entry {
  readonly key: number;
  readonly dialog: ShellDialog;
  readonly open: boolean;
}

interface ShellDialogsApi {
  open(dialog: ShellDialog): void;
}

const DialogsContext = createContext<ShellDialogsApi | null>(null);

/** Opens a shell dialog from anywhere under the shell. */
export function useShellDialogs(): ShellDialogsApi {
  const api = useContext(DialogsContext);
  if (!api) {
    throw new Error("useShellDialogs outside ShellDialogsProvider");
  }
  return api;
}

/** How long a closed dialog stays mounted so its exit animation can play. */
const EXIT_MS = DURATION.fast + 50;

export function ShellDialogsProvider({ children }: { children: ReactNode }) {
  const [entries, setEntries] = useState<readonly Entry[]>([]);
  const nextKey = useRef(0);

  const open = useCallback((dialog: ShellDialog) => {
    nextKey.current += 1;
    const key = nextKey.current;
    setEntries((current) => [...current, { key, dialog, open: true }]);
  }, []);

  const close = useCallback((key: number) => {
    setEntries((current) => current.map((e) => (e.key === key ? { ...e, open: false } : e)));
    window.setTimeout(() => setEntries((current) => current.filter((e) => e.key !== key)), EXIT_MS);
  }, []);

  const api = useMemo(() => ({ open }), [open]);

  return (
    <DialogsContext.Provider value={api}>
      {children}
      <Suspense fallback={null}>
        {entries.map((entry) => (
          <DialogFor key={entry.key} dialog={entry.dialog} open={entry.open} onOpenChange={(next) => (next ? undefined : close(entry.key))} />
        ))}
      </Suspense>
    </DialogsContext.Provider>
  );
}

function DialogFor({ dialog, open, onOpenChange }: { dialog: ShellDialog; open: boolean; onOpenChange(open: boolean): void }) {
  const props = { open, onOpenChange };
  switch (dialog.type) {
    case "labels":
      return <LabelsDialog {...props} />;
    case "collections":
      return <CollectionsDialog {...props} />;
    case "labelEditor":
      return <LabelEditorDialog {...props} labelId={dialog.labelId} />;
    case "smartViews":
      return <SmartViewsDialog {...props} />;
    case "savedView":
      return <SavedViewDialog {...props} savedViewId={dialog.savedViewId} initialQuery={dialog.initialQuery ?? ""} afterSave={dialog.afterSave ?? "stay"} />;
    case "collection":
      return <CollectionSettingsDialog {...props} workspaceId={dialog.workspaceId} collectionId={dialog.collectionId} />;
    case "createWorkspace":
      return <CreateWorkspaceDialog {...props} />;
    case "renameWorkspace":
      return <RenameWorkspaceDialog {...props} workspaceId={dialog.workspaceId} />;
    case "duplicateWorkspace":
      return <DuplicateWorkspaceDialog {...props} workspaceId={dialog.workspaceId} />;
    case "shortcuts":
      return <ShortcutHelpDialog {...props} />;
    case "sync":
      return <SyncSheet {...props} />;
    case "filters":
      return <SearchFiltersSurface {...props} />;
    case "recording":
      return <RecordingDialog {...props} labelIds={dialog.labelIds} />;
    case "bulkColor":
      return <BulkColorSurface {...props} noteIds={dialog.noteIds} />;
    case "moveToCollection":
      return <MoveToCollectionSurface {...props} noteIds={dialog.noteIds} />;
    case "moveToWorkspace":
      return <MoveToWorkspaceSurface {...props} noteIds={dialog.noteIds} />;
    case "moveToStage":
      return <MoveToStageDialog {...props} noteIds={dialog.noteIds} />;
    case "restorePicker":
      return <RestorePickerSurface {...props} noteIds={dialog.noteIds} workspaceId={dialog.workspaceId} />;
    case "confirm":
      return (
        <ConfirmDialog
          {...props}
          title={dialog.title}
          description={dialog.description}
          confirmLabel={dialog.confirmLabel}
          tone={dialog.tone}
          onConfirm={dialog.onConfirm}
        />
      );
  }
}
