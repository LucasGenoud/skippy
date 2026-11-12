"use client";

import { Check, Folder, TriangleAlert, Users } from "lucide-react";
import { cn } from "cn";
import { BackgroundPicker } from "@/components/common/color-picker";
import { showAppSnack } from "@/components/common/snack";
import type { Note } from "@/lib/models/note";
import { isWorkspaceShared, type NoteCollection } from "@/lib/models/workspace";
import { noteAvailability } from "@/lib/state/note-availability";
import { useNotesController, useNotesSelector, useSettings, useWorkspace, useWorkspaces } from "@/lib/store";
import { labelIconFor } from "@/lib/theme/label-style";
import type { NotePatternId } from "@/lib/theme/patterns";
import { AdaptiveSurface } from "./adaptive-surface";
import { GlyphBadge } from "./form-bits";
import { useBrightness } from "./responsive";
import { commonValue, labelsDroppedByMove } from "./selection-rules";

// Pickers the selection bar opens for several notes at once.

interface SurfaceProps {
  readonly open: boolean;
  onOpenChange(open: boolean): void;
}

function notesEqual(a: readonly Note[], b: readonly Note[]): boolean {
  return a.length === b.length && a.every((n, i) => n === b[i]);
}

/** The selected notes as stored now; ids that vanished are skipped. */
function useNotes(ids: readonly string[]): Note[] {
  return useNotesSelector((s) => ids.map((id) => s.notes[id]).filter((n): n is Note => n !== undefined), notesEqual, [ids.join("|")]);
}

const COLLECTION_LAYOUT_NAMES: Record<string, string> = { board: "Board", list: "List" };

/** Colour and pattern for every selected note; the check sits where they all agree. */
export function BulkColorSurface({ open, onOpenChange, noteIds }: SurfaceProps & { noteIds: readonly string[] }) {
  const notes = useNotesController();
  const selected = useNotes(noteIds);
  const palette = useSettings((s) => s.palette);
  const brightness = useBrightness();
  const color = commonValue(selected.map((n) => n.color), "default");
  const pattern = commonValue<NotePatternId>(selected.map((n) => n.pattern as NotePatternId), "none" as NotePatternId);

  return (
    <AdaptiveSurface open={open} onOpenChange={onOpenChange} title={selected.length === 1 ? "Background" : `Background of ${selected.length} notes`}>
      <div className="py-1">
        <BackgroundPicker
          color={color}
          onColorChange={(key) => selected.forEach((n) => notes.setColor(n.id, key))}
          pattern={pattern}
          onPatternChange={(p) => selected.forEach((n) => notes.setPattern(n.id, p))}
          brightness={brightness}
          palette={palette}
        />
      </div>
    </AdaptiveSurface>
  );
}

function CollectionChoices({ collections, selectedId, onPick }: { collections: readonly NoteCollection[]; selectedId: string | null; onPick(id: string): void }) {
  if (collections.length === 0) {
    return <p className="py-6 text-center text-sm text-on-surface-variant">Create a collection in this workspace first.</p>;
  }
  return (
    <div role="listbox" className="flex flex-col gap-0.5 pb-1">
      {collections.map((c) => (
        <PickRow
          key={c.id}
          selected={c.id === selectedId}
          onPick={() => onPick(c.id)}
          leading={<GlyphBadge icon={c.icon} color={c.color} fallback={c.icon === null ? Folder : labelIconFor(c.icon)} />}
          title={c.name}
          subtitle={COLLECTION_LAYOUT_NAMES[c.layout] ?? "Masonry"}
        />
      ))}
    </div>
  );
}

function PickRow({ selected, onPick, leading, title, subtitle }: { selected: boolean; onPick(): void; leading: React.ReactNode; title: string; subtitle?: string }) {
  return (
    <button
      type="button"
      role="option"
      aria-selected={selected}
      onClick={onPick}
      className={cn(
        "flex min-h-11 items-center gap-3 rounded-md px-2 text-left outline-none transition-colors duration-150 ease-standard hover:bg-hover focus-visible:ring-[3px] focus-visible:ring-ring/50",
        selected && "bg-secondary-container",
      )}
    >
      {leading}
      <span className="flex min-w-0 flex-1 flex-col">
        <span className="truncate text-sm text-on-surface">{title}</span>
        {subtitle ? <span className="truncate text-xs text-on-surface-variant">{subtitle}</span> : null}
      </span>
      {selected ? <Check aria-hidden className="size-4 text-primary" /> : null}
    </button>
  );
}

