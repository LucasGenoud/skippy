"use client";

import { lazy, Suspense, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { Plus } from "lucide-react";
import { AnimatePresence, motion } from "motion/react";

import { NotesSkeleton } from "@/components/common/notes-skeleton";
import { SectionLabel } from "@/components/common/section-label";
import { Button } from "@/components/ui/button";
import { useShellScrollRoot } from "@/features/shell";
import {
  GRID_DENSITIES,
  GRID_WIDTHS,
  useActiveCollection,
  useActiveLayout,
  useActiveSort,
  useComposeLabelIds,
  useHighlightQuery,
  useNotesController,
  useNotesLoading,
  useNotesSelector,
  useSelectedIds,
  useSemanticActive,
  useSettings,
  useUi,
  useUiController,
  useViewSelection,
  useVisibleNoteIds,
} from "@/lib/store";
import { TRANSITION } from "@/lib/theme/motion";

import { rangeSelection } from "./card-rules";
import { gridMetrics } from "./masonry-layout";
import { Masonry } from "./masonry";
import { CardEnvironmentContext, NoteCard, type CardEnvironment } from "./note-card";
import { QuickAddBar } from "./quick-add-bar";

const CollectionSettingsDialog = lazy(() =>
  import("@/features/workspace/collection-settings-dialog").then((m) => ({ default: m.CollectionSettingsDialog })),
);

/** Below this width there is no inline quick add (phones compose from the shell's button). */
const WIDE_BREAKPOINT = 840;
const GRID_SPACING = 8;

/**
 * The notes of the current destination (`home_screen.dart` `_notesGrid`):
 * quick add, the pinned and other sections as an animated masonry or a list,
 * skeletons while loading. The shell scrolls it and draws its headers, empty
 * states and the offline banner.
 */
export function NotesView() {
  const notes = useNotesController();
  const ui = useUiController();
  const { pinned, others } = useVisibleNoteIds();
  const selection = useViewSelection();
  const layout = useActiveLayout();
  const sort = useActiveSort();
  const collection = useActiveCollection();
  const composeLabelIds = useComposeLabelIds();
  const highlight = useHighlightQuery();
  const query = useUi((s) => s.query);
  const workspaceId = useUi((s) => s.activeWorkspaceId);
  const semanticBusy = useUi((s) => s.semantic.busy && s.semantic.ids === null);
  const semanticActive = useSemanticActive();
  const loading = useNotesLoading();
  const shellScroll = useShellScrollRoot();
  const selectedIds = useSelectedIds();
  const density = useSettings((s) => GRID_DENSITIES.find((d) => d.id === s.gridDensity) ?? GRID_DENSITIES[1]);
  const gridWidth = useSettings((s) => GRID_WIDTHS.find((w) => w.id === s.gridWidth) ?? GRID_WIDTHS[1]);
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const [width, setWidth] = useState(0);
  const [raisedId, setRaisedId] = useState<string | null>(null);
  const [collectionDialog, setCollectionDialog] = useState(false);
  const anchor = useRef<string | null>(null);

  useLayoutEffect(() => {
    const element = scrollRef.current;
    if (!element) {
      return;
    }
    setWidth(element.clientWidth);
    if (typeof ResizeObserver === "undefined") {
      return;
    }
    const observer = new ResizeObserver(([entry]) => setWidth(entry?.contentRect.width ?? 0));
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  const searching = query.trim() !== "";
  const view = selection.view;
  const viewKey = `${view}-${selection.labelId ?? ""}-${selection.savedViewId ?? ""}-${workspaceId ?? ""}-${collection?.id ?? ""}`;

  // A new workspace or collection is another grid: it opens at its top. (The
  // shell handles a destination picked in the sidebar.)
  useEffect(() => {
    shellScroll?.current?.scrollTo?.({ top: 0 });
  }, [shellScroll, workspaceId, collection?.id]);

  const compact = width > 0 && width < WIDE_BREAKPOINT;
  const listLayout = layout === "list";
  const metrics = gridMetrics(width || WIDE_BREAKPOINT, density, gridWidth.maxWidth, listLayout ? "list" : "masonry");
  const selectionMode = selectedIds.length > 0;
  const canReorder = !searching && sort === "custom" && (view === "notes" || view === "archive");
  // Trash never reorders, but a card can still be dragged out of it onto a collection.
  const dragEnabled = canReorder || selectionMode || view === "trash";
  const selectedSet = useMemo(() => new Set(selectedIds), [selectedIds]);
  const visibleIds = useMemo(() => [...pinned, ...others], [pinned, others]);

  const spanKey = useNotesSelector((s) => visibleIds.map((id) => s.notes[id]?.gridSpan ?? 1).join(""), Object.is, [visibleIds]);
  const spans = useMemo(() => new Map(visibleIds.map((id, i) => [id, Number(spanKey[i] ?? 1)])), [visibleIds, spanKey]);

  const visibleRef = useRef(visibleIds);
  useEffect(() => {
    visibleRef.current = visibleIds;
  }, [visibleIds]);
  const environment = useMemo<CardEnvironment>(
    () => ({
      query: highlight,
      onSelect: (id, intent) => {
        if (intent === "range") {
          const next = rangeSelection(visibleRef.current, ui.state.selectedIds, anchor.current, id);
          for (const other of next) {
            ui.setSelected(other, true);
          }
          for (const other of ui.state.selectedIds) {
            if (!next.includes(other)) {
              ui.setSelected(other, false);
            }
          }
        } else {
          ui.toggleSelected(id);
        }
        anchor.current = id;
      },
      onSwipeActive: (id, active) => setRaisedId((current) => (active ? id : current === id ? null : current)),
    }),
    [highlight, ui],
  );

  const renderCard = useCallback((id: string) => <NoteCard noteId={id} variant={listLayout ? "list" : "grid"} />, [listLayout]);
  const onReorder = useCallback((ordered: string[]) => notes.reorder(ordered), [notes]);
  const onLongPress = useCallback(
    (id: string) => {
      ui.toggleSelected(id);
      anchor.current = id;
    },
    [ui],
  );

  const showQuickAdd = !compact && width > 0 && !searching && (view === "notes" || view === "label");

  const grid = (ids: readonly string[], section: "pinned" | "others") => (
    <Masonry
      ids={ids}
      spans={spans}
      columns={metrics.columns}
      spacing={GRID_SPACING}
      renderCard={renderCard}
      dragEnabled={dragEnabled}
      draggableIds={selectionMode ? selectedSet : null}
      groupIds={canReorder ? selectedSet : EMPTY_SET}
      canReorder={canReorder}
      onReorder={onReorder}
      onLongPress={onLongPress}
      raisedId={raisedId}
      scrollRoot={shellScroll}
      dragLabel={selectionMode && selectedIds.length > 1 ? `Move ${selectedIds.length} cards` : undefined}
      key={section}
    />
  );

  let body: React.ReactNode;
  if (loading || (semanticActive && semanticBusy)) {
    body = (
      <motion.div key="loading" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={TRANSITION.fast} className="pt-2">
        <NotesSkeleton columns={metrics.columns} />
      </motion.div>
    );
  } else {
    body = (
      <motion.div key={viewKey} initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0, transition: TRANSITION.fast }} transition={TRANSITION.base}>
        <AnimatePresence initial={false}>
          {pinned.length > 0 ? (
            <motion.div key="pinned-label" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={TRANSITION.fast}>
              <SectionLabel className="block px-2 pt-3 pb-2">Pinned</SectionLabel>
            </motion.div>
          ) : null}
        </AnimatePresence>
        {pinned.length > 0 ? grid(pinned, "pinned") : null}
        {pinned.length > 0 && others.length > 0 ? <SectionLabel className="block px-2 pt-5 pb-2">Others</SectionLabel> : null}
        {grid(others, "others")}
      </motion.div>
    );
  }

  return (
    <CardEnvironmentContext.Provider value={environment}>
      <div ref={scrollRef} className="w-full">
        <div className="mx-auto pt-6" style={{ paddingLeft: metrics.pad, paddingRight: metrics.pad, maxWidth: metrics.maxWidth + metrics.pad * 2 }}>
          {showQuickAdd ? (
            <div className="mx-auto w-full max-w-[600px] pt-4 pb-6">
              {collection ? (
                <QuickAddBar labelIds={composeLabelIds} />
              ) : (
                <div className="flex justify-center">
                  <Button onClick={() => setCollectionDialog(true)}>
                    <Plus />
                    Create a collection
                  </Button>
                </div>
              )}
            </div>
          ) : null}
          <div className="relative">
            <AnimatePresence initial={false} mode="popLayout">
              {body}
            </AnimatePresence>
          </div>
        </div>
      </div>
      {collectionDialog && workspaceId ? (
        <Suspense fallback={null}>
          <CollectionSettingsDialog workspaceId={workspaceId} open onOpenChange={(open) => !open && setCollectionDialog(false)} />
        </Suspense>
      ) : null}
    </CardEnvironmentContext.Provider>
  );
}

const EMPTY_SET: ReadonlySet<string> = new Set();
