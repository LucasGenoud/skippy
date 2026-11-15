"use client";

import { memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { flushSync } from "react-dom";
import {
  DndContext,
  DragOverlay,
  MouseSensor,
  TouchSensor,
  useDraggable,
  useSensor,
  useSensors,
  type DragEndEvent,
  type DragMoveEvent,
  type DragStartEvent,
} from "@dnd-kit/core";
import { animate, motion, useMotionValue, useReducedMotion, type Transition } from "motion/react";
import { cn } from "cn";

import { DURATION, EASE, TRANSITION } from "@/lib/theme/motion";

import {
  ESTIMATED_CARD_HEIGHT,
  idsInBand,
  mergeDuringDrag,
  orderAtPoint,
  packMasonry,
  sameMembers,
  sameOrder,
  type MasonryLayout,
  type MasonrySlot,
} from "./masonry-layout";

// A masonry grid where every layout change animates (`widgets/masonry.dart`).
// Positions are computed in JS (masonry-layout.ts) and applied as transforms,
// gliding on a spring that keeps its speed when retargeted mid-flight. Cards
// measure themselves through one shared ResizeObserver; only cards near the
// viewport are mounted. Dragging a card (instantly with a mouse, after a hold
// on touch) flows the others around the pointer.

/** How long the pointer stays on one target before the grid reflows around it. */
const REORDER_SETTLE_MS = 50;
/** Long press that selects on touch where no drag is offered. */
const LONG_PRESS_MS = 450;
const LONG_PRESS_SLOP = 8;
/** A drag's release swallows the click that follows it. */
const CLICK_GUARD_MS = 350;
/** Mounted margin around the viewport, as a share of its height. */
const VIEWPORT_MARGIN = 0.5;
/** Mouse drags start after this much movement, so a click still opens. */
const MOUSE_DRAG_DISTANCE = 4;
/** Touch drags start after this hold (`LongPressDraggable` delay). */
const TOUCH_DRAG_DELAY_MS = 220;
const TOUCH_DRAG_TOLERANCE = 6;
/** Opening grids cascade in, offset per card, capped. */
const STAGGER_MS = 18;
const STAGGER_CAP_MS = 200;
const HIDDEN_SCALE = 0.95;
/** How far an opening grid's cards rise as they fade in. */
const ENTRANCE_RISE_PX = 8;
const GHOST_OPACITY = 0.3;
/** Geometry changes and reduced motion place cards outright. */
const SNAP: Transition = { duration: 0 };

/** Card heights remembered across grids, so a grid built again lays out right at once. */
const knownHeights = new Map<string, { width: number; height: number }>();

/** An element the grid can drop notes on: `data-note-drop` marks it; it receives a `skippy:note-drop` event. */
export const NOTE_DROP_EVENT = "skippy:note-drop";
export interface NoteDropDetail {
  readonly noteIds: readonly string[];
}

function dropTargetAt(x: number, y: number): HTMLElement | null {
  if (typeof document === "undefined") {
    return null;
  }
  // The drag overlay sits under the pointer, so look through it rather than at the topmost element.
  for (const element of document.elementsFromPoint(x, y)) {
    const target = element instanceof HTMLElement ? element.closest<HTMLElement>("[data-note-drop]") : null;
    if (target) {
      return target;
    }
  }
  return null;
}

export interface MasonryProps {
  /** Ids in display order. */
  ids: readonly string[];
  spans: ReadonlyMap<string, number>;
  columns: number;
  spacing?: number;
  renderCard: (id: string) => ReactNode;
  /** Whether cards can be lifted at all (custom order, selection, or trash). */
  dragEnabled: boolean;
  /** When set, only these can start a drag (selection mode). */
  draggableIds: ReadonlySet<string> | null;
  /** Selected cards that move together. */
  groupIds: ReadonlySet<string>;
  /** Whether a reorder inside the grid is persisted. */
  canReorder: boolean;
  onReorder: (ordered: string[]) => void;
  /** A touch hold released in place (or a long press where nothing drags). */
  onLongPress: (id: string) => void;
  /** Painted above its neighbours (a card being swiped). */
  raisedId: string | null;
  /** Shown on the lifted card when it carries several. */
  dragLabel?: string;
  /** The element the grid scrolls in; the window when absent. */
  scrollRoot?: { readonly current: HTMLElement | null } | null;
}

interface Departing {
  readonly slot: MasonrySlot;
  readonly height: number;
}

export function Masonry({
  ids,
  spans,
  columns,
  spacing = 8,
  renderCard,
  dragEnabled,
  draggableIds,
  groupIds,
  canReorder,
  onReorder,
  onLongPress,
  raisedId,
  dragLabel,
  scrollRoot,
}: MasonryProps) {
  const reduced = useReducedMotion() ?? false;
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [width, setWidth] = useState(0);
  // Cards mount only once the grid has read its width (before the first
  // paint), so none is first placed for a zero-width grid and then moved.
  const [sized, setSized] = useState(false);
  const [measured, setMeasured] = useState<ReadonlyMap<string, number>>(() => new Map());
  // Mirrors for event handlers and frame callbacks, synced after each render.
  const heightsRef = useRef<ReadonlyMap<string, number>>(measured);
  const [band, setBand] = useState<{ top: number; bottom: number } | null>(null);
  const [settledGeometry, setSettledGeometry] = useState<string | null>(null);
  const [measureSnap, setMeasureSnap] = useState(false);
  const visibleRef = useRef<ReadonlySet<string>>(new Set());
  // Slots as last drawn, for cards that leave.
  const lastSlots = useRef<ReadonlyMap<string, MasonrySlot>>(new Map());
  const [opening, setOpening] = useState(true);
  const openingRef = useRef(true);
  const [dragOrder, setDragOrder] = useState<string[] | null>(null);
  const [dragging, setDragging] = useState<{ id: string; ids: ReadonlySet<string>; startOrder: readonly string[] } | null>(null);
  const [departing, setDeparting] = useState<ReadonlyMap<string, Departing>>(new Map());
  const [arriving, setArriving] = useState<ReadonlySet<string>>(new Set());
  const [mountOrder] = useState<ReadonlyMap<string, number>>(() => new Map(ids.map((id, i) => [id, i])));
  const previousIds = useRef<readonly string[]>(ids);
  const layoutRef = useRef<MasonryLayout | null>(null);
  const draggingRef = useRef<{ id: string; ids: ReadonlySet<string>; startOrder: readonly string[] } | null>(null);
  const orderRef = useRef<readonly string[]>(ids);
  const clickGuardUntil = useRef(0);

  const order = useMemo(() => (dragOrder ? mergeDuringDrag(dragOrder, ids) : [...ids]), [dragOrder, ids]);

  // Width of the grid, via the shared observer.
  useLayoutEffect(() => {
    const element = containerRef.current;
    if (!element) {
      return;
    }
    setWidth(element.getBoundingClientRect().width);
    setSized(true);
    if (typeof ResizeObserver === "undefined") {
      return;
    }
    const observer = new ResizeObserver(([entry]) => setWidth(entry?.contentRect.width ?? 0));
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  // Geometry changes (resize, column count) place cards at once rather than
  // gliding them across; two frames later moves glide again.
  const geometry = `${width}:${columns}`;
  useEffect(() => {
    let inner = 0;
    const outer = requestAnimationFrame(() => {
      inner = requestAnimationFrame(() => setSettledGeometry(geometry));
    });
    return () => {
      cancelAnimationFrame(outer);
      cancelAnimationFrame(inner);
    };
  }, [geometry]);
  const snap = settledGeometry !== geometry || measureSnap;

  // The opening grid's guesses are corrected without glides; after two frames a change is a move.
  useEffect(() => {
    const frame = requestAnimationFrame(() =>
      requestAnimationFrame(() => {
        openingRef.current = false;
        setOpening(false);
      }),
    );
    return () => cancelAnimationFrame(frame);
  }, []);

  // Measured heights, plus heights earlier grids recorded for these cards at this width.
  const heights = useMemo(() => {
    const cols = Math.max(1, columns);
    const columnWidth = (width - spacing * (cols - 1)) / cols;
    let seeded: Map<string, number> | null = null;
    for (const id of order) {
      if (measured.has(id)) {
        continue;
      }
      const span = Math.min(Math.max(1, spans.get(id) ?? 1), cols);
      const known = knownHeights.get(id);
      if (known && Math.abs(known.width - (columnWidth * span + spacing * (span - 1))) < 0.5) {
        seeded ??= new Map(measured);
        seeded.set(id, known.height);
      }
    }
    return seeded ?? measured;
  }, [order, spans, columns, spacing, width, measured]);

  const layout = useMemo(() => packMasonry({ order, spans, heights, columns, spacing, width }), [order, spans, heights, columns, spacing, width]);

  // Arrivals and departures, before the caches forget the leavers.
  useLayoutEffect(() => {
    const previous = previousIds.current;
    previousIds.current = ids;
    if (previous === ids) {
      return;
    }
    const incoming = new Set(ids);
    const before = new Set(previous);
    const arrived = ids.filter((id) => !before.has(id));
    const left = previous.filter((id) => !incoming.has(id));
    if (arrived.length > 0 && !openingRef.current) {
      setArriving(new Set(arrived));
    }
    if (left.length === 0 && arrived.length === 0) {
      return;
    }
    setDeparting((current) => {
      const next = new Map(current);
      for (const id of arrived) {
        next.delete(id);
      }
      // Mid-drag the drag owns every position; leavers just go.
      if (!dragging) {
        const prior = lastSlots.current;
        for (const id of left) {
          const slot = prior.get(id);
          if (slot && visibleRef.current.has(id)) {
            next.set(id, { slot, height: heightsRef.current.get(id) ?? ESTIMATED_CARD_HEIGHT });
          }
        }
      }
      return next;
    });
  }, [ids, dragging]);

  // Mirrors for handlers and frame callbacks.
  useLayoutEffect(() => {
    lastSlots.current = layout.slots;
    layoutRef.current = layout;
  }, [layout]);
  useLayoutEffect(() => {
    orderRef.current = order;
  }, [order]);
  useLayoutEffect(() => {
    draggingRef.current = dragging;
  }, [dragging]);

  // Which cards sit near the viewport: measured now, on any scroll (captured
  // at the document, so a nested scroller counts) and on resize.
  useEffect(() => {
    const measure = (): void => {
      const element = containerRef.current;
      if (!element) {
        return;
      }
      const rect = element.getBoundingClientRect();
      // The scroller's box, clipped to the window.
      const clip = scrollRoot?.current?.getBoundingClientRect();
      const clipTop = Math.max(0, clip?.top ?? 0);
      const clipBottom = Math.min(window.innerHeight, clip?.bottom ?? window.innerHeight);
      const margin = (clipBottom - clipTop) * VIEWPORT_MARGIN;
      const top = clipTop - rect.top - margin;
      const bottom = clipBottom - rect.top + margin;
      setBand((current) => (current && Math.abs(current.top - top) < 1 && Math.abs(current.bottom - bottom) < 1 ? current : { top, bottom }));
    };
    let frame: number | null = null;
    const onScroll = (): void => {
      if (frame !== null) {
        return;
      }
      frame = requestAnimationFrame(() => {
        frame = null;
        measure();
      });
    };
    onScroll();
    document.addEventListener("scroll", onScroll, { capture: true, passive: true });
    window.addEventListener("resize", onScroll);
    return () => {
      document.removeEventListener("scroll", onScroll, { capture: true });
      window.removeEventListener("resize", onScroll);
      if (frame !== null) {
        cancelAnimationFrame(frame);
      }
    };
  }, [scrollRoot, layout.totalHeight]);

  const visible = useMemo(() => {
    if (!band) {
      // Before the grid knows where it is: the first screenful.
      return new Set(order.slice(0, 20));
    }
    const set = idsInBand(order, layout, heights, band.top, band.bottom);
    for (const id of dragging?.ids ?? []) {
      set.add(id);
    }
    return set;
  }, [band, order, layout, heights, dragging]);
  useLayoutEffect(() => {
    visibleRef.current = visible;
  }, [visible]);

  // Every card reports to one observer. Its callback runs after layout and
  // before paint, so committing there (flushSync) means a frame drawn from
  // guessed heights, with cards overlapping, never reaches the screen.
  const cardIds = useRef(new WeakMap<Element, string>());
  const observer = useRef<ResizeObserver | null>(null);
  const onCardsResized = useCallback(
    (entries: ResizeObserverEntry[]) => {
      const current = heightsRef.current;
      const changed = new Map<string, number>();
      for (const entry of entries) {
        const id = cardIds.current.get(entry.target);
        const box = entry.borderBoxSize?.[0];
        const size = { width: box ? box.inlineSize : entry.contentRect.width, height: box ? box.blockSize : entry.contentRect.height };
        if (id === undefined || size.height <= 0) {
          continue;
        }
        knownHeights.set(id, size);
        if (current.get(id) !== size.height) {
          changed.set(id, size.height);
        }
      }
      if (changed.size === 0) {
        return;
      }

      // A first measurement corrects a guess rather than moving a card.
      const firstMeasure = [...changed.keys()].some((id) => !current.has(id));
      const snapOpening = firstMeasure && openingRef.current && !draggingRef.current;
      const next = new Map(current);
      for (const [id, height] of changed) {
        next.set(id, height);
      }
      heightsRef.current = next;
      flushSync(() => {
        if (snapOpening) {
          setMeasureSnap(true);
        }
        setMeasured(next);
      });
      if (snapOpening) {
        requestAnimationFrame(() => requestAnimationFrame(() => setMeasureSnap(false)));
      }
    },
    [],
  );
  // Each card unobserves itself on unmount, so the observer needs no teardown
  // of its own: one with nothing left to watch is collected with the grid.
  const observeCard = useCallback(
    (element: Element, id: string): (() => void) => {
      if (typeof ResizeObserver === "undefined") {
        return () => undefined;
      }
      observer.current ??= new ResizeObserver(onCardsResized);
      const watching = observer.current;
      cardIds.current.set(element, id);
      watching.observe(element);
      return () => {
        watching.unobserve(element);
        cardIds.current.delete(element);
      };
    },
    [onCardsResized],
  );

  // -- drag ----------------------------------------------------------------------

  const sensors = useSensors(
    useSensor(MouseSensor, { activationConstraint: { distance: MOUSE_DRAG_DISTANCE } }),
    useSensor(TouchSensor, { activationConstraint: { delay: TOUCH_DRAG_DELAY_MS, tolerance: TOUCH_DRAG_TOLERANCE } }),
  );
  const pointerStart = useRef<{ x: number; y: number } | null>(null);
  const lastPointer = useRef<{ x: number; y: number } | null>(null);
  const moved = useRef(false);
  const changedOrder = useRef(false);
  const settleTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const pendingOrder = useRef<string[] | null>(null);
  const hoverTarget = useRef<HTMLElement | null>(null);

  const cancelPending = (): void => {
    if (settleTimer.current) {
      clearTimeout(settleTimer.current);
    }
    settleTimer.current = null;
    pendingOrder.current = null;
  };

  const orderAtPointer = (point: { x: number; y: number }, current: readonly string[]): string[] | null => {
    const element = containerRef.current;
    const active = draggingRef.current;
    const currentLayout = layoutRef.current;
    if (!element || !active || !currentLayout) {
      return null;
    }
    const rect = element.getBoundingClientRect();
    return orderAtPoint(
      { order: current, layout: currentLayout, heights: heightsRef.current, dragging: active.ids, draggingId: active.id, gridWidth: rect.width },
      { x: point.x - rect.left, y: point.y - rect.top },
    );
  };


  const applyPending = (): void => {
    cancelPending();
    const point = lastPointer.current;
    const next = point ? orderAtPointer(point, orderRef.current) : null;
    if (!next || sameOrder(next, orderRef.current)) {
      return;
    }
    orderRef.current = next;
    setDragOrder(next);
    changedOrder.current = true;
  };

  const onDragStart = (event: DragStartEvent): void => {
    const id = String(event.active.id);
    const activator = event.activatorEvent as PointerEvent | TouchEvent | MouseEvent;
    const point = "touches" in activator ? activator.touches[0] : activator;
    pointerStart.current = point ? { x: point.clientX, y: point.clientY } : null;
    moved.current = false;
    changedOrder.current = false;
    const ids = groupIds.has(id) ? new Set(order.filter((other) => groupIds.has(other))) : new Set([id]);
    const next = { id, ids, startOrder: [...order] };
    draggingRef.current = next;
    setDragging(next);
    setDragOrder([...order]);
    // The whole page shows the grab while a card is carried, not just the card.
    document.body.style.cursor = "grabbing";
  };

  const onDragMove = (event: DragMoveEvent): void => {
    const start = pointerStart.current;
    if (!start) {
      return;
    }
    if (event.delta.x !== 0 || event.delta.y !== 0) {
      moved.current = true;
    }
    const point = { x: start.x + event.delta.x, y: start.y + event.delta.y };
    lastPointer.current = point;

    const target = dropTargetAt(point.x, point.y);
    if (target !== hoverTarget.current) {
      hoverTarget.current?.removeAttribute("data-drop-hover");
      target?.setAttribute("data-drop-hover", "");
      hoverTarget.current = target;
    }

    // Debounced on the target, not the pointer, so jitter inside a card does not postpone it.
    const next = orderAtPointer(point, orderRef.current);
    if (!next) {
      return;
    }
    if (sameOrder(next, orderRef.current)) {
      cancelPending();
      return;
    }
    if (sameOrder(next, pendingOrder.current)) {
      return;
    }
    pendingOrder.current = next;
    if (settleTimer.current) {
      clearTimeout(settleTimer.current);
    }
    settleTimer.current = setTimeout(applyPending, REORDER_SETTLE_MS);
  };

  const finishDrag = (event: DragEndEvent | null): void => {
    if (settleTimer.current) {
      applyPending();
    }
    const active = draggingRef.current;
    const point = lastPointer.current;
    lastPointer.current = null;
    pointerStart.current = null;
    hoverTarget.current?.removeAttribute("data-drop-hover");
    hoverTarget.current = null;
    clickGuardUntil.current = Date.now() + CLICK_GUARD_MS;
    document.body.style.cursor = "";
    if (!active) {
      return;
    }
    const final = orderRef.current;

    // A drop onto a target outside the grid (a sidebar label, a collection) owns the gesture.
    let accepted = false;
    if (event && point) {
      const target = dropTargetAt(point.x, point.y);
      if (target) {
        const ids = active.startOrder.filter((id) => active.ids.has(id));
        target.dispatchEvent(new CustomEvent<NoteDropDetail>(NOTE_DROP_EVENT, { detail: { noteIds: ids }, bubbles: true }));
        accepted = true;
      }
    }

    const keep = event !== null && changedOrder.current && !accepted && canReorder && sameMembers(active.startOrder, final) && !sameOrder(active.startOrder, final);
    setDragging(null);
    if (keep) {
      onReorder([...final]);
    }
    setDragOrder(null);
    const stationary = !moved.current;
    changedOrder.current = false;
    if (event && stationary && isTouch(event)) {
      onLongPress(active.id);
    }
  };

  const activeId = dragging?.id ?? null;
  const activeSlot = activeId ? layout.slots.get(activeId) : undefined;

  // One element per card for as long as the order holds, so a re-pack (a
  // card growing, a neighbour arriving) only re-renders the tiles that move.
  const cards = useMemo(() => new Map(order.map((id) => [id, renderCard(id)])), [order, renderCard]);
  const guardClick = useCallback(() => {
    clickGuardUntil.current = Date.now() + CLICK_GUARD_MS;
  }, []);

  // -- render --------------------------------------------------------------------

  const spring: Transition = reduced || snap ? SNAP : TRANSITION.spring;
  const rendered = sized ? order.filter((id) => visible.has(id) && layout.slots.has(id)) : [];
  // Leaving cards paint first, so cards gliding into their gap pass over them; a raised card paints last.
  const raised = raisedId && rendered.includes(raisedId) ? raisedId : null;
  const tiles = raised ? [...rendered.filter((id) => id !== raised), raised] : rendered;

  return (
    <DndContext sensors={sensors} onDragStart={onDragStart} onDragMove={onDragMove} onDragEnd={finishDrag} onDragCancel={() => finishDrag(null)} autoScroll={{ threshold: { x: 0, y: 0.15 } }}>
      <div
        ref={containerRef}
        className={cn("relative", !snap && !reduced && "transition-[height] duration-240 ease-emphasized")}
        style={{ height: layout.totalHeight }}
        onClickCapture={(event) => {
          if (Date.now() < clickGuardUntil.current) {
            event.stopPropagation();
            event.preventDefault();
          }
        }}
      >
        {[...departing.entries()].map(([id, gone]) => (
          <LeavingTile
            key={id}
            slot={gone.slot}
            reduced={reduced}
            onGone={() =>
              setDeparting((current) => {
                const next = new Map(current);
                next.delete(id);
                return next;
              })
            }
          >
            {renderCard(id)}
          </LeavingTile>
        ))}
        {tiles.map((id) => (
          <Tile
            key={id}
            id={id}
            slot={layout.slots.get(id)!}
            transition={spring}
            arriving={arriving.has(id)}
            staggerIndex={opening ? (mountOrder.get(id) ?? null) : null}
            reduced={reduced}
            ghost={dragging?.ids.has(id) ?? false}
            dragDisabled={!dragEnabled || (draggableIds !== null && !draggableIds.has(id))}
            longPressOnly={!dragEnabled || (draggableIds !== null && !draggableIds.has(id))}
            raised={id === raised}
            observeCard={observeCard}
            onLongPress={onLongPress}
            guardClick={guardClick}
          >
            {cards.get(id) ?? renderCard(id)}
          </Tile>
        ))}
      </div>
      <DragOverlay dropAnimation={reduced ? null : { duration: DURATION.base, easing: `cubic-bezier(${EASE.emphasized.join(",")})` }} zIndex={60}>
        {activeId && activeSlot ? (
          <motion.div
            className="pointer-events-none relative rounded-md shadow-raised"
            style={{ width: activeSlot.width }}
            initial={{ scale: 1, opacity: 1 }}
            animate={{ scale: 1.04, opacity: 0.84 }}
            transition={TRANSITION.fast}
          >
            {renderCard(activeId)}
            {dragLabel ? (
              <span className="absolute right-2 bottom-2 rounded-md bg-primary-container px-2.5 py-1.5 text-sm font-medium text-on-primary-container shadow-card">{dragLabel}</span>
            ) : null}
          </motion.div>
        ) : null}
      </DragOverlay>
    </DndContext>
  );
}

function isTouch(event: DragEndEvent): boolean {
  const activator = event.activatorEvent;
  return typeof TouchEvent !== "undefined" && activator instanceof TouchEvent;
}

interface TileProps {
  id: string;
  slot: MasonrySlot;
  transition: Transition;
  arriving: boolean;
  staggerIndex: number | null;
  reduced: boolean;
  ghost: boolean;
  dragDisabled: boolean;
  longPressOnly: boolean;
  raised: boolean;
  /** Reports the card's size to the grid's observer; returns the unsubscribe. */
  observeCard: (element: Element, id: string) => () => void;
  onLongPress: (id: string) => void;
  guardClick: () => void;
  children: ReactNode;
}

/** Tiles compare their slot by value: every pack makes new slot objects. */
function tilePropsEqual(a: TileProps, b: TileProps): boolean {
  for (const key of Object.keys(b) as (keyof TileProps)[]) {
    if (key === "slot") {
      if (a.slot.x !== b.slot.x || a.slot.y !== b.slot.y || a.slot.width !== b.slot.width) {
        return false;
      }
    } else if (!Object.is(a[key], b[key])) {
      return false;
    }
  }
  return true;
}

/** One card at its slot: glides on a spring, fades in when it joins a grid already shown. */
const Tile = memo(function Tile({
  id,
  slot,
  transition,
  arriving,
  staggerIndex,
  reduced,
  ghost,
  dragDisabled,
  longPressOnly,
  raised,
  observeCard,
  onLongPress,
  guardClick,
  children,
}: TileProps) {
  const { setNodeRef, listeners } = useDraggable({ id, disabled: dragDisabled });
  const measureRef = useRef<HTMLDivElement | null>(null);
  const press = useRef<{ x: number; y: number; timer: ReturnType<typeof setTimeout> } | null>(null);

  useLayoutEffect(() => {
    const element = measureRef.current;
    return element ? observeCard(element, id) : undefined;
  }, [id, observeCard]);

  // The card's place. A snap (opening, resize, column change) jumps the values
  // and writes them before the next paint; motion's own render would land a
  // frame later and show the cards in their old places for that frame. Any
  // other move glides, keeping its speed when retargeted mid-flight.
  const placeRef = useRef<HTMLDivElement | null>(null);
  const x = useMotionValue(slot.x);
  const y = useMotionValue(slot.y);
  useLayoutEffect(() => {
    if (transition === SNAP) {
      x.jump(slot.x);
      y.jump(slot.y);
      if (placeRef.current) {
        placeRef.current.style.transform = `translateX(${slot.x}px) translateY(${slot.y}px)`;
      }
      return;
    }
    animate(x, slot.x, transition);
    animate(y, slot.y, transition);
  }, [x, y, slot.x, slot.y, transition]);

  const entering = (arriving || staggerIndex !== null) && !reduced;
  const delay = staggerIndex !== null ? Math.min(staggerIndex * STAGGER_MS, STAGGER_CAP_MS) / 1000 : 0;

  const cancelPress = (): void => {
    if (press.current) {
      clearTimeout(press.current.timer);
      press.current = null;
    }
  };

  return (
    // The outer layer only places the card, so a corrected height snaps or
    // glides with the grid; the inner one plays the entrance (fade, rise, pop)
    // and never drags the card's position along with it.
    <motion.div ref={placeRef} className="absolute top-0 left-0" style={{ width: slot.width, zIndex: raised ? 2 : 1, x, y }}>
      <motion.div
        ref={measureRef}
        initial={entering ? { y: staggerIndex !== null ? ENTRANCE_RISE_PX : 0, opacity: 0, scale: arriving ? HIDDEN_SCALE : 1 } : false}
        animate={{ y: 0, opacity: ghost ? GHOST_OPACITY : 1, scale: 1 }}
        transition={{
          y: { ...TRANSITION.base, delay },
          opacity: { ...(ghost ? TRANSITION.fast : TRANSITION.base), delay: staggerIndex !== null ? delay : 0 },
          scale: TRANSITION.base,
        }}
      >
        <div
          ref={setNodeRef}
          {...(dragDisabled ? {} : listeners)}
          className="touch-pan-y"
          onPointerDown={(event) => {
            if (!dragDisabled) {
              listeners?.onPointerDown?.(event);
            }
            if (!longPressOnly || event.pointerType !== "touch") {
              return;
            }
            const start = { x: event.clientX, y: event.clientY };
            press.current = {
              ...start,
              timer: setTimeout(() => {
                press.current = null;
                guardClick();
                onLongPress(id);
              }, LONG_PRESS_MS),
            };
          }}
          onPointerMove={(event) => {
            const p = press.current;
            if (p && Math.hypot(event.clientX - p.x, event.clientY - p.y) > LONG_PRESS_SLOP) {
              cancelPress();
            }
          }}
          onPointerUp={cancelPress}
          onPointerCancel={cancelPress}
          onContextMenu={(event) => {
            // A touch hold is ours, not the browser's menu.
            if (longPressOnly || !dragDisabled) {
              if ((event.nativeEvent as PointerEvent).pointerType === "touch") {
                event.preventDefault();
              }
            }
          }}
        >
          {children}
        </div>
      </motion.div>
    </motion.div>
  );
}, tilePropsEqual);

/** A card that left the grid, fading where it last stood while the rest closes the gap. */
function LeavingTile({ slot, reduced, onGone, children }: { slot: MasonrySlot; reduced: boolean; onGone: () => void; children: ReactNode }) {
  useEffect(() => {
    if (reduced) {
      onGone();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [reduced]);
  return (
    <motion.div
      aria-hidden
      className="pointer-events-none absolute top-0 left-0"
      style={{ width: slot.width, zIndex: 0 }}
      initial={{ x: slot.x, y: slot.y, opacity: 1, scale: 1 }}
      animate={{ x: slot.x, y: slot.y, opacity: 0, scale: HIDDEN_SCALE }}
      transition={TRANSITION.fast}
      onAnimationComplete={onGone}
    >
      {children}
    </motion.div>
  );
}
