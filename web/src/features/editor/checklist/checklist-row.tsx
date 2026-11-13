"use client";

import { memo, useEffect, useLayoutEffect, useRef, useState, type CSSProperties, type KeyboardEvent, type ReactNode } from "react";
import { AlarmClock, AlarmClockCheck, GripVertical, History, Plus, X } from "lucide-react";
import { useAnimate, useReducedMotion } from "motion/react";
import { cn } from "cn";

import { Checkbox } from "@/components/ui/checkbox";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { IconButton } from "@/components/common/icon-button";
import { ReminderChip } from "@/components/common/reminder-chip";
import { ReminderPicker, type ReminderValue } from "@/components/common/reminder-picker";
import type { ChecklistItem, ItemReminder } from "@/lib/models/note";
import { DURATION, EASE } from "@/lib/theme/motion";
import { INDENT_STEP } from "./checklist-view";

// One checklist row and the composer that writes the next one
// (`animated_checklist.dart`, `checklist_row_input.dart`). The text field is
// uncontrolled: the browser owns it while it has focus, and an edit from
// elsewhere (undo, another device) lands only once the caret has left, so a
// keyboard that deletes and retypes a word is never overwritten mid-burst.

/** Everything a row does goes through the list, via one stable object. */
export interface RowActions {
  toggle(item: ChecklistItem): void;
  text(item: ChecklistItem, value: string): void;
  key(item: ChecklistItem, event: KeyboardEvent<HTMLTextAreaElement>, value: string): boolean;
  remove(item: ChecklistItem): void;
  focus(itemId: string | null): void;
  register(itemId: string, element: HTMLTextAreaElement): () => void;
  setReminder(item: ChecklistItem, value: ReminderValue | null): void;
  pick(rowId: string, suggestion: string): void;
  /** The row's text as the store holds it now (props can lag a throttle behind). */
  latest(itemId: string): string | null;
}

const CONTROL_FADE =
  "transition-opacity duration-150 ease-standard opacity-0 group-hover/row:opacity-100 group-focus-within/row:opacity-100 [@media(hover:none)]:opacity-100";

/** Grows a one-line field with its wrapped text. */
export function fitHeight(element: HTMLTextAreaElement | null): void {
  if (!element) {
    return;
  }
  element.style.height = "auto";
  element.style.height = `${element.scrollHeight}px`;
}

export function Suggestions({
  suggestions,
  query,
  active,
  onPick,
}: {
  suggestions: readonly string[];
  query: string;
  active: number;
  onPick(text: string): void;
}) {
  const q = query.trim().toLowerCase();
  return (
    <ul
      role="listbox"
      aria-label="Suggestions"
      className="absolute top-full left-14 z-30 max-h-72 w-[min(300px,calc(100%-3.5rem))] overflow-y-auto rounded-lg border border-outline-variant bg-popover py-1 shadow-popover animate-in fade-in-0 zoom-in-95 duration-150"
    >
      {suggestions.map((text, i) => {
        const at = q ? text.toLowerCase().indexOf(q) : -1;
        return (
          <li key={text}>
            <button
              type="button"
              role="option"
              aria-selected={i === active}
              onPointerDown={(e) => e.preventDefault()}
              onClick={() => onPick(text)}
              className={cn(
                "flex w-full items-center gap-3 px-3.5 py-2 text-left text-sm text-on-surface transition-colors duration-150 ease-standard",
                i === active ? "bg-hover" : "hover:bg-hover active:bg-pressed",
              )}
            >
              <History aria-hidden className="size-4 shrink-0 text-on-surface-variant" />
              <span className="truncate">
                {at < 0 ? (
                  text
                ) : (
                  <>
                    {text.slice(0, at)}
                    <b className="font-bold">{text.slice(at, at + q.length)}</b>
                    {text.slice(at + q.length)}
                  </>
                )}
              </span>
            </button>
          </li>
        );
      })}
    </ul>
  );
}

