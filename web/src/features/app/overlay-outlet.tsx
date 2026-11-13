"use client";

import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { OverlayPresenceProvider, type OverlayPresenceSlot } from "@/components/common/overlay-presence";
import { EXIT_TIMEOUT_MS } from "@/lib/theme/motion";

// The slot `/n/<id>` and `/n/<id>/history` render into. An overlay the route
// has left stays mounted, told it is no longer present, until it releases
// itself (see components/common/overlay-presence.tsx), so closing with the
// browser's back button plays the same exit as the close button.

/** The overlay the route asks for: [key] names one instance. */
export interface OverlayEntry {
  readonly key: string;
  readonly node: ReactNode;
}

interface Item {
  readonly id: number;
  readonly key: string;
  readonly node: ReactNode;
  readonly present: boolean;
}

interface OutletState {
  readonly items: readonly Item[];
  readonly key: string | null;
  readonly nextId: number;
}

function initialState(entry: OverlayEntry | null): OutletState {
  if (!entry) {
    return { items: [], key: null, nextId: 0 };
  }
  return { items: [{ id: 0, key: entry.key, node: entry.node, present: true }], key: entry.key, nextId: 1 };
}

/**
 * The route moved to [entry]: every shown overlay starts leaving, and the new
 * one mounts beside them. One still leaving under the same key is dropped
 * first, so a note reopened mid-close is one editor, not two.
 */
function routeTo(state: OutletState, entry: OverlayEntry | null): OutletState {
  const leaving = state.items.filter((item) => item.key !== entry?.key).map((item) => (item.present ? { ...item, present: false } : item));
  if (!entry) {
    return { items: leaving, key: null, nextId: state.nextId };
  }
  const arriving: Item = { id: state.nextId, key: entry.key, node: entry.node, present: true };
  return { items: [...leaving, arriving], key: entry.key, nextId: state.nextId + 1 };
}

export function OverlayOutlet({ entry }: { entry: OverlayEntry | null }) {
  const [state, setState] = useState(() => initialState(entry));
  const key = entry?.key ?? null;
  let current = state;
  if (key !== state.key) {
    // Derived during render, so the leaving overlay never misses a frame.
    current = routeTo(state, entry);
    setState(current);
  }

  const remove = useCallback((id: number) => {
    setState((s) => ({ ...s, items: s.items.filter((item) => item.id !== id) }));
  }, []);

  return (
    <>
      {current.items.map((item) => (
        <PresenceSlot key={item.id} id={item.id} present={item.present} onRemove={remove}>
          {/* The current overlay renders with fresh props; a leaving one keeps its last. */}
          {item.present && entry ? entry.node : item.node}
        </PresenceSlot>
      ))}
    </>
  );
}

const STAY = (): void => {};

function PresenceSlot({ id, present, onRemove, children }: { id: number; present: boolean; onRemove(id: number): void; children: ReactNode }) {
  const registered = useRef(0);
  const released = useRef(false);

  const release = useCallback(() => {
    if (released.current) {
      return;
    }
    released.current = true;
    onRemove(id);
  }, [id, onRemove]);

  const register = useCallback(() => {
    registered.current += 1;
    return () => {
      registered.current -= 1;
    };
  }, []);

  useEffect(() => {
    if (present) {
      return;
    }
    // Nothing inside will report back: remove at once.
    if (registered.current === 0) {
      release();
      return;
    }
    const timer = window.setTimeout(release, EXIT_TIMEOUT_MS);
    return () => window.clearTimeout(timer);
  }, [present, release]);

  // Only the slot's leaving render hands out the real release, so an
  // overlay cannot remove itself while its route is still current.
  const value = useMemo<OverlayPresenceSlot>(() => ({ present, safeToRemove: present ? STAY : release, register }), [present, release, register]);
  return <OverlayPresenceProvider value={value}>{children}</OverlayPresenceProvider>;
}
