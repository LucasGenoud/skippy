"use client";

import { Fragment, useEffect, useState } from "react";
import { Kbd } from "@/components/common/kbd";
import { SectionLabel } from "@/components/common/section-label";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { usePlatformName } from "./responsive";
import { modifierName, shortcutSections } from "./shortcuts";

/** The keyboard shortcut reference, opened with "?" (`ShortcutHelpDialog`). */
export function ShortcutHelpDialog({ open, onOpenChange }: { open: boolean; onOpenChange(open: boolean): void }) {
  const mod = modifierName(usePlatformName());
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-[360px]">
        <DialogHeader>
          <DialogTitle>Keyboard shortcuts</DialogTitle>
          <DialogDescription className="sr-only">Keys for the notes screen, the editor and quick add</DialogDescription>
        </DialogHeader>
        <div className="flex flex-col gap-4">
          {shortcutSections(mod).map((section) => (
            <section key={section.title} className="flex flex-col gap-1.5">
              <SectionLabel className="px-0">{section.title}</SectionLabel>
              <dl className="grid grid-cols-[8.5rem_1fr] items-center gap-x-3 gap-y-1.5">
                {section.rows.map((row) => (
                  <Fragment key={row.description}>
                    <dt className="flex flex-wrap items-center gap-1">
                      {row.keys.map((key, i) => (
                        <Fragment key={key}>
                          {i > 0 ? <span className="text-xs text-on-surface-variant">or</span> : null}
                          <span className="inline-flex gap-0.5">
                            {key.split(" ").map((part) => (
                              <Kbd key={part}>{part}</Kbd>
                            ))}
                          </span>
                        </Fragment>
                      ))}
                    </dt>
                    <dd className="text-sm text-on-surface">{row.description}</dd>
                  </Fragment>
                ))}
              </dl>
            </section>
          ))}
        </div>
        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Close
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

// Opening the reference from outside the shell (Settings > About), where the
// shell's dialog stack is not mounted. A module-level signal, heard by every
// mounted host.

const listeners = new Set<() => void>();

/** Show the keyboard shortcut reference wherever a `ShortcutHelpHost` is mounted. */
export function openShortcutHelp(): void {
  for (const listener of listeners) {
    listener();
  }
}

/**
 * Renders the reference when `openShortcutHelp()` is called. The shell
 * mounts one; a page rendered outside the shell (settings) mounts its own.
 */
export function ShortcutHelpHost() {
  const [open, setOpen] = useState(false);
  useEffect(() => {
    const show = (): void => setOpen(true);
    listeners.add(show);
    return () => {
      listeners.delete(show);
    };
  }, []);
  return <ShortcutHelpDialog open={open} onOpenChange={setOpen} />;
}
