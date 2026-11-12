"use client";

import { lazy, Suspense, type ReactNode } from "react";
import { closeTo, useRoute, type Route } from "@/lib/router";
import { SessionProvider, useActiveLayout, useSettings, useUi } from "@/lib/store/hooks";
import type { Session } from "@/lib/store/session";
import { AppShell } from "@/features/shell";
import { NotesView } from "@/features/notes";
import { BoardView } from "@/features/board";
import { RemindersView } from "@/features/reminders";
import { NoteEditor } from "@/features/editor";
import { SessionLifecycle } from "./lifecycle";
import { ThemeSync } from "./theme-sync";

// Heavy, rarely opened screens load on demand.
const HistoryScreen = lazy(() => import("@/features/editor").then((m) => ({ default: m.HistoryScreen })));
const SettingsScreen = lazy(() => import("@/features/settings").then((m) => ({ default: m.SettingsScreen })));
const WorkspaceSettingsScreen = lazy(() => import("@/features/workspace").then((m) => ({ default: m.WorkspaceSettingsScreen })));
const WorkspaceStatsScreen = lazy(() => import("@/features/workspace").then((m) => ({ default: m.WorkspaceStatsScreen })));
const ChatScreen = lazy(() => import("@/features/chat").then((m) => ({ default: m.ChatScreen })));

/** The view the navigation state asks for: reminders, a board, or the grid. */
function ActiveView() {
  const destination = useUi((s) => s.destination);
  const layout = useActiveLayout();
  if (destination === "reminders") {
    return <RemindersView />;
  }
  if (destination === "notes" && layout === "board") {
    return <BoardView />;
  }
  return <NotesView />;
}

function Home({ overlay }: { overlay?: ReactNode }) {
  return (
    <>
      <AppShell>
        <ActiveView />
      </AppShell>
      {overlay}
    </>
  );
}

const closeOverlay = (): void => closeTo({ name: "home" });

function RouteOutlet({ route }: { route: Route }) {
  switch (route.name) {
    case "note":
      return <Home overlay={<NoteEditor key={route.noteId} noteId={route.noteId} onClose={closeOverlay} />} />;
    case "history":
      return (
        <Home
          overlay={
            <Suspense fallback={null}>
              <HistoryScreen noteId={route.noteId} onClose={() => closeTo({ name: "note", noteId: route.noteId })} />
            </Suspense>
          }
        />
      );
    case "settings":
      return (
        <Suspense fallback={null}>
          <SettingsScreen page={route.page ?? undefined} />
        </Suspense>
      );
    case "workspaceSettings":
      return (
        <Suspense fallback={null}>
          <WorkspaceSettingsScreen workspaceId={route.workspaceId} />
        </Suspense>
      );
    case "workspaceStats":
      return (
        <Suspense fallback={null}>
          <WorkspaceStatsScreen workspaceId={route.workspaceId} />
        </Suspense>
      );
    case "chat":
      return (
        <Suspense fallback={null}>
          <ChatScreen />
        </Suspense>
      );
    default:
      return <Home />;
  }
}

function SignedInTheme() {
  const mode = useSettings((s) => s.themeMode);
  const accent = useSettings((s) => s.accentColor);
  const font = useSettings((s) => s.font);
  return <ThemeSync accent={accent} mode={mode} font={font} />;
}

export function SignedInApp({ session }: { session: Session }) {
  const route = useRoute();
  return (
    <SessionProvider session={session}>
      <SignedInTheme />
      <SessionLifecycle session={session} />
      <RouteOutlet route={route} />
    </SessionProvider>
  );
}
