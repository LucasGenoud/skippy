import { createStore, type StoreApi } from "zustand/vanilla";
import type { Api, AccountUpdate, AuthResult } from "@/lib/api/client";
import { ApiError, NetworkError } from "@/lib/api/errors";
import { ACTIVE_URL_KEY, defaultApiBase, normalizeBaseUrl, SAVED_URLS_KEY } from "@/lib/api/base-url";
import { authUserToJson, parseAuthUser, type AuthUser } from "@/lib/models/note";
import { navigationCacheKey, notesCacheKey, type KeyValueStore } from "@/lib/state/local-cache";
import type { AccountOrigin } from "@/lib/state/starter-notes";
import { describeConnectionFailure } from "@/lib/util/network-error";

// Session restoration, sign-in/up/out, the saved server list, and account
// changes. Ported from `state/auth_store.dart`. A previously signed-in user
// enters from the cached profile at once; the token is verified off the
// critical path, and only an outright rejection signs them out.

export type AuthStatus = "restoring" | "signedOut" | "signedIn";

export interface AuthState {
  readonly status: AuthStatus;
  readonly user: AuthUser | null;
  /** An auth request is in flight. */
  readonly busy: boolean;
  /** The last auth failure, in words for the login form. */
  readonly error: string | null;
  /** HTTP status of that failure (401 both fields, 409 email taken), else null. */
  readonly errorStatus: number | null;
  /** The session came from this browser's saved token. */
  readonly restoredSession: boolean;
  /** Set by registration, so the new account gets its starter notes. */
  readonly accountOrigin: AccountOrigin;
  /** Every server the user has saved. */
  readonly savedUrls: readonly string[];
  /** The server in use. */
  readonly activeUrl: string;
  /** An address to prefill on the sign-in form (after a password reset). */
  readonly prefillEmail: string | null;
}

/** What the auth store needs beyond [Api]: a mutable session on the client. */
export interface SessionApi extends Api {
  baseUrl: string;
  token: string | null;
  onUnauthorized: (() => void) | null;
}

/** Synchronous key/value storage (localStorage in the app, a map in tests). */
export interface PreferenceStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

const TOKEN_KEY = "sticky_notes_token";
const USER_KEY = "sticky_notes_user";
const HTTP_UNAUTHORIZED = 401;
const HTTP_FORBIDDEN = 403;
const HTTP_CONFLICT = 409;

/** localStorage, tolerating a browser that refuses it. */
export function browserPreferences(): PreferenceStorage {
  const memory = new Map<string, string>();
  const storage = (): Storage | null => {
    try {
      return window.localStorage;
    } catch {
      return null;
    }
  };
  return {
    getItem: (key) => {
      try {
        return storage()?.getItem(key) ?? memory.get(key) ?? null;
      } catch {
        return memory.get(key) ?? null;
      }
    },
    setItem: (key, value) => {
      memory.set(key, value);
      try {
        storage()?.setItem(key, value);
      } catch {
        // Kept in memory for this session.
      }
    },
    removeItem: (key) => {
      memory.delete(key);
      try {
        storage()?.removeItem(key);
      } catch {
        // Nothing to clean up.
      }
    },
  };
}

/** Whether the server actively refused the session (as opposed to not answering). */
const isRejection = (e: ApiError): boolean => e.statusCode === HTTP_UNAUTHORIZED || e.statusCode === HTTP_FORBIDDEN;

export class AuthStore {
  readonly store: StoreApi<AuthState>;
  /** Invalidates authentication work superseded by another attempt or a server switch. */
  private generation = 0;

  constructor(
    readonly api: SessionApi,
    private readonly prefs: PreferenceStorage,
    /** The offline notes cache, cleared when the account is deleted. */
    private readonly notesCache?: KeyValueStore,
  ) {
    this.store = createStore<AuthState>(() => ({
      status: "restoring",
      user: null,
      busy: false,
      error: null,
      errorStatus: null,
      restoredSession: false,
      accountOrigin: "existing",
      savedUrls: [],
      activeUrl: api.baseUrl,
      prefillEmail: null,
    }));
    api.onUnauthorized = () => this.onSessionRejected();
  }

  get state(): AuthState {
    return this.store.getState();
  }

  private set(partial: Partial<AuthState>): void {
    this.store.setState(partial);
  }

  // -- server list ------------------------------------------------------------

  private readSavedUrls(): string[] {
    try {
      const raw: unknown = JSON.parse(this.prefs.getItem(SAVED_URLS_KEY) ?? "[]");
      return Array.isArray(raw) ? raw.filter((u): u is string => typeof u === "string") : [];
    } catch {
      return [];
    }
  }

