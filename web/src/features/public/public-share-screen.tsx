"use client";

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { Eye, Link2Off, LoaderCircle, RefreshCw } from "lucide-react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { AppLogo } from "@/components/common/app-logo";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import type { Api } from "@/lib/api/client";
import { getPublicApi } from "@/lib/api/public-api";
import type { Label, Note } from "@/lib/models/note";
import type { PublicShare } from "@/lib/models/misc";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";
import { PublicNoteCard } from "./public-note-card";
import { boardColumns, gridColumnCount, masonryColumns } from "./public-layout";

// The page behind a public link (`screens/public_share_screen.dart`):
// someone else's notes, read only, with no account and no session. No store
// exists here on purpose; everything drawn comes from the one payload fetched.

type Load = { readonly state: "loading" } | { readonly state: "ready"; readonly share: PublicShare } | { readonly state: "unavailable" };

const GRID_GAP_PX = 8;

export function PublicShareScreen({ token, api }: { token: string; /** For tests; the page's own origin otherwise. */ api?: Api }) {
  const client = api ?? getPublicApi();
  const [attempt, setAttempt] = useState(0);
  const [load, setLoad] = useState<{ key: string; result: Load } | null>(null);
  const reduced = useReducedMotion();
  const key = `${token}#${attempt}`;

  useEffect(() => {
    let current = true;
    client.fetchPublicShare(token).then(
      (share) => current && setLoad({ key, result: { state: "ready", share } }),
      // Revoked, expired, mistyped or gone all look the same from out here:
      // saying which would leak whether a token was ever real.
      () => current && setLoad({ key, result: { state: "unavailable" } }),
    );
    return () => {
      current = false;
    };
  }, [client, token, key]);

  const result: Load = load?.key === key ? load.result : { state: "loading" };
  const title = result.state === "ready" ? result.share.title : null;

  useEffect(() => {
    if (!title) {
      return;
    }
    const previous = document.title;
    document.title = `${title} · Skippy`;
    return () => {
      document.title = previous;
    };
  }, [title]);

  return (
    <main className="min-h-dvh bg-canvas">
      <AnimatePresence mode="wait" initial={false}>
        <motion.div
          key={result.state}
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={transitionFor(TRANSITION.base, reduced)}
          className="min-h-dvh"
        >
          {result.state === "loading" ? (
            <div className="flex min-h-dvh items-center justify-center" role="status" aria-label="Loading">
              <LoaderCircle aria-hidden className="size-6 animate-spin text-on-surface-variant" />
            </div>
          ) : result.state === "unavailable" ? (
            <Unavailable onRetry={() => setAttempt((a) => a + 1)} />
          ) : (
            <ShareBody share={result.share} api={client} />
          )}
        </motion.div>
      </AnimatePresence>
    </main>
  );
}

function Unavailable({ onRetry }: { onRetry(): void }) {
  return (
    <div className="flex min-h-dvh items-center justify-center p-6">
      <div className="flex max-w-[420px] flex-col items-center text-center">
        <Link2Off aria-hidden className="size-12 text-on-surface-variant" strokeWidth={1.5} />
        <h1 className="mt-4 text-base font-semibold text-on-surface">This link is not available</h1>
        <p className="mt-2 text-sm text-on-surface-variant">It may have been revoked or expired. Ask whoever shared it for a new one.</p>
        <Button variant="ghost" className="mt-5" onClick={onRetry}>
          <RefreshCw />
          Try again
        </Button>
      </div>
    </div>
  );
}

function ShareBody({ share, api }: { share: PublicShare; api: Api }) {
  const labels = useMemo(() => new Map<string, Label>(share.labels.map((l) => [l.id, l])), [share.labels]);
  const first = share.notes[0];
  return (
    <div className="pb-12">
      <Header share={share} />
      {first === undefined ? (
        <p className="p-12 text-center text-base text-on-surface-variant">
          {share.target === "note" ? "This note is empty" : "Nothing has been added here yet"}
        </p>
      ) : share.target === "board" ? (
        <Board share={share} api={api} labels={labels} />
      ) : share.target === "note" ? (
        <div className="mx-auto max-w-[720px] px-5 pt-3">
          {/* The whole note rather than a card's preview: nothing clipped, nowhere to tap through to. */}
          <PublicNoteCard note={first} api={api} labels={labels} extent="full" />
        </div>
      ) : (
        <Grid notes={share.notes} api={api} labels={labels} />
      )}
    </div>
  );
}