/** The checkbox, with a small pop fired from the tap itself. */
function PopCheckbox({ checked, disabled, onToggle, label }: { checked: boolean; disabled?: boolean; onToggle(): void; label: string }) {
  const [scope, animate] = useAnimate<HTMLSpanElement>();
  const reduced = useReducedMotion();
  return (
    <span ref={scope} className="inline-flex size-6 items-center justify-center">
      <Checkbox
        checked={checked}
        disabled={disabled}
        aria-label={label}
        onCheckedChange={() => {
          if (!reduced && scope.current) {
            void animate(scope.current, { scale: [1, 1.35, 1] }, { duration: DURATION.slow / 1000, ease: [...EASE.back] });
          }
          onToggle();
        }}
      />
    </span>
  );
}

function ReminderButton({
  reminder,
  use24h,
  onChange,
  children,
}: {
  reminder: ItemReminder | undefined;
  use24h: boolean;
  onChange(value: ReminderValue | null): void;
  children: ReactNode;
}) {
  const [open, setOpen] = useState(false);
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>{children}</PopoverTrigger>
      <PopoverContent className="w-[360px]" align="end">
        <ReminderPicker
          value={reminder ? { at: reminder.at, repeat: reminder.repeat ?? undefined } : null}
          use24h={use24h}
          onChange={(value) => {
            onChange(value);
            setOpen(false);
          }}
        />
      </PopoverContent>
    </Popover>
  );
}

export interface ChecklistRowProps {
  item: ChecklistItem;
  reminder: ItemReminder | undefined;
  readOnly: boolean;
  match: "none" | "match" | "current";
  dragging: boolean;
  /** Extra indent while the handle is dragged sideways. */
  depthPreview: number;
  use24h: boolean;
  suggestions: readonly string[] | null;
  suggestionQuery: string;
  activeSuggestion: number;
  actions: RowActions;
  handleProps?: Record<string, unknown>;
  setSortableNode?(element: HTMLElement | null): void;
  sortableStyle?: CSSProperties;
  /** Nested rows travelling with this one during a drag. */
  carried?: ReactNode;
}

