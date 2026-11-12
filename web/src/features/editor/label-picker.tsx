"use client";

import { useState, type ReactNode } from "react";
import { Check, Plus } from "lucide-react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";

import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from "@/components/ui/command";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Checkbox } from "@/components/ui/checkbox";
import type { Label, Note } from "@/lib/models/note";
import { useLabels, useNotesController, useNotesSelector } from "@/lib/store";
import { LabelIcon, labelStyle } from "@/lib/theme/label-style";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";

// Assigning a workspace's labels to notes (`labels_sheet.dart`): search,
// tick, or type a new name to create it. With one note each row toggles; with
// several a row only adds, so applying a label twice is harmless.

function notesEqual(a: readonly Note[], b: readonly Note[]): boolean {
  return a.length === b.length && a.every((n, i) => n === b[i]);
}

/** The small tinted square leading a label row (`LabelGlyph`). */
function LabelGlyph({ label }: { label: Label }) {
  return (
    <span className="inline-flex size-6 shrink-0 items-center justify-center rounded-md border" style={labelStyle(label.color)}>
      <LabelIcon iconKey={label.icon} aria-hidden className="size-3.5" />
    </span>
  );
}

export function NoteLabelPicker({ noteIds, children }: { noteIds: string[]; children: ReactNode }) {
  const [open, setOpen] = useState(false);
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>{children}</PopoverTrigger>
      <PopoverContent className="w-72 p-0" align="start" onOpenAutoFocus={(e) => e.preventDefault()}>
        {open ? <LabelList noteIds={noteIds} /> : null}
      </PopoverContent>
    </Popover>
  );
}

function LabelList({ noteIds }: { noteIds: string[] }) {
  const store = useNotesController();
  const labels = useLabels();
  const reduced = useReducedMotion();
  const [query, setQuery] = useState("");
  const notes = useNotesSelector(
    (s) => noteIds.map((id) => s.notes[id]).filter((n): n is Note => n !== undefined),
    notesEqual,
    [noteIds.join("|")],
  );
  if (notes.length === 0) {
    return null;
  }
  const multiple = notes.length > 1;
  const q = query.trim().toLowerCase();
  const visible = labels.filter((l) => q === "" || l.name.toLowerCase().includes(q));
  const exactExists = labels.some((l) => l.name.toLowerCase() === q);
  const assigned = (label: Label): boolean => notes.every((n) => n.labelIds.includes(label.id));

  const toggle = (label: Label): void => {
    if (multiple) {
      for (const note of notes) {
        store.addLabelToNote(note.id, label.id);
      }
      return;
    }
    const only = notes[0];
    if (only) {
      store.toggleLabelOnNote(only.id, label.id);
    }
  };

  const create = (): void => {
    const name = query.trim();
    if (!name) {
      return;
    }
    const label = store.createLabel(name);
    for (const note of notes) {
      store.addLabelToNote(note.id, label.id);
    }
    setQuery("");
  };

  return (
    <Command shouldFilter={false} label={multiple ? `Add label to ${notes.length} notes` : "Label note"}>
      <CommandInput autoFocus value={query} onValueChange={setQuery} placeholder="Enter label name" />
      <CommandList>
        {labels.length === 0 && q === "" ? <CommandEmpty>No labels yet, type a name to create one.</CommandEmpty> : null}
        <CommandGroup heading={multiple ? `Add to ${notes.length} notes` : undefined}>
          {q !== "" && !exactExists ? (
            <CommandItem value="__create__" onSelect={create}>
              <Plus />
              <span className="truncate">Create “{query.trim()}”</span>
            </CommandItem>
          ) : null}
          {visible.map((label) => {
            const on = assigned(label);
            return (
              <CommandItem key={label.id} value={label.id} onSelect={() => toggle(label)}>
                {multiple ? null : <Checkbox checked={on} tabIndex={-1} aria-hidden className="pointer-events-none" />}
                <LabelGlyph label={label} />
                <span className="min-w-0 flex-1 truncate">{label.name}</span>
                {multiple ? (
                  <span className="inline-grid size-4">
                    <AnimatePresence initial={false}>
                      <motion.span
                        key={on ? "on" : "off"}
                        initial={{ scale: 0, opacity: 0 }}
                        animate={{ scale: 1, opacity: 1 }}
                        exit={{ scale: 0, opacity: 0 }}
                        transition={transitionFor(TRANSITION.pop, reduced)}
                        style={{ gridArea: "1 / 1" }}
                      >
                        {on ? <Check className="size-4 text-primary" /> : <Plus className="size-4" />}
                      </motion.span>
                    </AnimatePresence>
                  </span>
                ) : null}
              </CommandItem>
            );
          })}
        </CommandGroup>
      </CommandList>
    </Command>
  );
}
