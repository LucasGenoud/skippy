"use client";

import { useEffect, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { ChevronRight, X } from "lucide-react";
import { AnimatePresence, LayoutGroup, motion, useReducedMotion, type Variants } from "motion/react";
import {
  DndContext,
  KeyboardSensor,
  PointerSensor,
  closestCenter,
  useSensor,
  useSensors,
  type DragEndEvent,
  type DragMoveEvent,
  type DragStartEvent,
} from "@dnd-kit/core";
import { SortableContext, sortableKeyboardCoordinates, useSortable, verticalListSortingStrategy } from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import { cn } from "cn";

import { Button } from "@/components/ui/button";
import { AllDoneBurst } from "@/components/common/all-done-burst";
import { IconButton } from "@/components/common/icon-button";
import type { ReminderValue } from "@/components/common/reminder-picker";
import { MAX_ITEM_DEPTH, type ChecklistItem, type ItemReminder } from "@/lib/models/note";
import { canShiftDepth, removeItem, reopenWhereWritten } from "@/lib/state/checklist-tree";
import { DURATION, TRANSITION, transitionFor } from "@/lib/theme/motion";
import { ChecklistRow, ComposerLeading, Suggestions, fitHeight, type RowActions } from "./checklist-row";
import {
  INDENT_STEP,
  activeTexts,
  blockFor,
  checkedRows,
  completesList,
  dropBlock,
  matchingRows,
  rowKeyAction,
  sameRows,
  uncheckedIds,
} from "./checklist-view";

// The checklist editor (`animated_checklist.dart`):
//
//   rows        drag the handle to reorder (a task moves with its subtasks),
//               sideways to nest; Tab / Shift+Tab nest from the keyboard
//   composer    the last row; its first keystroke creates the item it writes,
//               and the caret never leaves it
//   checked     finished tasks fold away behind "N checked items"
//
// A ticked row is held in place while its checkbox pops, then files itself
// away. Ticking the last open row plays the all-done burst.

const COMPOSER = "__composer__";

export interface ChecklistEditorProps {
  items: readonly ChecklistItem[];
  reminders: Readonly<Record<string, ItemReminder>>;
  readOnly: boolean;
  findQuery: string;
  /** The row find-in-note navigated to. */
  currentMatchId: string | null;
  use24h: boolean;
  /** Bumped to put the caret in the composer (a tap below the list). */
  composerFocus: number;
  suggestionsFor(query: string, exclude: readonly string[]): string[];
  latestText(itemId: string): string | null;
  onToggle(itemId: string): void;
  onItemText(itemId: string, text: string): void;
  onRemove(itemId: string): void;
  onClearChecked(): void;
  onAdd(text: string): string;
  onInsertAfter(afterId: string): string;
  onReplace(items: readonly ChecklistItem[]): void;
  onIndent(itemId: string, delta: number): void;
  onSetReminder(itemId: string, value: ReminderValue | null): void;
}

interface SuggestionState {
  readonly rowId: string;
  readonly text: string;
  /** Rows offer suggestions only once typed in; the composer offers them on focus. */
  readonly typed: boolean;
  readonly hidden: boolean;
}

/** Steps through -1 (nothing highlighted) and 0..count-1, wrapping both ways. */
export function cycleIndex(current: number, step: number, count: number): number {
  const next = current + step;
  if (next < -1) {
    return count - 1;
  }
  return next >= count ? -1 : next;
}

function SortableRow({
  id,
  disabled,
  children,
}: {
  id: string;
  disabled: boolean;
  children(props: { setNode(el: HTMLElement | null): void; style: React.CSSProperties; handle: Record<string, unknown>; dragging: boolean }): ReactNode;
}) {
  const sortable = useSortable({ id, disabled });
  const transform = sortable.transform ? { ...sortable.transform, x: 0, scaleX: 1, scaleY: 1 } : null;
  return children({
    setNode: sortable.setNodeRef,
    style: { transform: CSS.Translate.toString(transform), transition: sortable.transition },
    handle: { ...sortable.attributes, ...sortable.listeners },
    dragging: sortable.isDragging,
  });
}

export function ChecklistEditor(props: ChecklistEditorProps) {
  const { items, readOnly } = props;
  const reduced = useReducedMotion();
  const [composingId, setComposingId] = useState<string | null>(null);
  const [showChecked, setShowChecked] = useState(false);
  const [settling, setSettling] = useState<ReadonlySet<string>>(() => new Set());
  const [celebration, setCelebration] = useState<number | null>(null);
  const [focusedId, setFocusedId] = useState<string | null>(null);
  const [suggestion, setSuggestion] = useState<SuggestionState | null>(null);
  const [activeSuggestion, setActiveSuggestion] = useState(-1);
  const [drag, setDrag] = useState<{ activeId: string; depthDelta: number } | null>(null);
  const [suppressLayout, setSuppressLayout] = useState(false);
  // Which rows each section drew last, so a row crossing over is told apart from a new one.
  const [sections, setSections] = useState<Sections>(() => ({ open: [], checked: [], wasOpen: new Set(), wasChecked: new Set() }));
  const elements = useRef(new Map<string, HTMLTextAreaElement>());
  const composer = useRef<HTMLTextAreaElement>(null);
  const pendingFocus = useRef<string | null>(null);
  // Rows that appear without an entrance: the caret is about to land in them.
  const [noEntrance] = useState(() => new Set<string>());
  const timers = useRef(new Map<string, ReturnType<typeof setTimeout>>());
  const celebrations = useRef(0);

  // A composed item that went away underneath us (undo, another device).
  const composing = composingId === null ? null : (items.find((i) => i.id === composingId) ?? null);
  if (composingId !== null && composing === null) {
    setComposingId(null);
  }

  const checked = useMemo(() => checkedRows(items, settling), [items, settling]);
  const checkedIds = useMemo(() => new Set(checked.map((i) => i.id)), [checked]);
  const order = useMemo(() => uncheckedIds(items, checkedIds, composing?.id ?? null), [items, checkedIds, composing]);
  const byId = useMemo(() => new Map(items.map((i) => [i.id, i])), [items]);
  const carried = drag ? blockFor(order, byId, drag.activeId).slice(1) : [];
  const visibleOrder = carried.length > 0 ? order.filter((id) => !carried.includes(id)) : order;
  const matchIds = useMemo(() => new Set(matchingRows(items, props.findQuery)), [items, props.findQuery]);

  // Find-in-note opens the checked section when the hit is in it.
  const currentInChecked = props.currentMatchId !== null && checkedIds.has(props.currentMatchId);
  if (currentInChecked && !showChecked) {
    setShowChecked(true);
  }

  useEffect(() => {
    const pending = timers.current;
    return () => pending.forEach((t) => clearTimeout(t));
  }, []);

  useEffect(() => {
    if (props.composerFocus > 0 && !readOnly) {
      composer.current?.focus();
    }
  }, [props.composerFocus, readOnly]);

  // The caret moves into a row once that row exists.
  useLayoutEffect(() => {
    const id = pendingFocus.current;
    if (id === null) {
      return;
    }
    const el = id === COMPOSER ? composer.current : elements.current.get(id);
    if (!el) {
      return;
    }
    pendingFocus.current = null;
    el.focus();
    el.setSelectionRange(el.value.length, el.value.length);
  });

  // -- suggestions --------------------------------------------------------------

  let suggestionList: string[] = [];
  if (!readOnly && suggestion && !suggestion.hidden && suggestion.rowId === focusedId) {
    if (focusedId === COMPOSER) {
      suggestionList = props.suggestionsFor(suggestion.text, activeTexts(items, composing?.id ?? null));
    } else if (suggestion.typed && suggestion.text.trim() !== "") {
      suggestionList = props.suggestionsFor(suggestion.text, activeTexts(items, focusedId));
    }
  }

  const typed = (rowId: string, text: string): void => {
    setSuggestion({ rowId, text, typed: true, hidden: false });
    setActiveSuggestion(-1);
  };

  /** Arrow keys and Enter in an open suggestion list. True when the key was taken. */
  const suggestionKey = (rowId: string, event: KeyboardEvent<HTMLTextAreaElement>): boolean => {
    if (suggestionList.length === 0 || suggestion?.rowId !== rowId) {
      return false;
    }
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      const step = event.key === "ArrowDown" ? 1 : -1;
      setActiveSuggestion((i) => cycleIndex(i, step, suggestionList.length));
      return true;
    }
    if (event.key === "Enter" && activeSuggestion >= 0 && activeSuggestion < suggestionList.length) {
      pick(rowId, suggestionList[activeSuggestion] ?? "");
      return true;
    }
    if (event.key === "Escape") {
      setSuggestion({ ...suggestion, hidden: true });
      event.stopPropagation();
      return true;
    }
    return false;
  };

  // -- the composer ---------------------------------------------------------------

  const releaseComposer = (): void => {
    if (composer.current && composer.current.value !== "") {
      composer.current.value = "";
      fitHeight(composer.current);
    }
    setComposingId(null);
  };

  const commitComposing = (): void => {
    const id = composingId;
    if (id === null) {
      return;
    }
    const text = (composer.current?.value ?? "").trim();
    releaseComposer();
    noEntrance.add(id);
    if (text === "") {
      props.onRemove(id);
    } else if (text !== props.latestText(id)) {
      props.onItemText(id, text);
    }
  };

  const composerInput = (value: string): void => {
    typed(COMPOSER, value);
    if (value === "") {
      if (composingId !== null) {
        // Everything typed so far is gone: so is the half-written row.
        const id = composingId;
        setComposingId(null);
        props.onRemove(id);
      }
      return;
    }
    if (composingId === null) {
      setComposingId(props.onAdd(value));
      return;
    }
    props.onItemText(composingId, value);
  };

  const composerKey = (event: KeyboardEvent<HTMLTextAreaElement>): boolean => {
    if (event.nativeEvent.isComposing || suggestionKey(COMPOSER, event)) {
      return !event.nativeEvent.isComposing;
    }
    const value = event.currentTarget.value;
    if (event.key === "Enter" && !event.shiftKey) {
      commitComposing();
      return true;
    }
    if (event.key === "Tab" && composingId !== null) {
      const delta = event.shiftKey ? -1 : 1;
      if (canShiftDepth(items, composingId, delta)) {
        props.onIndent(composingId, delta);
      }
      return true;
    }
    if (event.key === "Backspace" && value === "" && composingId === null) {
      const last = order[order.length - 1];
      if (last) {
        focusNow(last);
        return true;
      }
    }
    return false;
  };

  // -- rows -------------------------------------------------------------------------

  /** Focus a row inside the keypress that asked, so a soft keyboard stays up. */
  const focusNow = (id: string): void => {
    const el = id === COMPOSER ? composer.current : elements.current.get(id);
    if (el) {
      el.focus();
      el.setSelectionRange(el.value.length, el.value.length);
    }
  };

  const rowAbove = (id: string): string => {
    const at = order.indexOf(id);
    if (at >= 0) {
      return at > 0 ? (order[at - 1] ?? COMPOSER) : COMPOSER;
    }
    const inChecked = checked.findIndex((i) => i.id === id);
    return inChecked > 0 ? (checked[inChecked - 1]?.id ?? COMPOSER) : COMPOSER;
  };

  const toggle = (item: ChecklistItem): void => {
    if (completesList(items, item) && !reduced) {
      celebrations.current += 1;
      setCelebration(celebrations.current);
    }
    const timer = timers.current.get(item.id);
    if (timer !== undefined) {
      clearTimeout(timer);
      timers.current.delete(item.id);
    }
    if (!item.done && !reduced) {
      // Held where the finger left it while the checkbox pops, then filed away.
      setSettling((s) => new Set(s).add(item.id));
      timers.current.set(
        item.id,
        setTimeout(() => {
          timers.current.delete(item.id);
          setSettling((s) => {
            const next = new Set(s);
            next.delete(item.id);
            return next;
          });
        }, DURATION.slow),
      );
    } else {
      setSettling((s) => {
        if (!s.has(item.id)) {
          return s;
        }
        const next = new Set(s);
        next.delete(item.id);
        return next;
      });
    }
    props.onToggle(item.id);
  };

  const pick = (rowId: string, text: string): void => {
    const twin = items.find((i) => i.done && i.text === text);
    setActiveSuggestion(-1);
    if (rowId === COMPOSER) {
      if (twin) {
        // Re-adding a checked row reopens it where it is being written.
        const id = composingId;
        releaseComposer();
        const without = id === null ? items : removeItem(items, id);
        props.onReplace(reopenWhereWritten(without, twin.id));
      } else if (composingId !== null) {
        if (composer.current) {
          composer.current.value = text;
        }
        props.onItemText(composingId, text);
        commitComposing();
      } else {
        props.onAdd(text);
      }
      setSuggestion({ rowId: COMPOSER, text: "", typed: false, hidden: false });
      composer.current?.focus();
      return;
    }
    const el = elements.current.get(rowId);
    if (twin) {
      props.onReplace(reopenWhereWritten(items, twin.id, rowId));
      const original = props.latestText(rowId) ?? "";
      if (el) {
        el.value = original;
        el.setSelectionRange(original.length, original.length);
      }
    } else {
      if (el) {
        el.value = text;
        el.setSelectionRange(text.length, text.length);
        fitHeight(el);
      }
      props.onItemText(rowId, text);
    }
    setSuggestion({ rowId, text, typed: false, hidden: false });
  };

  const rowKey = (item: ChecklistItem, event: KeyboardEvent<HTMLTextAreaElement>, value: string): boolean => {
    if (readOnly) {
      return false;
    }
    if (suggestionKey(item.id, event)) {
      return true;
    }
    const action = rowKeyAction({ key: event.key, shiftKey: event.shiftKey, isComposing: event.nativeEvent.isComposing }, value, item.depth);
    switch (action.kind) {
      case "indent":
        if (canShiftDepth(items, item.id, action.delta)) {
          props.onIndent(item.id, action.delta);
        }
        return true;
      case "insertAfter":
        if (!item.done) {
          const id = props.onInsertAfter(item.id);
          pendingFocus.current = id;
          noEntrance.add(id);
        }
        return true;
      case "outdentEmpty":
        props.onIndent(item.id, -1);
        return true;
      case "removeEmpty":
        focusNow(rowAbove(item.id));
        props.onRemove(item.id);
        return true;
      case "none":
        return false;
    }
  };

  // One stable object: rows are memoized and read the latest closures through it.
  const latest = useRef({ toggle, rowKey, pick, typed, props });
  useLayoutEffect(() => {
    latest.current = { toggle, rowKey, pick, typed, props };
  });
  const [actions] = useState<RowActions>(() => ({
    toggle: (item) => latest.current.toggle(item),
    text: (item, value) => {
      latest.current.typed(item.id, value);
      latest.current.props.onItemText(item.id, value);
    },
    key: (item, event, value) => latest.current.rowKey(item, event, value),
    remove: (item) => latest.current.props.onRemove(item.id),
    focus: (id) => {
      setFocusedId((current) => (id === null && current === COMPOSER ? current : id));
      if (id !== null) {
        setSuggestion((s) => (s?.rowId === id ? s : { rowId: id, text: elements.current.get(id)?.value ?? "", typed: false, hidden: false }));
      }
    },
    register: (id, el) => {
      elements.current.set(id, el);
      return () => {
        if (elements.current.get(id) === el) {
          elements.current.delete(id);
        }
      };
    },
    setReminder: (item, value) => latest.current.props.onSetReminder(item.id, value),
    pick: (rowId, text) => latest.current.pick(rowId, text),
    latest: (id) => latest.current.props.latestText(id),
  }));

  // -- drag -----------------------------------------------------------------------

  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 4 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  );

  const onDragStart = (event: DragStartEvent): void => {
    setDrag({ activeId: String(event.active.id), depthDelta: 0 });
  };

  const onDragMove = (event: DragMoveEvent): void => {
    const id = String(event.active.id);
    const depth = byId.get(id)?.depth ?? 0;
    const wanted = Math.round(event.delta.x / INDENT_STEP);
    const delta = Math.max(-depth, Math.min(MAX_ITEM_DEPTH - depth, wanted));
    setDrag((d) => (d && d.depthDelta !== delta ? { ...d, depthDelta: delta } : d));
  };

  const onDragEnd = (event: DragEndEvent): void => {
    const current = drag;
    setDrag(null);
    if (!current) {
      return;
    }
    const next = dropBlock(items, {
      order,
      composingId: composing?.id ?? null,
      checked,
      activeId: current.activeId,
      overId: event.over ? String(event.over.id) : null,
      depthDelta: current.depthDelta,
    });
    // The reorder lands in place: the row is already where it was dropped.
    setSuppressLayout(true);
    requestAnimationFrame(() => setSuppressLayout(false));
    if (!sameRows(next, items)) {
      props.onReplace(next);
    }
  };

  // -- render -----------------------------------------------------------------------

  const rowTransition = transitionFor(TRANSITION.base, reduced);
  const layoutMode = suppressLayout || drag ? false : "position";
  // A row ticked or unticked glides between the list and the checked section
  // as one element (`layoutId`), rather than leaving one and entering the other.
  const shownChecked = showChecked ? checked.map((i) => i.id) : NO_IDS;
  if (!sameIds(sections.open, visibleOrder) || !sameIds(sections.checked, shownChecked)) {
    setSections({ open: visibleOrder, checked: shownChecked, wasOpen: new Set(sections.open), wasChecked: new Set(sections.checked) });
  }
  const openIds = new Set(visibleOrder);
  const checkedShown = new Set(shownChecked);
  const shareId = (id: string): string | undefined => (layoutMode ? `${CHECKLIST_LAYOUT}-${id}` : undefined);

  const row = (item: ChecklistItem, extra: Partial<React.ComponentProps<typeof ChecklistRow>> = {}): ReactNode => (
    <ChecklistRow
      item={item}
      reminder={props.reminders[item.id]}
      readOnly={readOnly}
      match={props.currentMatchId === item.id ? "current" : matchIds.has(item.id) ? "match" : "none"}
      dragging={false}
      depthPreview={0}
      use24h={props.use24h}
      suggestions={focusedId === item.id && suggestionList.length > 0 ? suggestionList : null}
      suggestionQuery={suggestion?.text ?? ""}
      activeSuggestion={activeSuggestion}
      actions={actions}
      {...extra}
    />
  );

  const composerDepth = composing?.depth ?? items[items.length - 1]?.depth ?? 0;

  return (
    <LayoutGroup id={CHECKLIST_LAYOUT}>
      <div className="relative py-1">
        <DndContext
          sensors={sensors}
          collisionDetection={closestCenter}
          onDragStart={onDragStart}
          onDragMove={onDragMove}
          onDragEnd={onDragEnd}
          onDragCancel={() => setDrag(null)}
        >
          <SortableContext items={visibleOrder} strategy={verticalListSortingStrategy}>
            <AnimatePresence initial={false} custom={checkedShown}>
              {visibleOrder.map((id) => {
                const item = byId.get(id);
                if (!item) {
                  return null;
                }
                return (
                  <motion.div
                    key={id}
                    layout={layoutMode}
                    // Only a row crossing sections shares its layout, so a drag reorder never replays as a glide.
                    layoutId={item.done || sections.wasChecked.has(id) ? shareId(id) : undefined}
                    custom={checkedShown}
                    variants={rowVariants(id, drag !== null)}
                    initial={noEntrance.has(id) || sections.wasChecked.has(id) ? false : "enter"}
                    animate="shown"
                    exit="gone"
                    transition={rowTransition}
                  >
                    <SortableRow id={id} disabled={readOnly || item.done}>
                      {(sortable) =>
                        row(item, {
                          dragging: sortable.dragging,
                          depthPreview: sortable.dragging ? (drag?.depthDelta ?? 0) : 0,
                          handleProps: sortable.handle,
                          setSortableNode: sortable.setNode,
                          sortableStyle: sortable.style,
                          carried:
                            sortable.dragging && carried.length > 0 ? (
                              <div className="rounded-b-md bg-surface-container-high shadow-raised">
                                {carried.map((childId) => {
                                  const child = byId.get(childId);
                                  return child ? <div key={childId}>{row(child, { depthPreview: drag?.depthDelta ?? 0 })}</div> : null;
                                })}
                              </div>
                            ) : undefined,
                        })
                      }
                    </SortableRow>
                  </motion.div>
                );
              })}
            </AnimatePresence>
          </SortableContext>
        </DndContext>

        {readOnly ? null : (
          // Glides down for a row added above it instead of jumping a row's height.
          <motion.div layout={layoutMode} transition={rowTransition} style={{ paddingLeft: composerDepth * INDENT_STEP }} className="transition-[padding] duration-150 ease-standard">
            <div className="group/row relative flex min-h-11 items-start rounded-md focus-within:bg-primary/[0.035]">
              <span className="w-6 shrink-0" />
              <ComposerLeading
                composing={composing !== null}
                onTick={() => {
                  const item = composing;
                  commitComposing();
                  if (item) {
                    toggle(item);
                  }
                }}
              />
              <div className="flex min-w-0 flex-1 py-2.5">
                <textarea
                  ref={composer}
                  rows={1}
                  aria-label="List item"
                  placeholder="List item"
                  autoCapitalize="sentences"
                  enterKeyHint="next"
                  className="block w-full resize-none overflow-hidden bg-transparent text-base leading-6 text-on-surface outline-none placeholder:text-on-surface-variant/70"
                  onInput={(e) => {
                    fitHeight(e.currentTarget);
                    composerInput(e.currentTarget.value);
                  }}
                  onKeyDown={(e) => {
                    if (composerKey(e)) {
                      e.preventDefault();
                    }
                  }}
                  onFocus={() => {
                    setFocusedId(COMPOSER);
                    setSuggestion({ rowId: COMPOSER, text: composer.current?.value ?? "", typed: false, hidden: false });
                  }}
                  onBlur={() => {
                    setFocusedId((id) => (id === COMPOSER ? null : id));
                    commitComposing();
                  }}
                />
              </div>
              <span
                className={cn(
                  "flex h-11 items-center pr-1 transition-opacity duration-150 ease-standard",
                  focusedId === COMPOSER ? "opacity-100" : "pointer-events-none opacity-0",
                )}
              >
                <IconButton
                  size="sm"
                  label={composing ? "Remove item" : "Close keyboard"}
                  icon={<X />}
                  onPointerDown={(e) => e.preventDefault()}
                  onClick={() => {
                    if (composing) {
                      const id = composing.id;
                      releaseComposer();
                      props.onRemove(id);
                    } else {
                      composer.current?.blur();
                    }
                  }}
                />
              </span>
              {focusedId === COMPOSER && suggestionList.length > 0 ? (
                <Suggestions suggestions={suggestionList} query={suggestion?.text ?? ""} active={activeSuggestion} onPick={(t) => pick(COMPOSER, t)} />
              ) : null}
            </div>
          </motion.div>
        )}

        <AnimatePresence initial={false} custom={openIds}>
          {checked.length > 0 ? (
            <motion.div
              key="checked-header"
              layout={layoutMode}
              initial={{ opacity: 0, height: 0 }}
              animate={{ opacity: 1, height: "auto" }}
              exit={{ opacity: 0, height: 0 }}
              transition={rowTransition}
              className="overflow-hidden"
            >
              <div className="flex items-center gap-2 py-1">
                <button
                  type="button"
                  aria-expanded={showChecked}
                  onClick={() => setShowChecked((v) => !v)}
                  className="flex min-h-9 flex-1 items-center gap-2 rounded-md px-1 text-left text-xs text-on-surface-variant transition-colors duration-150 ease-standard outline-none hover:bg-hover active:bg-pressed focus-visible:ring-[3px] focus-visible:ring-ring/50"
                >
                  <ChevronRight aria-hidden className={cn("size-5 transition-transform duration-150 ease-standard", showChecked && "rotate-90")} />
                  {checked.length} checked {checked.length === 1 ? "item" : "items"}
                </button>
                {readOnly ? null : (
                  <Button variant="ghost" size="sm" onClick={props.onClearChecked}>
                    Clear checked
                  </Button>
                )}
              </div>
            </motion.div>
          ) : null}
          {showChecked
            ? checked.map((item) => (
                <motion.div
                  key={`checked-${item.id}`}
                  layout={layoutMode}
                  layoutId={shareId(item.id)}
                  custom={openIds}
                  variants={checkedVariants(item.id)}
                  // Opening the section unfolds its rows; a row just ticked arrives from where it was.
                  initial={sections.wasOpen.has(item.id) ? false : "enter"}
                  animate="shown"
                  exit="gone"
                  transition={rowTransition}
                >
                  {row(item)}
                </motion.div>
              ))
            : null}
        </AnimatePresence>

        {celebration !== null ? (
          <div className="pointer-events-none absolute inset-0">
            <AllDoneBurst key={celebration} onDone={() => setCelebration(null)} />
          </div>
        ) : null}
      </div>
    </LayoutGroup>
  );
}

