import type { SyncStatus } from "@/lib/store";

// The sync indicator's words (`SyncPill._describe`, the avatar menu, the sync
// sheet), decided in one place.

export type PillState = "synced" | "syncing" | "connecting" | "offline" | "error";

/** The design system's pill state for the store's status. */
export function pillState(status: SyncStatus): PillState {
  return status === "failed" ? "error" : status;
}

export interface SyncFacts {
  readonly status: SyncStatus;
  readonly pending: number;
  readonly issues: number;
  readonly cacheFailure: boolean;
}

export function issuesLabel(count: number): string {
  return count === 1 ? "1 change needs attention" : `${count} changes need attention`;
}

/** The sheet's headline. */
export function syncSummary(facts: SyncFacts): { text: string; tone: "normal" | "error" } {
  if (facts.issues > 0) {
    return { text: issuesLabel(facts.issues), tone: "error" };
  }
  if (facts.cacheFailure) {
    return { text: "Offline copy was not saved", tone: "error" };
  }
  if (facts.status === "offline") {
    return { text: "Offline. Changes will sync when you reconnect.", tone: "normal" };
  }
  if (facts.pending === 0) {
    return { text: "All changes saved", tone: "normal" };
  }
  return { text: facts.pending === 1 ? "1 pending change" : `${facts.pending} pending changes`, tone: "normal" };
}

/** The avatar menu's sync row. */
export function syncMenuLabel(facts: SyncFacts): string {
  if (facts.cacheFailure) {
    return "Offline storage needs attention";
  }
  if (facts.issues > 0) {
    return issuesLabel(facts.issues);
  }
  return `Sync status: ${STATUS_WORDS[facts.status]}`;
}

const STATUS_WORDS: Record<SyncStatus, string> = {
  synced: "synced",
  syncing: "saving",
  connecting: "connecting",
  offline: "offline",
  failed: "not synced",
};
