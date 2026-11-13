"use client";

import { useEffect, useRef, useState } from "react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { LoaderCircle, Search, SlidersHorizontal, Sparkles, X } from "lucide-react";
import { cn } from "cn";
import { IconButton } from "@/components/common/icon-button";
import { semanticSearchAvailable, useSession, useSettings, useUi, useUiController } from "@/lib/store";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";
import { querySegments } from "./search-rules";
import { useShellDialogs } from "./shell-dialogs";

const BLUR_SETTLE_MS = 120;

/**
 * The search box: the query as typed, with its `label:`/`is:` operators
 * tinted behind the text so filters read apart from words; clear, the filter
 * sheet, and the semantic toggle (a spinner while ranking). The field stays a
 * plain input, so caret, selection and autocorrect behave normally.
 *
 * "compact" is the phone bar, where the shortcuts beside the field give way
 * to the search controls once it is focused or holds a query.
 */
export function SearchField({
  variant,
  idleControls,
  leading,
}: {
  variant: "wide" | "compact";
  /** The phone pill's drawer button, inside its left edge. */
  leading?: React.ReactNode;
  /** The phone bar's controls while not searching (chat, avatar). */
  idleControls?: React.ReactNode;
}) {
  const ui = useUiController();
  const session = useSession();
  const dialogs = useShellDialogs();
  const query = useUi((s) => s.query);
  const focusRequest = useUi((s) => s.searchFocusRequest);
  const semanticOffered = useUi((s) => s.semantic.available);
  const semanticBusy = useUi((s) => s.semantic.busy);
  const ranking = useSettings((s) => s.semanticRanking);
  const capable = useSettings(semanticSearchAvailable);
  const input = useRef<HTMLInputElement>(null);
  const backdrop = useRef<HTMLDivElement>(null);
  const [focused, setFocused] = useState(false);
  const blurTimer = useRef<number | null>(null);
  const reduced = useReducedMotion();
  const fade = transitionFor(TRANSITION.fast, reduced);

  // Each request (the "/" key, Cmd K, the filter sheet closing) takes focus.
  useEffect(() => {
    if (focusRequest === 0) {
      return;
    }
    const el = input.current;
    if (!el) {
      return;
    }
    el.focus();
    el.setSelectionRange(el.value.length, el.value.length);
  }, [focusRequest]);

  const syncScroll = (): void => {
    if (backdrop.current && input.current) {
      backdrop.current.scrollLeft = input.current.scrollLeft;
    }
  };

  const semantic = capable && semanticOffered;
  const searching = query !== "";
  const showSearchControls = variant === "wide" || focused || searching;

  const controls = (
    <span className="flex shrink-0 items-center">
      <AnimatePresence initial={false}>
        {searching ? (
          <motion.span key="clear" initial={{ opacity: 0, scale: 0.6 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0, scale: 0.6 }} transition={fade}>
            <IconButton
              size="sm"
              label="Clear search"
              icon={<X />}
              onClick={() => {
                ui.clearQuery();
                input.current?.focus();
              }}
            />
          </motion.span>
        ) : null}
      </AnimatePresence>
      <IconButton size="sm" label="Search filters" icon={<SlidersHorizontal />} onClick={() => dialogs.open({ type: "filters" })} />
      {semantic ? (
        <span className="inline-grid">
          <AnimatePresence initial={false}>
            {semanticBusy ? (
              <motion.span
                key="busy"
                role="status"
                aria-label="Ranking by meaning"
                className="inline-flex size-8 items-center justify-center [grid-area:1/1]"
                initial={{ opacity: 0, scale: 0.6 }}
                animate={{ opacity: 1, scale: 1 }}
                exit={{ opacity: 0, scale: 0.6 }}
                transition={fade}
              >
                <LoaderCircle className="size-4 animate-spin text-primary" />
              </motion.span>
            ) : (
              <motion.span key="toggle" className="[grid-area:1/1]" initial={{ opacity: 0, scale: 0.6 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0, scale: 0.6 }} transition={fade}>
                <IconButton
                  size="sm"
                  label={ranking ? "Semantic search on, results ranked by meaning" : "Search by meaning"}
                  active={ranking}
                  icon={<Sparkles className={ranking ? "text-primary" : undefined} />}
                  onClick={() => session.toggleSemanticRanking()}
                />
              </motion.span>
            )}
          </AnimatePresence>
        </span>
      ) : null}
    </span>
  );

  // Focus is tracked on the whole pill, and blur settles a beat later, so a
  // click on a control beside the field lands before the controls swap out.
  const onFocus = (): void => {
    if (blurTimer.current !== null) {
      window.clearTimeout(blurTimer.current);
      blurTimer.current = null;
    }
    setFocused(true);
  };
  const onBlur = (event: React.FocusEvent<HTMLDivElement>): void => {
    if (event.currentTarget.contains(event.relatedTarget as Node | null)) {
      return;
    }
    blurTimer.current = window.setTimeout(() => {
      blurTimer.current = null;
      setFocused(false);
    }, BLUR_SETTLE_MS);
  };

  return (
    <div
      onFocus={onFocus}
      onBlur={onBlur}
      className={cn(
        "flex min-w-0 flex-1 items-center rounded-md border transition-[background-color,border-color,box-shadow] duration-150 ease-standard",
        variant === "wide" ? "h-9" : "h-11",
        focused ? "border-outline-variant bg-surface shadow-raised dark:bg-surface-container-highest" : "border-transparent bg-surface-container-high",
      )}
    >
      {variant === "wide" ? <Search aria-hidden className="ml-3 size-4 shrink-0 text-on-surface-variant" /> : <span className="shrink-0 pl-1">{leading}</span>}
      <div className="relative mx-2 min-w-0 flex-1 self-stretch">
        <div ref={backdrop} aria-hidden className="pointer-events-none absolute inset-0 flex items-center overflow-hidden text-sm whitespace-pre text-transparent">
          {querySegments(query).map((seg, i) => (
            <span
              key={i}
              className={cn(
                seg.kind === "filter" && "rounded-xs bg-secondary-container",
                seg.kind === "excluded" && "rounded-xs bg-excluded",
              )}
            >
              {seg.text}
            </span>
          ))}
        </div>
        <input
          ref={input}
          type="search"
          role="searchbox"
          aria-label="Search notes"
          enterKeyHint="search"
          autoComplete="off"
          spellCheck={false}
          placeholder={variant === "wide" ? "Search" : "Search your notes"}
          value={query}
          onChange={(e) => ui.setQuery(e.target.value)}
          onScroll={syncScroll}
          onSelect={syncScroll}
          className="relative h-full w-full bg-transparent text-sm text-on-surface outline-none placeholder:text-on-surface-variant [&::-webkit-search-cancel-button]:hidden"
        />
      </div>
      <span className="inline-grid shrink-0 pr-1">
        <AnimatePresence initial={false} mode="popLayout">
          {showSearchControls ? (
            <motion.span key="search" className="[grid-area:1/1] flex items-center" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={fade}>
              {controls}
            </motion.span>
          ) : (
            <motion.span key="idle" className="[grid-area:1/1] flex items-center" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={fade}>
              {idleControls}
            </motion.span>
          )}
        </AnimatePresence>
      </span>
    </div>
  );
}