const CHECKLIST_LAYOUT = "checklist-row";
const NO_IDS: readonly string[] = [];
const INSTANT_OUT = { opacity: 0, transition: { duration: 0 } };

interface Sections {
  readonly open: readonly string[];
  readonly checked: readonly string[];
  readonly wasOpen: ReadonlySet<string>;
  readonly wasChecked: ReadonlySet<string>;
}

function sameIds(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((id, i) => id === b[i]);
}

/**
 * An open row: slides in when new, folds away when removed, and leaves at
 * once when it is crossing to the checked section, whose copy takes over.
 */
function rowVariants(id: string, dragging: boolean): Variants {
  return {
    enter: { opacity: 0, x: 20 },
    shown: { opacity: 1, x: 0 },
    gone: (elsewhere: ReadonlySet<string> | undefined) => (dragging || elsewhere?.has(id) ? INSTANT_OUT : { opacity: 0, height: 0 }),
  };
}

/** A checked row: unfolds with its section, and hands over to the list when unticked. */
function checkedVariants(id: string): Variants {
  return {
    enter: { opacity: 0, height: 0 },
    shown: { opacity: 1, height: "auto" },
    gone: (elsewhere: ReadonlySet<string> | undefined) => (elsewhere?.has(id) ? INSTANT_OUT : { opacity: 0, height: 0 }),
  };
}
