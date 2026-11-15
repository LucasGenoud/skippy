import { del, get, set } from "idb-keyval";
import type { JsonObject } from "@/lib/util/json";

// A tiny persistence seam for the offline cache, mirroring `LocalCache` in
// `state/local_cache.dart`. The app uses IndexedDB through idb-keyval; tests
// inject the in-memory store. Keys are opaque here.

export interface KeyValueStore {
  read(key: string): Promise<JsonObject | null>;
  write(key: string, doc: JsonObject): Promise<void>;
  clear(key: string): Promise<void>;
}

/** Stable cache identity for one account on one server. */
export function notesCacheKey(namespace: string, userId: string | null): string {
  const account = userId ?? "local";
  const trimmed = namespace.trim();
  if (!trimmed) {
    return account;
  }
  return `${encodeURIComponent(trimmed)}::${account}`;
}

/** Where the navigation record lives, beside the notes cache at [notesKey]. */
export function navigationCacheKey(notesKey: string): string {
  return `${notesKey}::navigation`;
}

const STORAGE_PREFIX = "notes_cache_";

/** IndexedDB-backed store. Skips rewriting a document identical to the last write. */
export class IdbKeyValueStore implements KeyValueStore {
  private readonly lastWrites = new Map<string, string>();

  async read(key: string): Promise<JsonObject | null> {
    try {
      const raw: unknown = await get(STORAGE_PREFIX + key);
      if (typeof raw !== "string") {
        return null;
      }
      const decoded: unknown = JSON.parse(raw);
      return decoded !== null && typeof decoded === "object" && !Array.isArray(decoded) ? (decoded as JsonObject) : null;
    } catch {
      // Corrupt or unavailable: behave as if empty.
      return null;
    }
  }

  async write(key: string, doc: JsonObject): Promise<void> {
    const json = JSON.stringify(doc);
    if (this.lastWrites.get(key) === json) {
      return;
    }
    this.lastWrites.delete(key);
    await set(STORAGE_PREFIX + key, json);
    this.lastWrites.set(key, json);
  }

  async clear(key: string): Promise<void> {
    this.lastWrites.delete(key);
    await del(STORAGE_PREFIX + key);
  }
}

/** In-memory store, for tests. Documents round-trip through JSON like the real one. */
export class MemoryKeyValueStore implements KeyValueStore {
  readonly docs = new Map<string, string>();

  async read(key: string): Promise<JsonObject | null> {
    const raw = this.docs.get(key);
    return raw === undefined ? null : (JSON.parse(raw) as JsonObject);
  }

  async write(key: string, doc: JsonObject): Promise<void> {
    this.docs.set(key, JSON.stringify(doc));
  }

  async clear(key: string): Promise<void> {
    this.docs.delete(key);
  }
}
