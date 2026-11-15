"use client"

import { createContext, useContext, useLayoutEffect, useMemo, type ReactNode } from "react"

// Lets a routed overlay (the note editor, its history) play its exit after
// the route has already moved on, e.g. when the browser's back button closes
// it. The route outlet keeps the overlay mounted with `present: false` until
// the overlay calls `safeToRemove()`.
//
//   route /n/42 --back--> route /
//   outlet: <NoteEditor present>   -> <NoteEditor present=false> -> (removed)
//   editor:                           plays its close, then safeToRemove()
//
// An overlay opts in by calling `useOverlayPresence()`. One that never calls
// it is removed as soon as its route goes, as before.

export interface OverlayPresence {
  /** False once the route has left this overlay: play the exit now. */
  readonly present: boolean
  /**
   * Call once the exit has finished (or at once, when the overlay already
   * played its exit before asking the route to close it). Ignored while
   * `present` is true. Idempotent.
   */
  safeToRemove(): void
}

/** What the outlet hands each overlay slot. */
export interface OverlayPresenceSlot extends OverlayPresence {
  /** Marks the overlay as one that will call `safeToRemove`; returns the undo. */
  register(): () => void
}

const OverlayPresenceContext = createContext<OverlayPresenceSlot | null>(null)

const ALWAYS_PRESENT: OverlayPresence = { present: true, safeToRemove: () => {} }

/** The slot's provider, used by the route outlet. */
export function OverlayPresenceProvider({ value, children }: { value: OverlayPresenceSlot; children: ReactNode }) {
  return <OverlayPresenceContext.Provider value={value}>{children}</OverlayPresenceContext.Provider>
}

/**
 * Whether this overlay's route is still current, and how to release it once
 * its exit has played. Outside a route outlet (a test, a storybook), always
 * present.
 */
export function useOverlayPresence(): OverlayPresence {
  const slot = useContext(OverlayPresenceContext)
  const register = slot?.register

  // Layout effect: registered before the outlet's own effect can see the
  // route leave in the same commit.
  useLayoutEffect(() => register?.(), [register])

  const present = slot?.present ?? true
  const safeToRemove = slot?.safeToRemove
  return useMemo(() => (safeToRemove ? { present, safeToRemove } : ALWAYS_PRESENT), [present, safeToRemove])
}