/** File the selection in another collection of its workspace; labels stay, the column clears. */
export function MoveToCollectionSurface({ open, onOpenChange, noteIds }: SurfaceProps & { noteIds: readonly string[] }) {
  const notes = useNotesController();
  const selected = useNotes(noteIds);
  const workspace = useWorkspace(notes.activeWorkspaceId);
  const collections = workspace?.collections ?? [];
  const current = commonValue<string | null>(selected.map((n) => n.collectionId), null);

  const pick = (collectionId: string): void => {
    for (const note of selected) {
      if (note.workspaceId === workspace?.id && note.collectionId !== collectionId) {
        notes.moveToCollection(note.id, collectionId);
      }
    }
    onOpenChange(false);
  };

  return (
    <AdaptiveSurface open={open} onOpenChange={onOpenChange} title="Move to collection">
      <CollectionChoices collections={collections} selectedId={current} onPick={pick} />
    </AdaptiveSurface>
  );
}

/** Restore notes whose collection is gone into one the user picks (`CollectionPicker.restore`). */
export function RestorePickerSurface({ open, onOpenChange, noteIds, workspaceId }: SurfaceProps & { noteIds: readonly string[]; workspaceId: string }) {
  const notes = useNotesController();
  const workspace = useWorkspace(workspaceId);
  const pick = (collectionId: string): void => {
    for (const id of noteIds) {
      notes.restoreFromTrash(id, collectionId);
    }
    onOpenChange(false);
  };
  return (
    <AdaptiveSurface open={open} onOpenChange={onOpenChange} title="Choose a collection" description="The collection these notes were in no longer exists.">
      <CollectionChoices collections={workspace?.collections ?? []} selectedId={null} onPick={pick} />
    </AdaptiveSurface>
  );
}

/**
 * File the selection in another workspace. Only a note's owner can move it,
 * and labels that do not exist there are dropped, which the user is told.
 */
export function MoveToWorkspaceSurface({ open, onOpenChange, noteIds }: SurfaceProps & { noteIds: readonly string[] }) {
  const notes = useNotesController();
  const selected = useNotes(noteIds);
  const workspaces = useWorkspaces();
  const current = commonValue<string | null>(selected.map((n) => n.workspaceId), null);

  const pick = (workspaceId: string): void => {
    let dropped = 0;
    let refused = 0;
    for (const note of selected) {
      if (note.workspaceId === workspaceId) {
        continue;
      }
      if (!noteAvailability(notes, note).canMoveToWorkspace) {
        refused++;
        continue;
      }
      dropped += labelsDroppedByMove(note, workspaceId, (id) => notes.labelById(id));
      notes.moveNoteToWorkspace(note.id, workspaceId);
    }
    onOpenChange(false);
    if (dropped > 0) {
      showAppSnack(`${dropped} ${dropped === 1 ? "label was" : "labels were"} removed when moving`, { icon: TriangleAlert, kind: "warning" });
    } else if (refused > 0) {
      showAppSnack("Only the owner can move a note to another workspace", { icon: TriangleAlert, kind: "warning" });
    }
  };

  return (
    <AdaptiveSurface open={open} onOpenChange={onOpenChange} title="Move to workspace">
      <div role="listbox" className="flex flex-col gap-0.5 pb-1">
        {workspaces.map((w) => (
          <PickRow
            key={w.id}
            selected={w.id === current}
            onPick={() => pick(w.id)}
            leading={
              <span className="inline-flex size-7 shrink-0 items-center justify-center rounded-md bg-secondary-container text-sm font-semibold text-on-secondary-container">
                {Array.from(w.name.trim())[0]?.toUpperCase() ?? "?"}
              </span>
            }
            title={w.name}
            subtitle={isWorkspaceShared(w) ? `${w.members.length + 1} people` : undefined}
          />
        ))}
      </div>
      {workspaces.some(isWorkspaceShared) ? (
        <p className="flex items-center gap-1.5 pb-1 text-xs text-on-surface-variant">
          <Users aria-hidden className="size-3.5" />
          Everyone in the destination workspace will see the moved notes.
        </p>
      ) : null}
    </AdaptiveSurface>
  );
}
