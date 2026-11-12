"use client";

import { useRef, useState, type ReactNode } from "react";
import { cn } from "cn";
import { SyncPill } from "@/components/common/sync-pill";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Sheet, SheetContent, SheetDescription, SheetTitle } from "@/components/ui/sheet";
import { useActiveCollection, useActiveLayout, useNotesSelector, useUi, useUiController } from "@/lib/store";
import { FileDropOverlay, useFileIntake } from "./file-intake";
import { HomeFabs } from "./home-fabs";
import { useWide } from "./responsive";
import { ScrollRootContext } from "./shell-actions";
import { ShellDialogsProvider, useShellDialogs } from "./shell-dialogs";
import { SIDEBAR_OPEN_PX, SIDEBAR_RAIL_PX, SidebarContent } from "./sidebar";
import { pillState } from "./sync-rules";
import { TopBar } from "./top-bar";
import { ShortcutHelpHost } from "./shortcut-help";
import { useHomeShortcuts } from "./use-shortcuts";
import { OfflineBanner, ViewEmptyState, ViewHeader } from "./view-chrome";

export { useShellScrollRoot } from "./shell-actions";
export { openShortcutHelp, ShortcutHelpHost } from "./shortcut-help";

/**
 * The signed-in frame around the active view (`HomeScreen`'s scaffold): the
 * top bar, the docked sidebar on a wide window or a drawer on a phone, the
 * grid views' headers and empty states, the offline banner, the new-note
 * button and sync pill, window file drop and paste, and the keyboard
 * shortcuts.
 */
export function AppShell({ children }: { children: ReactNode }) {
  return (
    <ShellDialogsProvider>
      <ShellFrame>{children}</ShellFrame>
    </ShellDialogsProvider>
  );
}

/** Whether the shell frames a grid (headers, empty states) or hands a board or agenda the whole area. */
function useGridView(): boolean {
  const destination = useUi((s) => s.destination);
  const layout = useActiveLayout();
  return destination !== "reminders" && !(destination === "notes" && layout === "board");
}

function ShellFrame({ children }: { children: ReactNode }) {
  const wide = useWide();
  const ui = useUiController();
  const sidebarOpen = useUi((s) => s.sidebarOpen);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const scrollRoot = useRef<HTMLElement | null>(null);
  const grid = useGridView();
  const dragging = useFileIntake();
  useHomeShortcuts();

  const onMenu = (): void => {
    if (wide) {
      ui.toggleSidebar();
    } else {
      setDrawerOpen(true);
    }
  };

  return (
    <ScrollRootContext.Provider value={scrollRoot}>
      <div className="flex h-dvh flex-col overflow-hidden bg-canvas text-on-surface">
        <TopBar onMenu={onMenu} />
        <div className="flex min-h-0 flex-1">
          {wide ? (
            <aside
              aria-label="Sidebar"
              className="shrink-0 overflow-hidden border-r border-hairline bg-sidebar transition-[width] duration-240 ease-emphasized motion-reduce:transition-none"
              style={{ width: sidebarOpen ? SIDEBAR_OPEN_PX : SIDEBAR_RAIL_PX }}
            >
              <ScrollArea className="h-full" style={{ width: SIDEBAR_OPEN_PX }}>
                <div style={{ width: sidebarOpen ? SIDEBAR_OPEN_PX : SIDEBAR_RAIL_PX }} className="transition-[width] duration-240 ease-emphasized motion-reduce:transition-none">
                  <SidebarContent compact={!sidebarOpen} placement="docked" />
                </div>
              </ScrollArea>
            </aside>
          ) : null}
          <div className="relative min-w-0 flex-1">
            <main
              ref={scrollRoot}
              data-shell-scroll
              className={cn("h-full overflow-x-hidden pb-[env(safe-area-inset-bottom)]", grid ? "overflow-y-auto" : "flex flex-col overflow-y-hidden")}
            >
              <div className={cn("shrink-0", grid ? "px-4 lg:px-8" : "px-4")}>
                <OfflineBanner />
                {grid ? <ViewHeader /> : null}
              </div>
              {grid ? (
                <>
                  {children}
                  <ViewEmptyState />
                  {/* Clearance under the last card for the new-note button. */}
                  <div aria-hidden className={wide ? "h-20" : "h-28"} />
                </>
              ) : (
                <div className="min-h-0 flex-1">{children}</div>
              )}
            </main>
            <CornerControls wide={wide} />
          </div>
        </div>
        {wide ? null : (
          <Sheet open={drawerOpen} onOpenChange={setDrawerOpen}>
            <SheetContent side="left" showCloseButton={false} className="w-[288px] max-w-[85vw] gap-0 bg-sidebar p-0 pt-[env(safe-area-inset-top)]">
              <SheetTitle className="sr-only">Main menu</SheetTitle>
              <SheetDescription className="sr-only">Workspaces, collections, labels, smart views and the library</SheetDescription>
              <ScrollArea className="h-full">
                <SidebarContent compact={false} placement="drawer" onNavigate={() => setDrawerOpen(false)} />
              </ScrollArea>
            </SheetContent>
          </Sheet>
        )}
        <FileDropOverlay visible={dragging} />
        <ShortcutHelpHost />
      </div>
    </ScrollRootContext.Provider>
  );
}

/** The new-note button, and on a wide window the sync pill centred beside it. */
function CornerControls({ wide }: { wide: boolean }) {
  const collection = useActiveCollection();
  const status = useNotesSelector((s) => s.syncStatus);
  const pending = useNotesSelector((s) => s.pendingChanges);
  const dialogs = useShellDialogs();
  return (
    <div className="pointer-events-none absolute right-4 bottom-[calc(1rem+env(safe-area-inset-bottom))] z-10 flex items-end gap-3">
      {wide ? (
        <button
          type="button"
          onClick={() => dialogs.open({ type: "sync" })}
          className="pointer-events-auto mb-3.5 rounded-md outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50"
          aria-label="Sync status details"
        >
          <SyncPill state={pillState(status)} count={pending} />
        </button>
      ) : null}
      {collection !== null ? <HomeFabs /> : null}
    </div>
  );
}
