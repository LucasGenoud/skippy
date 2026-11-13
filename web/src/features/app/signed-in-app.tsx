"use client";

import { lazy, Suspense, useEffect, useRef, type FocusEvent } from "react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { closeTo, useRoute, type Route } from "@/lib/router";
import { SessionProvider, useActiveLayout, useSettings, useUi } from "@/lib/store/hooks";
import type { Session } from "@/lib/store/session";
import { viewSwapVariants } from "@/lib/theme/motion";
import { FrozenOnExit } from "./frozen-on-exit";
import { AppShell, ShortcutHelpHost } from "@/features/shell";
import { NotesView } from "@/features/notes";
import { BoardView } from "@/features/board";
import { RemindersView } from "@/features/reminders";
import { NoteEditor } from "@/features/editor";
import { SessionLifecycle } from "./lifecycle";
import { OverlayOutlet, type OverlayEntry } from "./overlay-outlet";
import { PageOutlet, useCovered, type PageEntry } from "./page-outlet";
import { ThemeSync } from "./theme-sync";

// Heavy, rarely opened screens load on demand.
const loadEditor = () => import("@/features/editor");
const loadSettings = () => import("@/features/settings");
const loadWorkspace = () => import("@/features/workspace");
const loadChat = () => import("@/features/chat");
const HistoryScreen = lazy(() => loadEditor().then((m) => ({ default: m.HistoryScreen })));
const SettingsScreen = lazy(() => loadSettings().then((m) => ({ default: m.SettingsScreen })));
const WorkspaceSettingsScreen = lazy(() => loadWorkspace().then((m) => ({ default: m.WorkspaceSettingsScreen })));
const WorkspaceStatsScreen = lazy(() => loadWorkspace().then((m) => ({ default: m.WorkspaceStatsScreen })));
const ChatScreen = lazy(() => loadChat().then((m) => ({ default: m.ChatScreen })));

/** After the home view has settled, fetch the lazy pages so opening one never waits on the network. */
const PRELOAD_DELAY_MS = 2000;

function usePreloadPages(): void {
  useEffect(() => {
    const timer = window.setTimeout(() => {
      void loadSettings();
      void loadWorkspace();
      void loadChat();
    }, PRELOAD_DELAY_MS);
    return () => window.clearTimeout(timer);
  }, []);
}

type ViewKind = "reminders" | "board" | "grid";

/** The view the navigation state asks for: reminders, a board, or the grid. */
function useViewKind(): ViewKind {
  const destination = useUi((s) => s.destination);
  const layout = useActiveLayout();
  if (destination === "reminders") {
    return "reminders";
  }
  if (destination === "notes" && layout === "board") {
    return "board";
  }
  return "grid";
}

/**
 * The active view. Switching between the grid, a board and the agenda slides
 * the new one up into place as the old one sinks away (the grid's own view
 * changes do the same inside it); the first view of the session just appears.
 */
function ActiveView() {
  const kind = useViewKind();
  const swap = viewSwapVariants(useReducedMotion());
  const body = kind === "reminders" ? <RemindersView /> : kind === "board" ? <BoardView /> : <NotesView />;
  return (
    <div className={kind === "grid" ? "relative" : "relative h-full"}>
      <AnimatePresence initial={false} mode="popLayout">
        <motion.div
          key={kind}
          className={kind === "grid" ? undefined : "h-full"}
          variants={swap}
          initial="enter"
          animate="shown"
          exit="leave"
        >
          <FrozenOnExit className={kind === "grid" ? undefined : "h-full"}>{body}</FrozenOnExit>
        </motion.div>
      </AnimatePresence>
    </div>
  );
}

const closeOverlay = (): void => closeTo({ name: "home" });

/** The overlay drawn over the home view for [route], if any. */
function overlayFor(route: Route): OverlayEntry | null {
  switch (route.name) {
    case "note":
      return { key: `note:${route.noteId}`, node: <NoteEditor noteId={route.noteId} onClose={closeOverlay} /> };
    case "history": {
      const noteId = route.noteId;
      return {
        key: `history:${noteId}`,
        node: (
          <Suspense fallback={null}>
            <HistoryScreen noteId={noteId} onClose={() => closeTo({ name: "note", noteId })} />
          </Suspense>
        ),
      };
    }
    default:
      return null;
  }
}

/** The full page pushed over the home view for [route], if any. */
function pageFor(route: Route): PageEntry | null {
  switch (route.name) {
    case "settings":
      // One page for the whole of settings: its own pages switch inside it.
      return { key: "settings", node: <SettingsScreen page={route.page ?? undefined} /> };
    case "workspaceSettings":
      return { key: `workspaceSettings:${route.workspaceId}`, node: <WorkspaceSettingsScreen workspaceId={route.workspaceId} /> };
    case "workspaceStats":
      return { key: `workspaceStats:${route.workspaceId}`, node: <WorkspaceStatsScreen workspaceId={route.workspaceId} /> };
    case "chat":
      return { key: "chat", node: <ChatScreen /> };
    default:
      return null;
  }
}

/**
 * Every signed-in route. The home view is always mounted, as Flutter keeps
 * the home route under everything pushed over it; a page covers it, and once
 * the page has fully arrived the home view is hidden from paint, focus and
 * assistive technology until the page starts to leave.
 */
function RouteOutlet({ route }: { route: Route }) {
  const page = pageFor(route);
  const pageOpen = page !== null;
  const [covered, setCovered] = useCovered(pageOpen);
  const rememberFocus = useHomeFocusReturn(pageOpen);
  return (
    <>
      <div
        inert={pageOpen || undefined}
        style={covered ? { visibility: "hidden" } : undefined}
        onFocus={rememberFocus}
      >
        <AppShell>
          <ActiveView />
        </AppShell>
      </div>
      <OverlayOutlet entry={overlayFor(route)} />
      <PageOutlet entry={page} onCovered={setCovered} />
    </>
  );
}

/**
 * Remembers what had focus in the home view and gives it back once a page
 * closes (the Settings button, a workspace menu row's trigger), so a
 * keyboard user lands where they left rather than at the top of the page.
 */
function useHomeFocusReturn(pageOpen: boolean): (event: FocusEvent) => void {
  const lastFocus = useRef<HTMLElement | null>(null);
  useEffect(() => {
    if (pageOpen) {
      return;
    }
    const target = lastFocus.current;
    const active = document.activeElement;
    if (target?.isConnected && (active === null || active === document.body)) {
      target.focus({ preventScroll: true });
    }
  }, [pageOpen]);
  return (event) => {
    lastFocus.current = event.target instanceof HTMLElement ? event.target : null;
  };
}

function SignedInTheme() {
  const mode = useSettings((s) => s.themeMode);
  const accent = useSettings((s) => s.accentColor);
  const font = useSettings((s) => s.font);
  return <ThemeSync accent={accent} mode={mode} font={font} />;
}

export function SignedInApp({ session }: { session: Session }) {
  const route = useRoute();
  usePreloadPages();
  return (
    <SessionProvider session={session}>
      <SignedInTheme />
      <SessionLifecycle session={session} />
      <RouteOutlet route={route} />
      {/* Once for every route: Settings > About opens it too. */}
      <ShortcutHelpHost />
    </SessionProvider>
  );
}
