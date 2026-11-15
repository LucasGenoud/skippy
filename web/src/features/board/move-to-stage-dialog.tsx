"use client";

import { Check } from "lucide-react";

import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import type { Stage } from "@/lib/models/note";
import { useNotesController, useNotesSelector } from "@/lib/store";

import { StageDot } from "./stage-editor";

// Picks the column one or more notes belong in (`MoveToStageSheet`). The
// guaranteed way to move a card, and the keyboard and screen-reader path that
// dragging can never be. Backs a card's menu and the selection bar's bulk move.

interface Choice {
  readonly stageId: string | null;
  readonly name: string;
  readonly color: string | null;
}

/** Stages every note can go to, after Unassigned; the current one when all agree. */
function useChoices(noteIds: readonly string[]): { choices: Choice[]; current: string | null | undefined } {
  const notes = useNotesController();
  return useNotesSelector(
    () => {
      const present = noteIds.map((id) => notes.noteById(id)).filter((n) => n !== null);
      const stageIds = new Set(present.map((n) => n.stageId));
      // A shared "current" only means something when every note agrees.
      const current = stageIds.size === 1 ? [...stageIds][0] : undefined;
      const first = present[0] ?? null;
      const shared: Stage[] = notes.stagesForNote(first).filter((stage) => present.every((n) => notes.stagesForNote(n).some((s) => s.id === stage.id)));
      return {
        choices: [{ stageId: null, name: "Unassigned", color: null }, ...shared.map((s) => ({ stageId: s.id, name: s.name, color: s.color }))],
        current,
      };
    },
    (a, b) =>
      a.current === b.current &&
      a.choices.length === b.choices.length &&
      a.choices.every((c, i) => {
        const o = b.choices[i];
        return o !== undefined && o.stageId === c.stageId && o.name === c.name && o.color === c.color;
      }),
    [noteIds.join(",")],
  );
}

export function MoveToStageDialog({ noteIds, open, onOpenChange }: { noteIds: readonly string[]; open: boolean; onOpenChange(open: boolean): void }) {
  const notes = useNotesController();
  const { choices, current } = useChoices(noteIds);
  const title = noteIds.length === 1 ? "Move to column" : `Move ${noteIds.length} notes to column`;

  const move = (stageId: string | null): void => {
    onOpenChange(false);
    for (const id of noteIds) {
      const note = notes.noteById(id);
      if (note && note.stageId !== stageId) {
        notes.setNoteStage(id, stageId);
      }
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-[360px]">
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          <DialogDescription className="sr-only">Choose the board column.</DialogDescription>
        </DialogHeader>
        <ul role="listbox" aria-label="Columns" className="-mx-2 grid gap-0.5">
          {choices.map((choice) => {
            const selected = current === choice.stageId;
            return (
              <li key={choice.stageId ?? "unassigned"}>
                <button
                  type="button"
                  role="option"
                  aria-selected={selected}
                  onClick={() => move(choice.stageId)}
                  className={
                    "flex h-10 w-full items-center gap-3 rounded-md px-2 text-left text-sm transition-colors duration-150 ease-standard outline-none hover:bg-hover active:bg-pressed focus-visible:ring-[3px] focus-visible:ring-ring/50 " +
                    (selected ? "bg-secondary-container text-on-secondary-container hover:bg-secondary-container" : "text-on-surface")
                  }
                >
                  <StageDot color={choice.color} />
                  <span className="min-w-0 flex-1 truncate">{choice.name}</span>
                  {selected ? <Check className="size-4 animate-in zoom-in-50 duration-150 ease-back" /> : null}
                </button>
              </li>
            );
          })}
        </ul>
      </DialogContent>
    </Dialog>
  );
}
