import type { Api } from "@/lib/api/client";
import type { KeyValueStore } from "@/lib/state/local-cache";
import type { AccountOrigin } from "@/lib/state/starter-notes";
import { LinkPreviewCache } from "./link-preview-cache";
import { NotesStore } from "./notes-store";
import { semanticSearchAvailable, SettingsStore } from "./settings-store";
import { effectiveQueryOf } from "./selectors";
import { UiController } from "./ui-store";

// The stores of one signed-in user on one server, created together and torn
// down together (sign-out, user or server change). Mirrors `_onAuthChanged`
// in `main.dart`.

export interface SessionOptions {
  readonly api: Api;
  readonly userId: string;
  readonly cache: KeyValueStore;
  readonly accountOrigin: AccountOrigin;
  readonly restoredSession: boolean;
  /** Shown when semantic search turns out to be disabled. */
  readonly notify?: (message: string) => void;
  readonly offlineGraceMs?: number;
}

export class Session {
  readonly api: Api;
  readonly userId: string;
  readonly ui: UiController;
  readonly settings: SettingsStore;
  readonly notes: NotesStore;
  /** Link previews can include metadata from private URLs: one cache per session. */
  readonly linkPreviews: LinkPreviewCache;
  private started = false;

  constructor(options: SessionOptions) {
    this.api = options.api;
    this.userId = options.userId;
    this.ui = new UiController();
    this.settings = new SettingsStore(options.api);
    this.linkPreviews = new LinkPreviewCache(options.api);
    this.notes = new NotesStore({
      api: options.api,
      ui: this.ui,
      cache: options.cache,
      currentUserId: options.userId,
      cacheNamespace: options.api.baseUrl,
      migrateLegacyCache: options.restoredSession,
      accountOrigin: options.accountOrigin,
      // Settings changes on other devices arrive on the same socket.
      onRemoteChange: () => void this.settings.load(),
      offlineGraceMs: options.offlineGraceMs,
    });
    this.ui.connect({
      semanticSearch: async (query) => (await this.notes.semanticSearch(query)).map((n) => n.id),
      semanticWanted: () => semanticSearchAvailable(this.settings.state) && this.settings.state.semanticRanking,
      rememberDestination: (destination) => this.notes.rememberWorkspaceView(destination),
      effectiveQuery: () => effectiveQueryOf(this.notes.state, this.ui.state),
      notify: options.notify,
    });
  }

  /** Load settings and notes, and start live sync. Idempotent. */
  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    void this.settings.load();
    void this.notes.load();
    this.notes.startSync();
  }

  /** Flip the semantic ranking toggle and re-rank. */
  toggleSemanticRanking(): void {
    this.settings.setSemanticRanking(!this.settings.state.semanticRanking);
    this.ui.scheduleSemantic();
  }

  /** The tab is visible again: re-pull both halves of the account. */
  async resume(): Promise<void> {
    await Promise.all([this.notes.onResumed(), this.settings.load()]);
  }

  dispose(): void {
    this.notes.dispose();
    this.settings.dispose();
    this.ui.dispose();
  }
}
