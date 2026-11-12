"use client";

import { ArrowDownLeft, ArrowUpRight, Link2 } from "lucide-react";
import { cn } from "cn";

import { SectionLabel } from "@/components/common/section-label";
import type { Note } from "@/lib/models/note";
import { noteLinkTitle } from "@/lib/state/note-links";

// Note links in the editor (`note_links_panel.dart`): the picker docked above
// the bottom bar while `[[` is typed, and the links in and out of the note.

export function NoteLinkPicker({
  notes,
  query,
  active,
  onPick,
  onHover,
}: {
  notes: readonly Note[];
  query: string;
  /** The highlighted row (arrow keys). */
  active: number;
  onPick(note: Note): void;
  onHover(index: number): void;
}) {
  return (
    <div className="border-t border-hairline bg-surface-container-high" role="listbox" aria-label="Link to note">
      {notes.length === 0 ? (
        <p className="px-4 py-3.5 text-sm text-on-surface-variant">
          {query.trim() === "" ? "No notes to link to" : `No notes match “${query.trim()}”`}
        </p>
      ) : (
        <ul className="max-h-[220px] overflow-y-auto py-1">
          {notes.map((note, i) => (
            <li key={note.id}>
              <button
                type="button"
                role="option"
                aria-selected={i === active}
                // Keep focus (and the caret) in the body while picking.
                onPointerDown={(e) => e.preventDefault()}
                onPointerEnter={() => onHover(i)}
                onClick={() => onPick(note)}
                className={cn(
                  "flex w-full items-center gap-3 px-4 py-2 text-left text-sm text-on-surface transition-colors duration-150 ease-standard outline-none",
                  i === active ? "bg-hover" : "hover:bg-hover",
                )}
              >
                <Link2 aria-hidden className="size-4 shrink-0 text-on-surface-variant" />
                <span className="truncate">{noteLinkTitle(note)}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export interface LinkedNoteRef {
  readonly id: string;
  readonly title: string;
  /** False when this account cannot reach it; it shows but does not open. */
  readonly reachable: boolean;
}

function LinkGroup({ label, refs, icon: Icon, onOpen }: { label: string; refs: readonly LinkedNoteRef[]; icon: typeof Link2; onOpen(id: string): void }) {
  return (
    <div className="flex flex-col gap-1.5 pt-3">
      <SectionLabel>{label}</SectionLabel>
      <div className="flex flex-wrap gap-2">
        {refs.map((ref) => (
          <button
            key={ref.id}
            type="button"
            disabled={!ref.reachable}
            onClick={() => onOpen(ref.id)}
            className="inline-flex h-7 max-w-full items-center gap-1.5 rounded-md border border-outline-variant px-2.5 text-xs text-on-surface transition-colors duration-150 ease-standard outline-none hover:bg-hover active:bg-pressed focus-visible:ring-[3px] focus-visible:ring-ring/50 disabled:text-on-surface-variant disabled:opacity-70"
          >
            <Icon aria-hidden className="size-3.5 shrink-0 text-on-surface-variant" />
            <span className="truncate">{ref.title}</span>
          </button>
        ))}
      </div>
    </div>
  );
}

export function NoteLinksSection({
  outgoing,
  incoming,
  onOpen,
}: {
  outgoing: readonly LinkedNoteRef[];
  incoming: readonly LinkedNoteRef[];
  onOpen(id: string): void;
}) {
  return (
    <div className="flex flex-col">
      {outgoing.length > 0 ? <LinkGroup label="Links" refs={outgoing} icon={ArrowUpRight} onOpen={onOpen} /> : null}
      {incoming.length > 0 ? <LinkGroup label="Linked from" refs={incoming} icon={ArrowDownLeft} onOpen={onOpen} /> : null}
    </div>
  );
}
