"use client";

// Placeholders: the SETTINGS agent replaces these.
export function WorkspaceSettingsScreen({ workspaceId }: { workspaceId: string }) {
  return <div data-placeholder="workspace-settings" data-workspace={workspaceId} />;
}

export function WorkspaceStatsScreen({ workspaceId }: { workspaceId: string }) {
  return <div data-placeholder="workspace-stats" data-workspace={workspaceId} />;
}
