"use client";

import { useEffect, useRef, type KeyboardEvent } from "react";
import { Plus, X } from "lucide-react";
import { AnimatePresence, motion } from "motion/react";
import { cn } from "cn";

import type { ChecklistItem } from "@/lib/models/note";
import { shiftDepth } from "@/lib/state/checklist-tree";
import { TRANSITION } from "@/lib/theme/motion";
import { newId } from "@/lib/util/id";

/** Indent per nesting level in the composer. */
const DEPTH_INDENT = 24;

/**
 * The quick add's inline checklist, on a local list of rows. Enter adds a row
 * after this one, Backspace on an empty row removes it, Tab and Shift+Tab
 * nest. A small sibling of the editor's checklist: there is no history or
 * reminder here because there is no note yet.
 */
export function QuickAddChecklist({
  items,
  onChange,
  autoFocus,
}: {
  items: readonly ChecklistItem[];
  onChange: (items: readonly ChecklistItem[]) => void;
  /** Focus the last row (or the new-row field) as it appears. */
  autoFocus: boolean;
}) {
  const inputs = useRef(new Map<string, HTMLInputElement>());
  const newRow = useRef<HTMLInputElement | null>(null);
  const focusNext = useRef<string | null>(null);

  useEffect(() => {
    if (autoFocus) {
      newRow.current?.focus();
    }
    // Only as it appears.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    const id = focusNext.current;
    if (id) {
      focusNext.current = null;
      if (id === "new") {
        newRow.current?.focus();
      } else {
        inputs.current.get(id)?.focus();
      }
    }
  });

  const update = (id: string, change: Partial<ChecklistItem>): void => onChange(items.map((i) => (i.id === id ? { ...i, ...change } : i)));

  const insertAfter = (id: string): void => {
    const index = items.findIndex((i) => i.id === id);
    const depth = items[index]?.depth ?? 0;
    const item: ChecklistItem = { id: newId(), text: "", done: false, depth };
    onChange([...items.slice(0, index + 1), item, ...items.slice(index + 1)]);
    focusNext.current = item.id;
  };

  const remove = (id: string): void => {
    const index = items.findIndex((i) => i.id === id);
    onChange(items.filter((i) => i.id !== id));
    focusNext.current = items[index - 1]?.id ?? "new";
  };

  const onRowKey = (item: ChecklistItem, event: KeyboardEvent<HTMLInputElement>): void => {
    if (event.key === "Enter") {
      event.preventDefault();
      insertAfter(item.id);
    } else if (event.key === "Backspace" && item.text === "") {
      event.preventDefault();
      remove(item.id);
    } else if (event.key === "Tab") {
      const next = shiftDepth(items, item.id, event.shiftKey ? -1 : 1);
      if (next !== items) {
        event.preventDefault();
        onChange(next);
      }
    }
  };

  const add = (text: string): void => {
    const item: ChecklistItem = { id: newId(), text, done: false, depth: 0 };
    onChange([...items, item]);
    focusNext.current = item.id;
  };

  return (
    <div className="flex flex-col py-1">
      <AnimatePresence initial={false}>
        {items.map((item) => (
          <motion.div
            key={item.id}
            initial={{ opacity: 0, height: 0 }}
            animate={{ opacity: 1, height: "auto" }}
            exit={{ opacity: 0, height: 0 }}
            transition={TRANSITION.base}
            className="overflow-hidden"
          >
            <div className="group/row flex items-center gap-2.5 py-1" style={{ paddingLeft: item.depth * DEPTH_INDENT }}>
              <button
                type="button"
                role="checkbox"
                aria-checked={item.done}
                aria-label={item.done ? "Mark not done" : "Mark done"}
                onClick={() => update(item.id, { done: !item.done })}
                className={cn(
                  "inline-flex size-[18px] shrink-0 items-center justify-center rounded-check border transition-colors duration-150 ease-standard outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50",
                  item.done ? "border-primary-container bg-primary-container text-on-primary-container" : "border-outline hover:bg-hover",
                )}
              >
                {item.done ? (
                  <svg viewBox="0 0 16 16" aria-hidden className="size-3">
                    <path d="M3.5 8.5l3 3 6-7" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />
                  </svg>
                ) : null}
              </button>
              <input
                ref={(element) => {
                  if (element) {
                    inputs.current.set(item.id, element);
                  } else {
                    inputs.current.delete(item.id);
                  }
                }}
                value={item.text}
                aria-label="List item"
                onChange={(event) => update(item.id, { text: event.target.value })}
                onKeyDown={(event) => onRowKey(item, event)}
                className={cn("min-w-0 flex-1 bg-transparent text-sm outline-none", item.done && "text-on-surface-variant line-through")}
              />
              <button
                type="button"
                aria-label="Remove item"
                onClick={() => remove(item.id)}
                className="inline-flex size-6 items-center justify-center rounded-md text-on-surface-variant opacity-0 transition-opacity duration-150 ease-standard outline-none group-focus-within/row:opacity-100 group-hover/row:opacity-100 hover:bg-hover focus-visible:opacity-100"
              >
                <X aria-hidden className="size-4" />
              </button>
            </div>
          </motion.div>
        ))}
      </AnimatePresence>
      <label className="flex items-center gap-2.5 py-1 text-on-surface-variant">
        <Plus aria-hidden className="size-[18px] shrink-0" />
        <input
          ref={newRow}
          placeholder="List item"
          aria-label="New list item"
          className="min-w-0 flex-1 bg-transparent text-sm text-on-surface outline-none placeholder:text-on-surface-variant"
          onChange={(event) => {
            const text = event.target.value;
            if (text) {
              event.target.value = "";
              add(text);
            }
          }}
          onKeyDown={(event) => {
            if (event.key === "Backspace" && event.currentTarget.value === "" && items.length > 0) {
              event.preventDefault();
              focusNext.current = items[items.length - 1]!.id;
              onChange([...items]);
            }
          }}
        />
      </label>
    </div>
  );
}
