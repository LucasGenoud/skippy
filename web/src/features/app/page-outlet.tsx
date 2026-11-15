"use client";

import { Suspense, useEffect, useRef, useState, type ReactNode } from "react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { pageVariants } from "@/lib/theme/motion";

// Full pages (settings, workspace settings and statistics, chat) pushed over
// the home view, as `MaterialPageRoute` pushes them: the page slides a short
// way in while fading, and leaves the same way when closed, by its back
// button or the browser's. The home view stays mounted underneath, so its
// scroll, search and selection are where they were on the way back.

/** The page the route asks for: [key] names one page instance. */
export interface PageEntry {
  readonly key: string;
  readonly node: ReactNode;
}

/** Above the home view and its chrome, below dialogs, menus and toasts. */
const PAGE_LAYER = "fixed inset-0 z-40 overflow-hidden";

/** A dialog, menu or popover is up over the page: its own Escape wins. */
function layerAbove(): boolean {
  return document.querySelector('[role="dialog"][data-state="open"], [role="alertdialog"][data-state="open"], [data-radix-popper-content-wrapper]') !== null;
}

function isTextField(target: EventTarget | null): boolean {
  return target instanceof HTMLElement && (target.isContentEditable || target.closest("input, textarea, select") !== null);
}

/**
 * Escape goes back from a page, as its Back button does (a phone settings
 * page to its index, anything else to the notes), unless a field, a dialog
 * or a menu has a use for the key.
 */
function useEscapeGoesBack(layer: React.RefObject<HTMLDivElement | null>, open: boolean): void {
  useEffect(() => {
    if (!open) {
      return;
    }
    const onKey = (event: KeyboardEvent): void => {
      if (event.key !== "Escape" || event.defaultPrevented || isTextField(event.target) || layerAbove()) {
        return;
      }
      const back = layer.current?.querySelector<HTMLButtonElement>("[data-page-back]");
      if (back) {
        event.preventDefault();
        back.click();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [layer, open]);
}

export function PageOutlet({ entry, onCovered }: { entry: PageEntry | null; onCovered(covered: boolean): void }) {
  const reduced = useReducedMotion();
  const variants = pageVariants(reduced);
  const layer = useRef<HTMLDivElement>(null);
  useEscapeGoesBack(layer, entry !== null);
  return (
    <AnimatePresence initial={false} onExitComplete={() => onCovered(false)}>
      {entry ? (
        <motion.div
          key={entry.key}
          ref={layer}
          className={PAGE_LAYER}
          variants={variants}
          initial="enter"
          animate="shown"
          exit="leave"
          onAnimationComplete={(definition) => {
            if (definition === "shown") {
              onCovered(true);
            }
          }}
        >
          {/* An opaque stand-in while a lazy page loads, so the home view never shows through. */}
          <Suspense fallback={<div className="h-dvh bg-surface" />}>{entry.node}</Suspense>
        </motion.div>
      ) : null}
    </AnimatePresence>
  );
}

/**
 * Whether the home view is fully hidden under a page: set once a page has
 * finished arriving, cleared as soon as the route leaves the pages (so it is
 * visible again while the page leaves).
 */
export function useCovered(pageOpen: boolean): [boolean, (covered: boolean) => void] {
  const [covered, setCovered] = useState(false);
  return [covered && pageOpen, setCovered];
}
