"use client";

import { useEffect, useRef, useState } from "react";
import { LoaderCircle, RefreshCw } from "lucide-react";
import { Reveal } from "@/components/common/reveal";
import { showAppSnack } from "@/components/common/snack";
import { Button } from "@/components/ui/button";
import { Progress } from "@/components/ui/progress";
import type { SearchStats } from "@/lib/models";
import { useApi } from "@/lib/store";
import { plural } from "../kit/files";
import { useRemote } from "../kit/use-remote";

/** How often a running re-embed is polled. */
const POLL_MS = 500;

const sleep = (ms: number): Promise<void> => new Promise((resolve) => window.setTimeout(resolve, ms));

/**
 * Diagnostics for the semantic index (model, vector width, how many notes
 * are embedded) and a button that re-runs the embeddings with live progress.
 */
export function EmbeddingStats() {
  const api = useApi();
  const { remote: load, reload } = useRemote<SearchStats>(() => api.fetchSearchStats());
  const [reindexing, setReindexing] = useState(false);
  const [progress, setProgress] = useState<{ done: number; total: number } | null>(null);
  const alive = useRef(true);

  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);

  async function reindex() {
    setReindexing(true);
    setProgress(null);
    try {
      const total = await api.reindexEmbeddings();
      if (total === 0) {
        showAppSnack("No notes to re-embed");
      } else {
        setProgress({ done: 0, total });
        while (alive.current) {
          await sleep(POLL_MS);
          if (!alive.current) {
            return;
          }
          const status = await api.fetchReindexStatus();
          setProgress({ done: status.done, total: status.total });
          if (!status.running) {
            break;
          }
        }
        showAppSnack(`Re-embedded ${plural(total, "note")}`);
      }
    } catch {
      showAppSnack("Could not re-embed");
    }
    if (!alive.current) {
      return;
    }
    setReindexing(false);
    setProgress(null);
    await reload();
  }

  return (
    <div className="flex flex-col gap-2 pr-3 pb-3 pl-12">
      <span className="text-xs font-medium text-on-surface-variant">Embedding index</span>
      {load.state === "loading" ? (
        <span className="flex items-center gap-2 py-1 text-sm text-on-surface-variant">
          <LoaderCircle aria-hidden className="size-4 animate-spin" />
          Loading index stats…
        </span>
      ) : load.state === "failed" || !load.value.enabled ? (
        <span className="text-sm text-on-surface-variant">Index diagnostics are unavailable.</span>
      ) : (
        <>
          <dl className="grid grid-cols-[8rem_1fr] gap-x-3 gap-y-1.5 text-sm">
            <dt className="text-on-surface-variant">Model</dt>
            <dd className="font-medium break-all text-on-surface">{load.value.model}</dd>
            <dt className="text-on-surface-variant">Dimensions</dt>
            <dd className="font-medium text-on-surface">{load.value.dimensions}</dd>
            <dt className="text-on-surface-variant">Notes embedded</dt>
            <dd className="text-on-surface">
              <span className="font-medium tabular-nums">
                {load.value.indexedNotes} / {load.value.totalNotes}
              </span>
              {load.value.indexedNotes < load.value.totalNotes ? <span className="block text-xs text-on-surface-variant">some notes are not indexed yet</span> : null}
            </dd>
          </dl>
          <div className="pt-2">
            <Button variant="secondary" size="sm" disabled={reindexing} onClick={() => void reindex()}>
              {reindexing ? <LoaderCircle aria-hidden className="animate-spin" /> : <RefreshCw aria-hidden />}
              {reindexing ? "Re-embedding…" : "Re-run embeddings"}
            </Button>
          </div>
          <Reveal>{reindexing ? <ReindexProgress progress={progress} /> : null}</Reveal>
        </>
      )}
    </div>
  );
}

/** Determinate once the first status poll arrives; a moving sliver before. */
function ReindexProgress({ progress }: { progress: { done: number; total: number } | null }) {
  const value = progress && progress.total > 0 ? (progress.done / progress.total) * 100 : null;
  return (
    <div className="flex flex-col gap-1.5 pt-3 pr-2">
      {value === null ? <Progress aria-label="Re-embedding" className="animate-pulse" value={8} /> : <Progress aria-label="Re-embedding" value={value} />}
      {progress ? (
        <span className="text-xs text-on-surface-variant tabular-nums">
          {progress.done} / {progress.total} embedded
        </span>
      ) : null}
    </div>
  );
}
