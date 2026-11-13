"use client";

import { useCallback, useEffect, useRef, useState } from "react";

export type Remote<T> = { readonly state: "loading" } | { readonly state: "failed" } | { readonly state: "ready"; readonly value: T };

/**
 * A server read a section shows (share links, tokens, index stats): loading
 * on mount, `reload` from a retry button, `update` for optimistic edits of
 * what came back. Answers that land after unmount are dropped.
 */
export function useRemote<T>(fetcher: () => Promise<T>): {
  remote: Remote<T>;
  reload: () => Promise<void>;
  update: (change: (value: T) => T) => void;
} {
  const [remote, setRemote] = useState<Remote<T>>({ state: "loading" });
  const alive = useRef(true);
  const fetcherRef = useRef(fetcher);

  useEffect(() => {
    fetcherRef.current = fetcher;
  });

  const run = useCallback(async () => {
    try {
      const value = await fetcherRef.current();
      if (alive.current) {
        setRemote({ state: "ready", value });
      }
    } catch {
      if (alive.current) {
        setRemote({ state: "failed" });
      }
    }
  }, []);

  useEffect(() => {
    alive.current = true;
    void run();
    return () => {
      alive.current = false;
    };
  }, [run]);

  const reload = useCallback(async () => {
    setRemote({ state: "loading" });
    await run();
  }, [run]);

  const update = useCallback((change: (value: T) => T) => {
    setRemote((r) => (r.state === "ready" ? { state: "ready", value: change(r.value) } : r));
  }, []);

  return { remote, reload, update };
}
