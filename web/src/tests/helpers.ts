import { vi } from "vitest";
import { MemoryKeyValueStore, type KeyValueStore } from "@/lib/state/local-cache";
import type { AccountOrigin } from "@/lib/state/starter-notes";
import { NotesStore } from "@/lib/store/notes-store";
import { UiController } from "@/lib/store/ui-store";
import type { FakeApi } from "./fake-api";

// Shared test scaffolding: a notes store wired to a fake API and an in-memory
// cache, plus helpers that run timers out.

/** Production waits 5s before calling an outage an outage; tests wait 20ms. */
export const TEST_OFFLINE_GRACE_MS = 20;

export interface TestStore {
  readonly store: NotesStore;
  readonly ui: UiController;
  readonly cache: KeyValueStore;
}

export function testStore(
  api: FakeApi,
  options: { cache?: KeyValueStore; cacheNamespace?: string; migrateLegacyCache?: boolean; accountOrigin?: AccountOrigin; onRemoteChange?: () => void; userId?: string } = {},
): TestStore {
  const ui = new UiController();
  const cache = options.cache ?? new MemoryKeyValueStore();
  const store = new NotesStore({
    api,
    ui,
    cache,
    currentUserId: options.userId ?? "u-me",
    cacheNamespace: options.cacheNamespace ?? "",
    migrateLegacyCache: options.migrateLegacyCache,
    accountOrigin: options.accountOrigin,
    onRemoteChange: options.onRemoteChange,
    offlineGraceMs: TEST_OFFLINE_GRACE_MS,
  });
  return { store, ui, cache };
}

/** Let debounce timers (400ms) and queue flushes run out, under fake timers. */
export async function settle(ms = 600): Promise<void> {
  await vi.advanceTimersByTimeAsync(ms);
}

/** Drain pending microtasks and zero-delay work. */
export async function flushMicrotasks(): Promise<void> {
  await vi.advanceTimersByTimeAsync(0);
}
