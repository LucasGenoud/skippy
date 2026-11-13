"use client";

import { Check, ChevronDown, Plus, Settings, Users } from "lucide-react";
import { cn } from "cn";
import { MenuLabel } from "@/components/common/menu-label";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { isWorkspaceOwnedBy, isWorkspaceShared } from "@/lib/models/workspace";
import { navigate } from "@/lib/router";
import { useActiveWorkspace, useNotesController, useSession, useWorkspaces } from "@/lib/store";
import { useShellDialogs } from "./shell-dialogs";

/** A workspace's first character, for the square that stands in for it. */
export function workspaceInitial(name: string): string {
  const first = Array.from(name.trim())[0];
  return first ? first.toUpperCase() : "?";
}

/**
 * The switcher heading the sidebar: the open workspace's name, and a menu to
 * switch, create or manage (`WorkspaceMenu`); renaming, copying and statistics
 * live in workspace settings. [beforeAction]
 * runs an action once the phone drawer has closed, so a dialog or page it
 * opens does not animate through the closing drawer.
 */
export function WorkspaceMenu({ compact, beforeAction }: { compact: boolean; beforeAction?: (run: () => void) => void }) {
  const workspaces = useWorkspaces();
  const active = useActiveWorkspace();
  const notes = useNotesController();
  const { userId } = useSession();
  const dialogs = useShellDialogs();
  // Before the first load resolves a workspace the header stays put.
  const name = active?.name ?? "Workspace";

  const act = (run: () => void): void => {
    if (beforeAction) {
      beforeAction(run);
      return;
    }
    run();
  };

  const trigger = (
    <DropdownMenuTrigger
      aria-label={`Workspace: ${name}. Switch workspace`}
      className={cn(
        "group/ws flex h-12 w-full min-w-0 items-center gap-2.5 rounded-md border border-outline-variant bg-surface-container-low px-2 text-left shadow-card outline-none transition-[background-color,border-color] duration-150 ease-standard hover:bg-hover focus-visible:ring-[3px] focus-visible:ring-ring/50 data-[state=open]:border-outline",
        compact && "justify-center px-0",
      )}
    >
      <span className="inline-flex size-7 shrink-0 items-center justify-center rounded-md bg-secondary-container text-sm font-semibold text-on-secondary-container">
        {workspaceInitial(name)}
      </span>
      <span className={cn("min-w-0 truncate text-sm font-semibold text-on-surface transition-opacity duration-150 ease-standard", compact && "sr-only")}>{name}</span>
      {compact ? null : (
        <ChevronDown aria-hidden className="-ml-1 size-4 shrink-0 text-on-surface-variant transition-transform duration-240 ease-emphasized group-data-[state=open]/ws:rotate-180" />
      )}
    </DropdownMenuTrigger>
  );

  return (
    <DropdownMenu>
      {compact ? (
        <Tooltip>
          <TooltipTrigger asChild>{trigger}</TooltipTrigger>
          <TooltipContent side="right">{name}</TooltipContent>
        </Tooltip>
      ) : (
        trigger
      )}
      <DropdownMenuContent align="start" className="w-64">
        {workspaces.map((w) => (
          <DropdownMenuItem key={w.id} onSelect={() => act(() => notes.setActiveWorkspace(w.id))}>
            <span className="inline-flex size-4 items-center justify-center">{w.id === active?.id ? <Check className="text-primary!" /> : null}</span>
            <span className="min-w-0 flex-1 truncate">{w.name}</span>
            {isWorkspaceShared(w) || !isWorkspaceOwnedBy(w, userId) ? <Users aria-label="Shared" /> : null}
          </DropdownMenuItem>
        ))}
        <DropdownMenuSeparator />
        <DropdownMenuItem onSelect={() => act(() => dialogs.open({ type: "createWorkspace" }))}>
          <Plus />
          <MenuLabel label="New workspace" />
        </DropdownMenuItem>
        <DropdownMenuItem disabled={!active} onSelect={() => active && act(() => navigate({ name: "workspaceSettings", workspaceId: active.id }))}>
          <Settings />
          <MenuLabel label="Workspace settings" />
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
