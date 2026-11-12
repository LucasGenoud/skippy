"use client";

import { useSyncExternalStore } from "react";
import { passwordResetToken, publicShareToken } from "@/lib/util/public-route";

// A tiny client router over `window.history`. The static export serves one
// `index.html` for every path, so routes are parsed here, not by Next. A
// deployment under a sub-path (`/notes/n/<id>`) is tolerated: the base is
// whatever precedes the first recognised segment, and it is kept on navigate.

/** The settings pages, as `SettingsPage` in `widgets/settings/settings_pages.dart`. */
export const SETTINGS_PAGES = [
  { id: "account", title: "Account" },
  { id: "appearance", title: "Appearance" },
  { id: "reminders", title: "Reminders" },
  { id: "ai", title: "AI & search" },
  { id: "sharing", title: "Sharing & access" },
  { id: "data", title: "Backup & import" },
  { id: "about", title: "About" },
] as const;
export type SettingsPageId = (typeof SETTINGS_PAGES)[number]["id"];

export type Route =
  | { readonly name: "home" }
  | { readonly name: "note"; readonly noteId: string }
  | { readonly name: "history"; readonly noteId: string }
  | { readonly name: "settings"; readonly page: SettingsPageId | null }
  | { readonly name: "workspaceSettings"; readonly workspaceId: string }
  | { readonly name: "workspaceStats"; readonly workspaceId: string }
  | { readonly name: "chat" }
  | { readonly name: "publicShare"; readonly token: string }
  | { readonly name: "resetPassword"; readonly token: string };

/** Paths the app itself answers, to find the deployment's base path. */
const ROUTE_SEGMENTS = new Set(["n", "settings", "workspaces", "chat", "s", "reset"]);

/** Split [pathname] into the deployment base and the app path. */
function splitBase(pathname: string): { base: string; segments: string[] } {
  const parts = pathname.split("/").filter((p) => p !== "");
  const at = parts.findIndex((p) => ROUTE_SEGMENTS.has(p));
  if (at < 0) {
    // `/` or `/sub/path/` with no app segment: everything is base.
    const base = parts.length === 0 ? "" : `/${parts.join("/")}`;
    return { base: base === "/index.html" ? "" : base.replace(/\/index\.html$/, ""), segments: [] };
  }
  return { base: at === 0 ? "" : `/${parts.slice(0, at).join("/")}`, segments: parts.slice(at) };
}

const decode = (s: string): string => {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
};

/** The route a path names. Unknown paths are home. */
export function parseRoute(pathname: string): Route {
  const share = publicShareToken(pathname);
  if (share) {
    return { name: "publicShare", token: share };
  }
  const reset = passwordResetToken(pathname);
  if (reset) {
    return { name: "resetPassword", token: reset };
  }
  const [first, second, third] = splitBase(pathname).segments.map(decode);
  switch (first) {
    case "n":
      if (!second) {
        return { name: "home" };
      }
      return third === "history" ? { name: "history", noteId: second } : { name: "note", noteId: second };
    case "settings":
      return { name: "settings", page: SETTINGS_PAGES.find((p) => p.id === second)?.id ?? null };
    case "workspaces":
      if (second && third === "settings") {
        return { name: "workspaceSettings", workspaceId: second };
      }
      if (second && third === "stats") {
        return { name: "workspaceStats", workspaceId: second };
      }
      return { name: "home" };
    case "chat":
      return { name: "chat" };
    default:
      return { name: "home" };
  }
}

/** The path for [route] (without the deployment base). */
export function routePath(route: Route): string {
  switch (route.name) {
    case "home":
      return "/";
    case "note":
      return `/n/${encodeURIComponent(route.noteId)}`;
    case "history":
      return `/n/${encodeURIComponent(route.noteId)}/history`;
    case "settings":
      return route.page ? `/settings/${route.page}` : "/settings";
    case "workspaceSettings":
      return `/workspaces/${encodeURIComponent(route.workspaceId)}/settings`;
    case "workspaceStats":
      return `/workspaces/${encodeURIComponent(route.workspaceId)}/stats`;
    case "chat":
      return "/chat";
    case "publicShare":
      return `/s/${route.token}`;
    case "resetPassword":
      return `/reset/${route.token}`;
  }
}

// -- live location ----------------------------------------------------------------

/** Marks history entries this app pushed, so closing can go back to them. */
const PUSHED = { skippy: true } as const;

const listeners = new Set<() => void>();
let popstateAttached = false;
let cachedPath: string | null = null;
let cachedRoute: Route = { name: "home" };

function emit(): void {
  for (const listener of listeners) {
    listener();
  }
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  if (!popstateAttached && typeof window !== "undefined") {
    popstateAttached = true;
    window.addEventListener("popstate", emit);
  }
  return () => {
    listeners.delete(listener);
  };
}

function currentRoute(): Route {
  const path = typeof window === "undefined" ? "/" : window.location.pathname;
  if (path !== cachedPath) {
    cachedPath = path;
    cachedRoute = parseRoute(path);
  }
  return cachedRoute;
}

const SERVER_ROUTE: Route = { name: "home" };

/** The current route; re-renders on navigate, back and forward. */
export function useRoute(): Route {
  return useSyncExternalStore(subscribe, currentRoute, () => SERVER_ROUTE);
}

/** Read the current route outside React. */
export function getRoute(): Route {
  return currentRoute();
}

/** Navigate to an app path (`/n/<id>`) or a route; `replace` swaps the entry. */
export function navigate(to: string | Route, options: { replace?: boolean } = {}): void {
  if (typeof window === "undefined") {
    return;
  }
  const path = typeof to === "string" ? to : routePath(to);
  const { base } = splitBase(window.location.pathname);
  const target = `${base}${path.startsWith("/") ? path : `/${path}`}` || "/";
  if (target === window.location.pathname) {
    return;
  }
  if (options.replace) {
    window.history.replaceState(window.history.state, "", target);
  } else {
    window.history.pushState(PUSHED, "", target);
  }
  emit();
}

/** Go back one entry (closing an open note opened by navigate). */
export function back(): void {
  if (typeof window !== "undefined") {
    window.history.back();
  }
}

/**
 * Close an overlay route: back when the app pushed it, else replace with home
 * (a note opened straight from a link has nothing behind it to go back to).
 */
export function closeTo(route: Route = { name: "home" }): void {
  if (typeof window === "undefined") {
    return;
  }
  const state: unknown = window.history.state;
  if (state !== null && typeof state === "object" && (state as { skippy?: unknown }).skippy === true) {
    back();
    return;
  }
  navigate(route, { replace: true });
}
