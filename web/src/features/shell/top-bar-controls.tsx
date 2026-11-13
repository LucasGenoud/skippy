"use client";

import { lazy, Suspense, useState, type ReactNode } from "react";
import { ArrowUpDown, CircleAlert, CloudCheck, CloudOff, LogOut, Monitor, Moon, RefreshCw, Settings, Share, Sun, type LucideIcon } from "lucide-react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { cn } from "cn";
import { IconButton } from "@/components/common/icon-button";
import { MenuLabel } from "@/components/common/menu-label";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { navigate } from "@/lib/router";
import { SORT_MODES, type SortMode } from "@/lib/state/note-collection";
import {
  useActiveCollection,
  useActiveLayout,
  useActiveWorkspace,
  useActiveSort,
  useAuth,
  useAuthController,
  useLabel,
  useNotesSelector,
  useSession,
  useSettings,
  useSettingsController,
  useUiController,
  useViewSelection,
  type ThemeMode,
} from "@/lib/store";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";
import { isWorkspaceOwnedBy } from "@/lib/models/workspace";
import type { PublicLinkTarget } from "@/features/editor/public-link-dialog";
import { useShellDialogs } from "./shell-dialogs";
import { syncMenuLabel } from "./sync-rules";
import { viewLink } from "./view-rules";

const ViewLinkDialog = lazy(() => import("@/features/editor/public-link-dialog").then((m) => ({ default: m.ViewLinkDialog })));

const SORT_LABELS: Record<SortMode, string> = {
  custom: "Custom order",
  edited: "Recently edited",
  newest: "Recently added",
  oldest: "Oldest first",
};

const THEME: Record<ThemeMode, { icon: LucideIcon; label: string }> = {
  system: { icon: Monitor, label: "Auto" },
  light: { icon: Sun, label: "Light" },
  dark: { icon: Moon, label: "Dark" },
};

/** Sorting and the grid/list switch apply to a collection's own grid only. */
function useGridControls(): { collectionId: string | null; layout: string; grid: boolean } {
  const collection = useActiveCollection();
  const layout = useActiveLayout();
  const view = useViewSelection().view;
  const grid = collection !== null && layout !== "board" && view !== "reminders";
  return { collectionId: collection?.id ?? null, layout, grid };
}

