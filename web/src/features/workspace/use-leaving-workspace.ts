"use client";

import { useState } from "react";
import type { Workspace } from "@/lib/models";
import { useRoute } from "@/lib/router";
import { useWorkspace } from "@/lib/store";

/**
 * The workspace a workspace page shows. Deleting or leaving it closes the
 * page first, then removes it; while the page plays its exit it keeps
 * showing the workspace as it last was, instead of flashing "gone".
 */
export function useLeavingWorkspace(workspaceId: string): Workspace | null {
  const workspace = useWorkspace(workspaceId);
  const route = useRoute();
  const [last, setLast] = useState(workspace);
  if (workspace !== null && workspace !== last) {
    setLast(workspace);
  }
  const shownHere = (route.name === "workspaceSettings" || route.name === "workspaceStats") && route.workspaceId === workspaceId;
  return workspace ?? (shownHere ? null : last);
}