  private writeSavedUrls(urls: readonly string[]): void {
    this.prefs.setItem(SAVED_URLS_KEY, JSON.stringify(urls));
  }

  /** Load saved servers (call before [restore]); the active one is always listed. */
  loadSavedUrls(): void {
    const savedUrls = this.readSavedUrls();
    const active = this.prefs.getItem(ACTIVE_URL_KEY);
    if (active && active.trim()) {
      this.api.baseUrl = normalizeBaseUrl(active);
    }
    if (!savedUrls.includes(this.api.baseUrl)) {
      savedUrls.unshift(this.api.baseUrl);
      this.writeSavedUrls(savedUrls);
    }
    this.set({ savedUrls, activeUrl: this.api.baseUrl });
  }

  /** Switch to another saved server, signing out of this one. */
  setActiveUrl(url: string): void {
    if (url === this.api.baseUrl) {
      return;
    }
    this.clearSession();
    this.api.baseUrl = url;
    this.prefs.setItem(ACTIVE_URL_KEY, url);
    this.set({ activeUrl: url });
  }

  /** Add a server and switch to it. */
  addUrl(url: string): void {
    const normalized = normalizeBaseUrl(url);
    if (!normalized) {
      return;
    }
    const savedUrls = [...this.state.savedUrls];
    if (!savedUrls.includes(normalized)) {
      savedUrls.push(normalized);
      this.writeSavedUrls(savedUrls);
      this.set({ savedUrls });
    }
    this.setActiveUrl(normalized);
  }

  /** Edit a saved server in place; editing the active one reconnects. */
  editUrl(oldUrl: string, newUrl: string): void {
    const normalized = normalizeBaseUrl(newUrl);
    const savedUrls = [...this.state.savedUrls];
    const index = savedUrls.indexOf(oldUrl);
    if (!normalized || normalized === oldUrl || savedUrls.includes(normalized) || index === -1) {
      return;
    }
    savedUrls[index] = normalized;
    this.writeSavedUrls(savedUrls);
    if (oldUrl === this.api.baseUrl) {
      this.clearSession();
      this.api.baseUrl = normalized;
      this.prefs.setItem(ACTIVE_URL_KEY, normalized);
    }
    this.set({ savedUrls, activeUrl: this.api.baseUrl });
  }

  /** Remove a saved server (never the active one, never the last). */
  removeUrl(url: string): void {
    if (url === this.api.baseUrl || this.state.savedUrls.length <= 1) {
      return;
    }
    const savedUrls = this.state.savedUrls.filter((u) => u !== url);
    this.writeSavedUrls(savedUrls);
    this.set({ savedUrls });
  }

  /** The server this page would use before any saved choice. */
  defaultUrl(): string {
    return defaultApiBase();
  }

  // -- session ----------------------------------------------------------------

  private cachedUser(): AuthUser | null {
    const raw = this.prefs.getItem(USER_KEY);
    if (raw === null) {
      return null;
    }
    try {
      const user = parseAuthUser(JSON.parse(raw));
      return user.id ? user : null;
    } catch {
      return null;
    }
  }

  /** Restore the saved session; never a hard dependency on connectivity. */
  async restore(): Promise<void> {
    const saved = this.prefs.getItem(TOKEN_KEY);
    if (saved === null) {
      this.set({ restoredSession: false, status: "signedOut" });
      return;
    }
    this.api.token = saved;
    const cached = this.cachedUser();
    if (cached) {
      // Open from the cached profile at once; verify off the critical path.
      this.set({ restoredSession: true, accountOrigin: "existing", user: cached, status: "signedIn" });
      void this.verifySession();
      return;
    }
    // No cached profile: the server has to say whose token this is first.
    this.set({ restoredSession: true, accountOrigin: "existing" });
    try {
      const user = await this.api.me();
      this.prefs.setItem(USER_KEY, JSON.stringify(authUserToJson(user)));
      this.set({ user, status: "signedIn" });
    } catch (e) {
      this.api.token = null;
      if (e instanceof ApiError && isRejection(e)) {
        this.prefs.removeItem(TOKEN_KEY);
        this.prefs.removeItem(USER_KEY);
        this.set({ status: "signedOut" });
        return;
      }
      // Keep the token for a later launch, but do not invent a null-user session.
      const error =
        e instanceof ApiError
          ? `Can't restore the saved session: ${e.serverMessage}`
          : `Can't restore the saved session. ${e instanceof NetworkError ? e.message : describeConnectionFailure(e, this.api.baseUrl)}`;
      this.set({ status: "signedOut", error });
    }
  }