export const ChecklistRow = memo(function ChecklistRow(props: ChecklistRowProps) {
  const {
    item,
    reminder,
    readOnly,
    actions,
    match,
    dragging,
    depthPreview,
    use24h,
    suggestions,
    suggestionQuery,
    activeSuggestion,
    handleProps,
    setSortableNode,
    sortableStyle,
    carried,
  } = props;
  const field = useRef<HTMLTextAreaElement>(null);
  const canRemind = !readOnly && !item.done;

  // An edit made elsewhere reaches the field only while the caret is away.
  useEffect(() => {
    const el = field.current;
    if (el && document.activeElement !== el && el.value !== item.text) {
      el.value = item.text;
      fitHeight(el);
    }
  }, [item.text]);

  useLayoutEffect(() => fitHeight(field.current), []);

  useEffect(() => {
    if (match === "current") {
      field.current?.scrollIntoView({ block: "nearest", behavior: "smooth" });
    }
  }, [match]);

  const depth = item.depth + depthPreview;
  return (
    <div ref={setSortableNode} style={sortableStyle} className={cn("relative", dragging && "z-20")}>
      <div
        style={{ paddingLeft: Math.max(0, depth) * INDENT_STEP }}
        className="transition-[padding] duration-150 ease-standard"
      >
        <div
          data-row={item.id}
          className={cn(
            "group/row relative flex min-h-11 items-start rounded-md transition-[background-color,box-shadow] duration-150 ease-standard",
            dragging
              ? "bg-surface-container-high shadow-raised"
              : match === "current"
                ? "bg-primary-container/60"
                : match === "match"
                  ? "bg-primary-container/25"
                  : !readOnly && "hover:bg-on-surface/4 focus-within:bg-primary/[0.035]",
          )}
        >
          <span
            {...handleProps}
            aria-label="Drag to reorder"
            className={cn(
              "flex h-11 w-6 shrink-0 cursor-grab touch-none items-center justify-center text-on-surface-variant/70 active:cursor-grabbing",
              item.done || readOnly ? "pointer-events-none opacity-0" : CONTROL_FADE,
              dragging && "opacity-100",
            )}
          >
            <GripVertical aria-hidden className="size-4" />
          </span>
          <span className="flex h-11 w-9 shrink-0 items-center justify-center">
            <PopCheckbox checked={item.done} disabled={readOnly} label={item.text || "Item"} onToggle={() => actions.toggle(item)} />
          </span>
          <div className="flex min-w-0 flex-1 flex-col py-2.5">
            <textarea
              ref={(el) => {
                field.current = el;
                return el ? actions.register(item.id, el) : undefined;
              }}
              rows={1}
              defaultValue={item.text}
              readOnly={readOnly}
              aria-label="List item"
              autoCapitalize="sentences"
              enterKeyHint="next"
              className={cn(
                "block w-full resize-none overflow-hidden bg-transparent text-base leading-6 text-on-surface outline-none",
                item.done && "text-on-surface-variant line-through",
              )}
              onInput={(e) => {
                fitHeight(e.currentTarget);
                actions.text(item, e.currentTarget.value);
              }}
              onKeyDown={(e) => {
                if (actions.key(item, e, e.currentTarget.value)) {
                  e.preventDefault();
                }
              }}
              onFocus={() => actions.focus(item.id)}
              onBlur={(e) => {
                actions.focus(null);
                const latest = actions.latest(item.id);
                if (latest !== null && e.currentTarget.value !== latest) {
                  e.currentTarget.value = latest;
                  fitHeight(e.currentTarget);
                }
              }}
            />
            {reminder ? (
              <span className="pt-1.5">
                {canRemind ? (
                  <ReminderButton reminder={reminder} use24h={use24h} onChange={(v) => actions.setReminder(item, v)}>
                    <ReminderChip at={reminder.at} repeat={reminder.repeat} onClick={() => undefined} />
                  </ReminderButton>
                ) : (
                  <ReminderChip at={reminder.at} repeat={reminder.repeat} />
                )}
              </span>
            ) : null}
          </div>
          {canRemind ? (
            <span className={cn("flex h-11 items-center", reminder ? "" : CONTROL_FADE)}>
              <ReminderButton reminder={reminder} use24h={use24h} onChange={(v) => actions.setReminder(item, v)}>
                <IconButton
                  size="sm"
                  label={reminder ? "Edit reminder" : "Remind me about this item"}
                  icon={reminder ? <AlarmClockCheck className="text-primary" /> : <AlarmClock />}
                />
              </ReminderButton>
            </span>
          ) : null}
          {readOnly ? null : (
            <span className={cn("flex h-11 items-center pr-1", CONTROL_FADE)}>
              <IconButton size="sm" label="Remove item" icon={<X />} onClick={() => actions.remove(item)} />
            </span>
          )}
          {suggestions && suggestions.length > 0 ? (
            <Suggestions
              suggestions={suggestions}
              query={suggestionQuery}
              active={activeSuggestion}
              onPick={(text) => actions.pick(item.id, text)}
            />
          ) : null}
        </div>
      </div>
      {carried}
    </div>
  );
});

/** The "+" that gives way to a checkbox in one slot once the composer has text. */
export function ComposerLeading({ composing, onTick }: { composing: boolean; onTick(): void }) {
  return (
    <span className="relative flex h-11 w-9 shrink-0 items-center justify-center" data-testid="composer-leading">
      <Plus
        aria-hidden
        className={cn(
          "absolute size-5 text-on-surface-variant transition-[opacity,scale] duration-150 ease-standard",
          composing ? "scale-70 opacity-0" : "scale-100 opacity-100",
        )}
      />
      <span
        className={cn(
          "absolute transition-[opacity,scale] duration-240 ease-back",
          composing ? "scale-100 opacity-100 delay-75" : "pointer-events-none scale-60 opacity-0",
        )}
      >
        <PopCheckbox checked={false} label="Check off" disabled={!composing} onToggle={onTick} />
      </span>
    </span>
  );
}
