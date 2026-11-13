"use client";

import { lazy, Suspense } from "react";

export { WorkspaceSettingsScreen } from "./workspace-settings-screen";
export { CollectionSettingsDialog } from "./collection-settings-dialog";
export { DuplicateWorkspaceDialog } from "./duplicate-workspace-dialog";
export { CreateWorkspaceDialog, RenameWorkspaceDialog } from "./workspace-dialogs";
export { WorkspaceAiSection } from "./workspace-ai-section";

// The statistics page and its charts load only when opened.
const LazyStats = lazy(() => import("./workspace-stats-screen"));

export function WorkspaceStatsScreen({ workspaceId }: { workspaceId: string }) {
  return (
    <Suspense fallback={<div className="h-dvh bg-surface" />}>
      <LazyStats workspaceId={workspaceId} />
    </Suspense>
  );
}