  /** Confirm a restored token; only a rejection signs out. */
  private async verifySession(): Promise<void> {
    const token = this.api.token;
    const baseUrl = this.api.baseUrl;
    if (token === null) {
      return;
    }
    try {
      const fresh = await this.api.me();
      if (this.api.token !== token || this.api.baseUrl !== baseUrl) {
        return;
      }
      this.prefs.setItem(USER_KEY, JSON.stringify(authUserToJson(fresh)));
      this.set({ user: fresh });
    } catch (e) {
      if (e instanceof ApiError && isRejection(e) && this.api.token === token && this.api.baseUrl === baseUrl) {
        this.clearSession();
      }
      // Offline: keep the session exactly as it is.
    }
  }

  private async authenticate(call: () => Promise<AuthResult>, origin: AccountOrigin): Promise<boolean> {
    const generation = ++this.generation;
    const baseUrl = this.api.baseUrl;
    const isCurrent = (): boolean => generation === this.generation && this.api.baseUrl === baseUrl;
    this.set({ busy: true, error: null, errorStatus: null });
    try {
      const result = await call();
      if (!isCurrent()) {
        return false;
      }
      this.prefs.setItem(TOKEN_KEY, result.token);
      this.prefs.setItem(USER_KEY, JSON.stringify(authUserToJson(result.user)));
      this.api.token = result.token;
      this.set({ restoredSession: false, accountOrigin: origin, user: result.user, status: "signedIn" });
      return true;
    } catch (e) {
      if (!isCurrent()) {
        return false;
      }
      if (e instanceof ApiError) {
        const error =
          e.statusCode === HTTP_UNAUTHORIZED
            ? "Wrong email or password"
            : e.statusCode === HTTP_CONFLICT
              ? "That email is already registered"
              : e.serverMessage;
        this.set({ errorStatus: e.statusCode, error });
      } else {
        this.set({ error: e instanceof NetworkError ? e.message : describeConnectionFailure(e, baseUrl) });
      }
      return false;
    } finally {
      if (generation === this.generation) {
        this.set({ busy: false });
      }
    }
  }

  /** Prefill the sign-in form, e.g. with the address a reset link was sent to. */
  setPrefillEmail(email: string | null): void {
    this.set({ prefillEmail: email });
  }

  /** Clear a stale error (switching between sign-in and create-account). */
  clearError(): void {
    if (this.state.error !== null) {
      this.set({ error: null, errorStatus: null });
    }
  }

  signIn(email: string, password: string): Promise<boolean> {
    return this.authenticate(() => this.api.login(email, password), "existing");
  }

  registerAccount(name: string, email: string, password: string): Promise<boolean> {
    return this.authenticate(() => this.api.register(name, email, password), "justCreated");
  }

  /** Ask for a reset link; resolves whether or not the address has an account. */
  requestPasswordReset(email: string): Promise<void> {
    return this.api.requestPasswordReset(email);
  }

  /** Redeem a reset link; resolves to the address, for prefilling sign-in. */
  resetPassword(token: string, password: string): Promise<string> {
    return this.api.resetPassword(token, password);
  }

  /** Rejects with ApiError on refusal (wrong current password, email taken). */
  async updateAccount(update: AccountUpdate): Promise<void> {
    const user = await this.api.updateAccount(update);
    this.prefs.setItem(USER_KEY, JSON.stringify(authUserToJson(user)));
    this.set({ user });
  }

  /**
   * Delete the server account, then this browser's session and offline cache.
   * [beforeSignOut] lets the app close authenticated screens first.
   */
  async deleteAccount(currentPassword: string, beforeSignOut?: () => void): Promise<void> {
    const userId = this.state.user?.id ?? null;
    const cacheKey = notesCacheKey(this.api.baseUrl, userId);
    await this.api.deleteAccount(currentPassword);
    beforeSignOut?.();
    this.clearSession();
    // Let the app dispose its notes store first, so no queued write recreates the cache.
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
    try {
      await this.notesCache?.clear(cacheKey);
      await this.notesCache?.clear(navigationCacheKey(cacheKey));
    } catch {
      // The server deletion already succeeded.
    }
  }

  /** Signing out is local; the server is told afterwards, best effort. */
  signOut(): void {
    void this.api.logout().catch(() => undefined);
    this.clearSession();
  }

  private onSessionRejected(): void {
    if (this.state.status === "signedIn") {
      this.clearSession();
    }
  }

  private clearSession(): void {
    this.generation++;
    this.api.token = null;
    this.prefs.removeItem(TOKEN_KEY);
    this.prefs.removeItem(USER_KEY);
    this.set({ busy: false, restoredSession: false, user: null, status: "signedOut" });
  }
}
