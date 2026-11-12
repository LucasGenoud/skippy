import { showAppSnack } from "@/components/common/snack";
import { resolveApiBase } from "@/lib/api/base-url";
import { HttpApi } from "@/lib/api/http-api";
import { IdbKeyValueStore } from "@/lib/state/local-cache";
import { AuthStore, browserPreferences } from "@/lib/store/auth-store";
import { SessionManager } from "@/lib/store/session-manager";

// The app's long-lived objects, created once on the client (never at module
// scope, never on the server): the API client, the auth store, the offline
// cache, and the manager of the signed-in user's stores.
export interface Runtime {
  readonly api: HttpApi;
  readonly auth: AuthStore;
  readonly sessions: SessionManager;
}

let runtime: Runtime | null = null;

export function getRuntime(): Runtime {
  if (runtime) {
    return runtime;
  }
  const api = new HttpApi({ baseUrl: resolveApiBase() });
  const cache = new IdbKeyValueStore();
  const auth = new AuthStore(api, browserPreferences(), cache);
  const sessions = new SessionManager(auth, api, cache, (message) => void showAppSnack(message));
  auth.loadSavedUrls();
  void auth.restore();
  runtime = { api, auth, sessions };
  return runtime;
}
