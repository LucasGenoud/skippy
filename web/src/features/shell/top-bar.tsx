"use client";

import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { Menu, MessagesSquare, Settings } from "lucide-react";
import { IconButton } from "@/components/common/icon-button";
import { TooltipProvider } from "@/components/ui/tooltip";
import { navigate } from "@/lib/router";
import { useActiveCollection, useNotesSelector, useSavedViews, useUi, useViewSelection } from "@/lib/store";
import { DURATION, EASE, TRANSITION, transitionFor } from "@/lib/theme/motion";
import { useTitledBar } from "./responsive";
import { SearchField } from "./search-field";
import { SelectionBar } from "./selection-bar";
import { useChatAvailable } from "./shell-actions";
import { LayoutToggle, SortMenu, ThemeToggle, UserMenu } from "./top-bar-controls";
import { viewTitle } from "./view-rules";

/** The bar's own height (`HomeTopBar.barHeight`). */
export const TOP_BAR_PX = 60;

/**
 * The band across the top (`HomeTopBar`): the view's name and a compact
 * search while browsing, bulk actions while notes are selected. Below 650px
 * the browsing bar collapses into one search pill.
 */
export function TopBar({ onMenu }: { onMenu(): void }) {
  const selecting = useUi((s) => s.selectedIds.length > 0);
  const titled = useTitledBar();
  const reduced = useReducedMotion();
  const variant = titled ? "wide" : "compact";

  return (
    <header className="relative z-20 shrink-0 border-b border-hairline bg-surface pt-[env(safe-area-inset-top)]">
      <TooltipProvider>
        <div className="relative flex items-center px-3" style={{ height: TOP_BAR_PX }}>
          <AnimatePresence initial={false} mode="popLayout">
            {selecting ? (
              <motion.div key="selecting" className="flex h-full min-w-0 flex-1 items-center" exit={{ opacity: 0, transition: transitionFor(TRANSITION.fast, reduced) }}>
                <SelectionBar variant={variant} />
              </motion.div>
            ) : (
              <motion.div
                key="browsing"
                className="flex h-full min-w-0 flex-1 items-center"
                initial={{ opacity: 0 }}
                animate={{ opacity: 1, transition: reduced ? { duration: 0 } : { duration: (DURATION.base * 0.6) / 1000, delay: (DURATION.base * 0.4) / 1000, ease: EASE.standard } }}
                exit={{ opacity: 0, transition: transitionFor(TRANSITION.fast, reduced) }}
              >
                {titled ? <WideBar onMenu={onMenu} /> : <CompactBar onMenu={onMenu} />}
              </motion.div>
            )}
          </AnimatePresence>
        </div>
      </TooltipProvider>
    </header>
  );
}

function useViewTitle(): string {
  const selection = useViewSelection();
  const collection = useActiveCollection();
  const views = useSavedViews();
  const label = useNotesSelector((s) => (selection.labelId ? (s.labels.find((l) => l.id === selection.labelId)?.name ?? null) : null), Object.is, [selection.labelId]);
  return viewTitle(selection, {
    collection: collection?.name ?? null,
    label,
    smartView: views.find((v) => v.id === selection.savedViewId)?.name ?? null,
  });
}

function WideBar({ onMenu }: { onMenu(): void }) {
  const title = useViewTitle();
  const chat = useChatAvailable();
  const reduced = useReducedMotion();
  return (
    <>
      <IconButton label="Main menu" icon={<Menu />} onClick={onMenu} />
      <div className="ml-2 grid min-w-0 flex-1">
        <AnimatePresence initial={false}>
          <motion.h1
            key={title}
            className="truncate text-base font-semibold tracking-[-0.01em] text-on-surface [grid-area:1/1]"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={transitionFor(TRANSITION.base, reduced)}
          >
            {title}
          </motion.h1>
        </AnimatePresence>
      </div>
      <div className="ml-4 flex min-w-0 flex-[2] justify-end">
        <div className="w-full max-w-[560px]">
          <SearchField variant="wide" />
        </div>
      </div>
      <div className="ml-2 flex shrink-0 items-center gap-0.5">
        <AnimatePresence initial={false}>
          {chat ? (
            <motion.span key="chat" initial={{ opacity: 0, scale: 0.6 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0, scale: 0.6 }} transition={transitionFor(TRANSITION.fast, reduced)}>
              <IconButton label="Chat with your notes" icon={<MessagesSquare />} onClick={() => navigate({ name: "chat" })} />
            </motion.span>
          ) : null}
        </AnimatePresence>
        <LayoutToggle />
        <SortMenu />
        <ThemeToggle />
        <IconButton label="Settings" icon={<Settings />} onClick={() => navigate({ name: "settings", page: null })} />
        <span className="ml-1">
          <UserMenu variant="wide" />
        </span>
      </div>
    </>
  );
}

/** Phone: the whole bar is one search pill holding the drawer button, the field, chat and the avatar. */
function CompactBar({ onMenu }: { onMenu(): void }) {
  const chat = useChatAvailable();
  const reduced = useReducedMotion();
  return (
    <div className="flex min-w-0 flex-1 items-center">
      <SearchField
        variant="compact"
        leading={<IconButton size="sm" label="Main menu" icon={<Menu />} onClick={onMenu} />}
        idleControls={
          <span className="flex items-center gap-0.5 pr-0.5">
            <AnimatePresence initial={false}>
              {chat ? (
                <motion.span key="chat" className="inline-flex" initial={{ opacity: 0, scale: 0.6 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0, scale: 0.6 }} transition={transitionFor(TRANSITION.fast, reduced)}>
                  <IconButton size="sm" label="Chat with your notes" icon={<MessagesSquare />} onClick={() => navigate({ name: "chat" })} />
                </motion.span>
              ) : null}
            </AnimatePresence>
            <UserMenu variant="compact" />
          </span>
        }
      />
    </div>
  );
}
