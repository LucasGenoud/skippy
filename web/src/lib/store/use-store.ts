import { useCallback, useRef, useSyncExternalStore } from "react";

// Narrow subscriptions over vanilla stores. A selector's result is cached
// against the identity of every state it read and its [deps], and an
// `isEqual` hit hands back the previous result, so a component re-renders
// only when its slice really changed.

/** The read side of a zustand vanilla store. */
export interface Readable<S> {
  getState(): S;
  subscribe(listener: (state: S, previous: S) => void): () => void;
}

interface Cache<R> {
  readonly states: readonly unknown[];
  readonly deps: readonly unknown[];
  readonly value: R;
}

function sameList(a: readonly unknown[], b: readonly unknown[]): boolean {
  return a.length === b.length && a.every((x, i) => Object.is(x, b[i]));
}

function useCachedSnapshot<R>(states: () => readonly unknown[], compute: () => R, isEqual: (a: R, b: R) => boolean, deps: readonly unknown[]): () => R {
  const cache = useRef<Cache<R> | null>(null);
  return () => {
    const current = states();
    const cached = cache.current;
    if (cached && sameList(cached.states, current) && sameList(cached.deps, deps)) {
      return cached.value;
    }
    const next = compute();
    if (cached && isEqual(cached.value, next)) {
      cache.current = { states: current, deps, value: cached.value };
      return cached.value;
    }
    cache.current = { states: current, deps, value: next };
    return next;
  };
}

/**
 * Subscribe to [store] through [selector]. [deps] are the selector's inputs
 * besides the state (an id, an option).
 */
export function useStoreSelector<S, R>(store: Readable<S>, selector: (state: S) => R, isEqual: (a: R, b: R) => boolean = Object.is, deps: readonly unknown[] = []): R {
  const subscribe = useCallback((onChange: () => void) => store.subscribe(onChange), [store]);
  const getSnapshot = useCachedSnapshot(
    () => [store.getState()],
    () => selector(store.getState()),
    isEqual,
    deps,
  );
  return useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
}

/** Subscribe to two stores through one selector (notes plus navigation, mostly). */
export function useStorePairSelector<A, B, R>(
  first: Readable<A>,
  second: Readable<B>,
  selector: (a: A, b: B) => R,
  isEqual: (a: R, b: R) => boolean = Object.is,
  deps: readonly unknown[] = [],
): R {
  const subscribe = useCallback(
    (onChange: () => void) => {
      const a = first.subscribe(onChange);
      const b = second.subscribe(onChange);
      return () => {
        a();
        b();
      };
    },
    [first, second],
  );
  const getSnapshot = useCachedSnapshot(
    () => [first.getState(), second.getState()],
    () => selector(first.getState(), second.getState()),
    isEqual,
    deps,
  );
  return useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
}
