// Where the API lives. Resolution order follows the Flutter client: the server
// the user picked on the login screen (persisted), then the URL the Rust
// server injected into the page (`PUBLIC_URL`), then the page's own origin.

declare global {
  interface Window {
    stickyNotesApiBase?: string;
  }
}

export const ACTIVE_URL_KEY = "sticky_notes_active_url";
export const SAVED_URLS_KEY = "sticky_notes_backend_urls";

/** The URL the server stamped into the page, or null when unset. */
export function injectedApiBase(): string | null {
  if (typeof window === "undefined") {
    return null;
  }
  const value = window.stickyNotesApiBase;
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

/** The origin that served this page. */
export function pageOrigin(): string {
  return typeof window === "undefined" ? "" : window.location.origin;
}

/** The default before any saved choice: injected, else same origin. */
export function defaultApiBase(): string {
  return normalizeBaseUrl(injectedApiBase() ?? pageOrigin());
}

/** Trailing slashes and whitespace removed. */
export function normalizeBaseUrl(url: string): string {
  return url.trim().replace(/\/+$/, "");
}

/** The persisted active server, or the default. Reads localStorage; call from the client. */
export function resolveApiBase(): string {
  try {
    const saved = window.localStorage.getItem(ACTIVE_URL_KEY);
    if (saved && saved.trim()) {
      return normalizeBaseUrl(saved);
    }
  } catch {
    // Storage blocked: fall through to the default.
  }
  return defaultApiBase();
}
