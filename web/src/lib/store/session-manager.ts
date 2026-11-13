import type { KeyValueStore } from "@/lib/state/local-cache";
import type { AuthState, AuthStore, SessionApi } from "./auth-store";
import { Session } from "./session";

// Keeps one Session for the signed-in user, outside React: created when a user
// signs in, replaced when the user or server changes, disposed on sign-out.
export class SessionManager {
  private current: Session | null = null;
  private baseUrl: string | null = null;
  private readonly listeners = new Set<() => void>();
  private readonly unsubscribe: () => void;

  constructor(
    private readonly auth: AuthStore,
    private readonly api: SessionApi,
    private readonly cache: KeyValueStore,
    private readonly notify?: (message: string) => void,
  ) {
    this.unsubscribe = auth.store.subscribe((state) => this.sync(state));
    this.sync(auth.state);
  }

  /** The signed-in user's session, or null. */
  get = (): Session | null => this.current;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  private sync(state: AuthState): void {
    const user = state.status === "signedIn" ? state.user : null;
    if (user && this.current && this.current.userId === user.id && this.baseUrl === this.api.baseUrl) {
      return;
    }
    if (!user && !this.current) {
      return;
    }
    this.current?.dispose();
    this.current = null;
    this.baseUrl = null;
    if (user) {
      this.baseUrl = this.api.baseUrl;
      this.current = new Session({
        api: this.api,
        userId: user.id,
        cache: this.cache,
        accountOrigin: state.accountOrigin,
        restoredSession: state.restoredSession,
        notify: this.notify,
      });
      this.current.start();
    }
    for (const listener of this.listeners) {
      listener();
    }
  }

  dispose(): void {
    this.unsubscribe();
    this.current?.dispose();
    this.current = null;
  }
}