function Header({ share }: { share: PublicShare }) {
  return (
    <header className="mx-auto max-w-[1100px] px-5 pt-5 pb-3">
      <div className="flex items-center gap-2.5">
        <AppLogo size={26} />
        <span className="text-sm font-semibold text-on-surface-variant">Skippy</span>
        {/* Says plainly what this page is, so nobody hunts for an edit control. */}
        <Badge variant="outline" className="ml-auto">
          <Eye aria-hidden />
          Read only
        </Badge>
      </div>
      <h1 className="mt-4 text-2xl font-semibold tracking-tight break-words text-on-surface">{share.title}</h1>
      <p className="mt-1 text-xs text-on-surface-variant">{share.sharedBy === "" ? "Shared with you" : `Shared by ${share.sharedBy}`}</p>
      <div className="mt-3 h-px bg-hairline" />
    </header>
  );
}

/** The container's width, followed as it resizes. */
function useWidth(): [(element: HTMLDivElement | null) => void, number] {
  const [width, setWidth] = useState(0);
  const observer = useRef<ResizeObserver | null>(null);
  const ref = useCallback((element: HTMLDivElement | null) => {
    observer.current?.disconnect();
    observer.current = null;
    if (!element) {
      return;
    }
    setWidth(element.clientWidth);
    if (typeof ResizeObserver !== "undefined") {
      observer.current = new ResizeObserver(() => setWidth(element.clientWidth));
      observer.current.observe(element);
    }
  }, []);
  useLayoutEffect(() => () => observer.current?.disconnect(), []);
  return [ref, width];
}

function Grid({ notes, api, labels }: { notes: readonly Note[]; api: Api; labels: ReadonlyMap<string, Label> }) {
  const [ref, width] = useWidth();
  const columns = useMemo(() => masonryColumns(notes, gridColumnCount(width)), [notes, width]);
  return (
    <div ref={ref} className="mx-auto flex max-w-[1100px] items-start px-4 py-2" style={{ gap: GRID_GAP_PX }}>
      {columns.map((column, index) => (
        <div key={index} className="flex min-w-0 flex-1 flex-col" style={{ gap: GRID_GAP_PX }}>
          {column.map((note) => (
            <PublicNoteCard key={note.id} note={note} api={api} labels={labels} extent="preview" />
          ))}
        </div>
      ))}
    </div>
  );
}

/** Side-by-side columns on a wide screen, stacked sections on a phone. Read only: no drag. */
function Board({ share, api, labels }: { share: PublicShare; api: Api; labels: ReadonlyMap<string, Label> }) {
  const columns = useMemo(() => boardColumns(share.notes, share.stages), [share.notes, share.stages]);
  return (
    <div className="mx-auto max-w-[1400px] px-4 py-2">
      <div className="flex flex-col gap-5 min-[700px]:flex-row min-[700px]:items-start min-[700px]:gap-3 min-[700px]:overflow-x-auto min-[700px]:pb-2">
        {columns.map((column) => (
          <section
            key={column.key}
            aria-label={column.title}
            className="flex flex-col gap-2 rounded-md border border-trough-border bg-trough p-2.5 min-[700px]:w-[300px] min-[700px]:shrink-0"
          >
            <div className="flex items-center gap-2 px-1 pt-0.5 pb-1">
              <h2 className="min-w-0 flex-1 truncate text-sm font-semibold text-on-surface">{column.title}</h2>
              <span className="text-xs font-medium text-on-surface-variant">{column.notes.length}</span>
            </div>
            {column.notes.map((note) => (
              <PublicNoteCard key={note.id} note={note} api={api} labels={labels} extent="preview" />
            ))}
          </section>
        ))}
      </div>
    </div>
  );
}
