"use client"

import { Check, CircleAlert, CloudOff, LoaderCircle, type LucideIcon } from "lucide-react"
import { cn } from "cn"

import { CrossFade } from "./reveal"
import { RollingCount } from "./rolling-count"

export type SyncState = "synced" | "syncing" | "connecting" | "offline" | "error"

const DESCRIBE: Record<SyncState, { label: string; icon: LucideIcon | null }> = {
  synced: { label: "Synced", icon: Check },
  syncing: { label: "Saving", icon: null },
  connecting: { label: "Connecting", icon: null },
  offline: { label: "Offline", icon: CloudOff },
  error: { label: "Not synced", icon: CircleAlert },
}

/**
 * A small floating surface that says whether every edit has reached the
 * server. `count` is the number of writes still queued, shown beside the
 * label while saving or failed. Spinner while work is in flight.
 */
export function SyncPill({ state, count = 0, className }: { state: SyncState; count?: number; className?: string }) {
  const { label, icon: Icon } = DESCRIBE[state]
  const failed = state === "error"
  const showCount = count > 0 && (state === "syncing" || failed || state === "offline")
  return (
    <div
      role="status"
      aria-live="polite"
      aria-label={`Sync status: ${label}`}
      className={cn(
        "inline-flex h-7 items-center rounded-md border bg-surface px-2.5 text-xs font-medium shadow-card transition-colors duration-150 ease-standard",
        failed ? "border-error text-error" : "border-outline-variant text-on-surface-variant",
        className,
      )}
    >
      <CrossFade stateKey={state} className="items-center">
        <span className="inline-flex items-center gap-1.5" aria-hidden>
          {Icon ? <Icon className="size-3.5" strokeWidth={2.25} /> : <LoaderCircle className="size-3 animate-spin" />}
          {label}
          {showCount ? <RollingCount count={count} className="text-on-surface-variant/80" /> : null}
        </span>
      </CrossFade>
    </div>
  )
}
