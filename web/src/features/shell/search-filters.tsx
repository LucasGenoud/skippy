"use client";

import { useRef } from "react";
import { motion, useReducedMotion } from "motion/react";
import { Ban, BookmarkPlus, Check } from "lucide-react";
import { cn } from "cn";
import { CrossFade } from "@/components/common/reveal";
import { SectionLabel } from "@/components/common/section-label";
import { Button } from "@/components/ui/button";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { useLabels, useUi, useUiController } from "@/lib/store";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";
import { cycleSearchFilter } from "@/lib/util/search-query";
import { AdaptiveSurface } from "./adaptive-surface";
import { chipHint, chipState, chipText, filterGroups } from "./search-rules";
import { useShellDialogs } from "./shell-dialogs";

/**
 * The search box's cheat sheet: every operator, tapped on and off
 * (`SearchFiltersSheet`). It edits the live query and stays open, since a
 * search usually takes more than one filter. A tap cycles a chip through
 * match, exclude, clear; the chip's text is the token it adds, which is what
 * teaches the syntax. The footer saves the search as a smart view.
 */
export function SearchFiltersSurface({ open, onOpenChange }: { open: boolean; onOpenChange(open: boolean): void }) {
  const ui = useUiController();
  const dialogs = useShellDialogs();
  const query = useUi((s) => s.query);
  const labels = useLabels();
  const saving = useRef(false);
  const groups = filterGroups(labels.map((l) => l.name));
  const trimmed = query.trim();

  const close = (next: boolean): void => {
    onOpenChange(next);
    if (!next && !saving.current && ui.state.query.trim() !== "") {
      // Back to the box they were building, caret at the end.
      ui.requestSearchFocus();
    }
  };

  const save = (): void => {
    saving.current = true;
    onOpenChange(false);
    dialogs.open({ type: "savedView", savedViewId: null, initialQuery: trimmed, afterSave: "open" });
  };

  return (
    <AdaptiveSurface
      open={open}
      onOpenChange={close}
      title="Search filters"
      description="Tap to match, again to exclude, again to clear. Every filter narrows the search further, and typing words narrows it more."
      className="sm:max-w-[480px]"
      footer={
        <div className="flex w-full min-w-0 items-center gap-3">
          <span className={cn("min-w-0 flex-1 truncate text-xs text-on-surface-variant", trimmed !== "" && "font-mono")}>
            {trimmed === "" ? "Build a search to save it as a smart view" : trimmed}
          </span>
          <Button variant="secondary" size="sm" disabled={trimmed === ""} onClick={save}>
            <BookmarkPlus />
            Save as smart view
          </Button>
        </div>
      }
    >
      <div className="flex flex-col gap-4 py-1">
        {groups.map((group) => (
          <div key={group.title} className="flex flex-col gap-2">
            <SectionLabel className="px-0">{group.title}</SectionLabel>
            <div className="flex flex-wrap gap-2">
              {group.tokens.map((token) => (
                <FilterChip key={token} token={token} query={query} onCycle={() => ui.setQuery(cycleSearchFilter(ui.state.query, token))} />
              ))}
            </div>
          </div>
        ))}
      </div>
    </AdaptiveSurface>
  );
}

function FilterChip({ token, query, onCycle }: { token: string; query: string; onCycle(): void }) {
  const state = chipState(query, token);
  const reduced = useReducedMotion();
  const text = chipText(state, token);
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <motion.button
          layout="size"
          transition={transitionFor(TRANSITION.fast, reduced)}
          type="button"
          onClick={onCycle}
          aria-pressed={state !== "off"}
          aria-label={state === "excluding" ? `Excluding ${token}` : token}
          className={cn(
            "inline-flex h-7 items-center gap-1.5 rounded-md border px-2.5 font-mono text-xs transition-colors duration-150 ease-standard outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50",
            state === "off" && "border-outline-variant text-on-surface hover:bg-hover",
            state === "matching" && "border-transparent bg-secondary-container text-on-secondary-container",
            state === "excluding" && "border-transparent bg-excluded text-on-surface",
          )}
        >
          {state === "matching" ? <Check aria-hidden className="size-3.5" /> : null}
          {state === "excluding" ? <Ban aria-hidden className="size-3.5 text-error" /> : null}
          <CrossFade stateKey={text}>{text}</CrossFade>
        </motion.button>
      </TooltipTrigger>
      <TooltipContent>{chipHint(state, token)}</TooltipContent>
    </Tooltip>
  );
}