/** Sort override for the open collection; anything but custom order stops drag reordering. */
export function SortMenu() {
  const ui = useUiController();
  const sort = useActiveSort();
  const { collectionId } = useGridControls();
  if (collectionId === null) {
    return null;
  }
  return (
    <DropdownMenu>
      <Tooltip>
        <TooltipTrigger asChild>
          <DropdownMenuTrigger asChild>
            <button
              type="button"
              aria-label="Sort by"
              className={cn(
                "inline-flex size-9 items-center justify-center rounded-md text-on-surface-variant transition-colors duration-150 ease-standard outline-none hover:bg-hover focus-visible:ring-[3px] focus-visible:ring-ring/50 data-[state=open]:bg-hover",
                sort !== "custom" && "text-primary",
              )}
            >
              <ArrowUpDown className="size-5" />
            </button>
          </DropdownMenuTrigger>
        </TooltipTrigger>
        <TooltipContent>Sort by: {SORT_LABELS[sort]}</TooltipContent>
      </Tooltip>
      <DropdownMenuContent align="end">
        <DropdownMenuLabel>Sort by</DropdownMenuLabel>
        <SortItems collectionId={collectionId} sort={sort} onPick={(mode) => ui.setSortOverride(collectionId, mode)} />
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

function SortItems({ sort, onPick }: { collectionId: string; sort: SortMode; onPick(mode: SortMode): void }) {
  return (
    <DropdownMenuRadioGroup value={sort} onValueChange={(v) => onPick(v as SortMode)}>
      {SORT_MODES.map((mode) => (
        <DropdownMenuRadioItem key={mode} value={mode}>
          {SORT_LABELS[mode]}
        </DropdownMenuRadioItem>
      ))}
    </DropdownMenuRadioGroup>
  );
}

/** The next layout the switch moves to, and whether that matches the shared one. */
export function nextGridLayout(current: string): "masonry" | "list" {
  return current === "list" ? "masonry" : "list";
}

/**
 * Flip this device between grid and list for the open collection. The shared
 * layout (and the board) stays in collection settings; returning to it clears
 * the local override.
 */
export function useToggleGridLayout(): (() => void) | null {
  const ui = useUiController();
  const collection = useActiveCollection();
  const { layout, grid } = useGridControls();
  if (!grid || collection === null) {
    return null;
  }
  return () => {
    const next = nextGridLayout(layout);
    ui.setLayoutOverride(collection.id, next === collection.layout ? null : next);
  };
}

/** The link "Share this view" would publish for the open view, or null when it is private. */
function useViewLink(): PublicLinkTarget | null {
  const selection = useViewSelection();
  const workspace = useActiveWorkspace();
  const collection = useActiveCollection();
  const label = useLabel(selection.labelId);
  const { userId } = useSession();
  return viewLink(selection, {
    workspace: workspace ? { id: workspace.id, name: workspace.name, owned: isWorkspaceOwnedBy(workspace, userId) } : null,
    collection: collection ? { id: collection.id, name: collection.name } : null,
    label: label ? { id: label.id, name: label.name } : null,
  });
}

/**
 * Opens the public-link dialog for the open view. The target is taken when
 * the dialog opens, so it stays put while the dialog is up.
 */
function useShareView(): { share: (() => void) | null; dialog: ReactNode } {
  const link = useViewLink();
  const [target, setTarget] = useState<PublicLinkTarget | null>(null);
  const dialog = target ? (
    <Suspense fallback={null}>
      <ViewLinkDialog target={target} open onOpenChange={(open) => !open && setTarget(null)} />
    </Suspense>
  ) : null;
  return { share: link ? () => setTarget(link) : null, dialog };
}

/** "Share this view" (`HomeTopBar`): publishes the open collection, board or label. */
export function ShareViewButton() {
  const { share, dialog } = useShareView();
  const reduced = useReducedMotion();
  return (
    <>
        <AnimatePresence initial={false}>
          {share ? (
            <motion.span
              key="share-view"
              className="inline-flex"
              initial={{ opacity: 0, scale: 0.6 }}
              animate={{ opacity: 1, scale: 1 }}
              exit={{ opacity: 0, scale: 0.6 }}
              transition={transitionFor(TRANSITION.fast, reduced)}
            >
              <IconButton label="Share this view" icon={<Share />} onClick={share} />
            </motion.span>
          ) : null}
        </AnimatePresence>
        {dialog}
    </>
  );
}

/** Shows the current theme; a tap cycles to the next (matches Settings, Appearance). */
export function ThemeToggle() {
  const mode = useSettings((s) => s.themeMode);
  const settings = useSettingsController();
  const reduced = useReducedMotion();
  const { icon: Icon, label } = THEME[mode];
  return (
    <IconButton
      label={`Theme: ${label}, click to change`}
      onClick={() => settings.cycleThemeMode()}
      icon={
        <span className="inline-grid">
          <AnimatePresence initial={false}>
            <motion.span
              key={mode}
              className="[grid-area:1/1]"
              initial={{ opacity: 0, rotate: -50 }}
              animate={{ opacity: 1, rotate: 0 }}
              exit={{ opacity: 0, rotate: 50 }}
              transition={transitionFor(TRANSITION.base, reduced)}
            >
              <Icon className="size-5" />
            </motion.span>
          </AnimatePresence>
        </span>
      }
    />
  );
}

/**
 * The avatar and its menu: who is signed in, how sync stands, settings and
 * sign-out. On a phone it also holds share, sort and theme, which the bar
 * has no room for (`_UserAvatarMenu`).
 */
export function UserMenu({ variant }: { variant: "wide" | "compact" }) {
  const auth = useAuthController();
  const user = useAuth((s) => s.user);
  const activeUrl = useAuth((s) => s.activeUrl);
  const settings = useSettingsController();
  const mode = useSettings((s) => s.themeMode);
  const ui = useUiController();
  const sort = useActiveSort();
  const dialogs = useShellDialogs();
  const { share, dialog } = useShareView();
  const { collectionId } = useGridControls();
  const status = useNotesSelector((s) => s.syncStatus);
  const pending = useNotesSelector((s) => s.pendingChanges);
  const issues = useNotesSelector((s) => s.syncIssues.length);
  const cacheFailure = useNotesSelector((s) => s.cacheFailure !== null);
  const name = user?.name ?? "";
  const initial = name.trim() === "" ? "?" : Array.from(name.trim())[0]!.toUpperCase();
  const syncLabel = syncMenuLabel({ status, pending, issues, cacheFailure });
  const trouble = issues > 0 || cacheFailure;
  const theme = THEME[mode];

  return (
    <>
    <DropdownMenu>
      <DropdownMenuTrigger
        aria-label={`${name === "" ? "Account" : name}, ${syncLabel}`}
        className="relative inline-flex size-9 shrink-0 items-center justify-center rounded-full outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50"
      >
        <span className="inline-flex size-8 items-center justify-center rounded-full bg-primary-container text-sm font-semibold text-on-primary-container">{initial}</span>
        <SyncBadge status={status} />
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-64">
        <div className="flex items-center gap-3 px-2.5 py-2">
          <span className="inline-flex size-9 shrink-0 items-center justify-center rounded-full bg-primary-container text-base font-semibold text-on-primary-container">{initial}</span>
          <span className="flex min-w-0 flex-col">
            <span className="truncate text-sm font-semibold text-on-surface">{name}</span>
            <span className="truncate text-2xs text-on-surface-variant">{user?.email ?? activeUrl}</span>
          </span>
        </div>
        <DropdownMenuSeparator />
        <DropdownMenuItem onSelect={() => dialogs.open({ type: "sync" })}>
          {trouble ? <CircleAlert className="text-error!" /> : status === "offline" ? <CloudOff /> : <CloudCheck />}
          <MenuLabel label={syncLabel} hint={!trouble && pending > 0 ? `${pending} queued` : undefined} />
        </DropdownMenuItem>
        <DropdownMenuItem onSelect={() => navigate({ name: "settings", page: null })}>
          <Settings />
          <MenuLabel label="Settings" hint="Account, theme, AI" />
        </DropdownMenuItem>
        {variant === "compact" ? (
          <>
            {share ? (
              <DropdownMenuItem onSelect={share}>
                <Share />
                <MenuLabel label="Share this view" hint="As a public link" />
              </DropdownMenuItem>
            ) : null}
            <DropdownMenuItem onSelect={() => settings.cycleThemeMode()}>
              <theme.icon />
              <MenuLabel label={`Theme: ${theme.label}`} />
            </DropdownMenuItem>
            {collectionId !== null ? (
              <>
                <DropdownMenuSeparator />
                <DropdownMenuLabel>Sort by</DropdownMenuLabel>
                <SortItems collectionId={collectionId} sort={sort} onPick={(m) => ui.setSortOverride(collectionId, m)} />
              </>
            ) : null}
          </>
        ) : null}
        <DropdownMenuSeparator />
        <DropdownMenuItem variant="destructive" onSelect={() => auth.signOut()}>
          <LogOut />
          Sign out
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
    {dialog}
    </>
  );
}

/** A bare glyph over the avatar's corner: offline, failed, syncing (turning) or saved. */
function SyncBadge({ status }: { status: string }) {
  const spinning = status === "syncing" || status === "connecting";
  const Icon = status === "offline" ? CloudOff : status === "failed" ? CircleAlert : spinning ? RefreshCw : CloudCheck;
  const tone = status === "offline" || status === "failed" ? "text-error" : spinning ? "text-primary" : "text-on-surface-variant";
  return (
    <span aria-hidden className="absolute -right-0.5 -bottom-0.5 inline-flex size-4 items-center justify-center rounded-xs bg-surface">
      <Icon className={cn("size-3 transition-colors duration-150 ease-standard", tone, spinning && "animate-spin")} strokeWidth={2.5} />
    </span>
  );
}
