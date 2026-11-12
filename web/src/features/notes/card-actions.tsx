"use client";

import { memo, useState } from "react";
import { Archive, ArchiveArrowUp, BellPlus, BellRing, CircleAlert, ImagePlus, Palette, Tag } from "lucide-react";

import { BackgroundPicker } from "@/components/common/color-picker";
import { IconButton } from "@/components/common/icon-button";
import { ReminderPicker } from "@/components/common/reminder-picker";
import { showAppSnack } from "@/components/common/snack";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { TooltipProvider } from "@/components/ui/tooltip";
import { NoteLabelPicker } from "@/features/editor/label-picker";
import { hasReminder, type Note } from "@/lib/models/note";
import { useNotesController, useSettings } from "@/lib/store";
import type { NotePatternId } from "@/lib/theme/patterns";

import { filesWithinLimit, toggleArchive, uploadFiles } from "./note-actions";
import { NoteActionsMenu } from "./note-actions-menu";
import { pickFiles, useBrightness } from "./platform";

/**
 * The pointer-only row along a card's footer (`note_card/actions.dart`):
 * colour, labels, reminder, image, archive, and the menu. The card reserves
 * its slot at all times, so revealing it never moves anything.
 */
export const CardActions = memo(function CardActions({ note, onOverlayChange }: { note: Note; onOverlayChange: (open: boolean) => void }) {
  const notes = useNotesController();
  const palette = useSettings((s) => s.palette);
  const use24h = useSettings((s) => s.use24hTime);
  const brightness = useBrightness();
  const [colorOpen, setColorOpen] = useState(false);
  const [reminderOpen, setReminderOpen] = useState(false);
  const reminder = hasReminder(note);

  const overlay = (setter: (open: boolean) => void) => (open: boolean) => {
    setter(open);
    onOverlayChange(open);
  };

  const addImage = async (): Promise<void> => {
    const picked = filesWithinLimit(await pickFiles({ accept: "image/*" }));
    if (picked.length === 0) {
      return;
    }
    try {
      await uploadFiles(notes, note.id, picked);
    } catch {
      showAppSnack("Couldn't upload the image", { icon: CircleAlert, kind: "danger" });
    }
  };

  const stop = (event: { stopPropagation(): void }): void => event.stopPropagation();

  return (
    <TooltipProvider>
      <div className="flex h-full items-center justify-evenly border-t border-outline-variant/55 pt-1.5" onClick={stop} onPointerDown={stop} onMouseDown={stop} onTouchStart={stop}>
        <Popover open={colorOpen} onOpenChange={overlay(setColorOpen)}>
          <PopoverTrigger asChild>
            <IconButton label="Note color" size="sm" icon={<Palette />} />
          </PopoverTrigger>
          <PopoverContent className="w-[332px]" onClick={stop}>
            <BackgroundPicker
              color={note.color}
              onColorChange={(key) => notes.setColor(note.id, key)}
              pattern={note.pattern as NotePatternId}
              onPatternChange={(pattern) => notes.setPattern(note.id, pattern)}
              brightness={brightness}
              palette={palette}
            />
          </PopoverContent>
        </Popover>
        <NoteLabelPicker noteIds={[note.id]}>
          <IconButton label="Add label" size="sm" icon={<Tag />} />
        </NoteLabelPicker>
        <Popover open={reminderOpen} onOpenChange={overlay(setReminderOpen)}>
          <PopoverTrigger asChild>
            <IconButton label={reminder ? "Edit reminder" : "Add reminder"} size="sm" icon={reminder ? <BellRing /> : <BellPlus />} />
          </PopoverTrigger>
          <PopoverContent className="w-[360px]" onClick={stop}>
            <ReminderPicker
              value={note.reminderAt ? { at: note.reminderAt, repeat: note.reminderRepeat ?? undefined } : null}
              use24h={use24h}
              onChange={(value) => {
                notes.setReminder(note.id, value?.at ?? null, value?.repeat ?? null);
                overlay(setReminderOpen)(false);
              }}
            />
          </PopoverContent>
        </Popover>
        <IconButton label="Add image" size="sm" icon={<ImagePlus />} onClick={() => void addImage()} />
        <IconButton
          label={note.archived ? "Unarchive note" : "Archive note"}
          size="sm"
          icon={note.archived ? <ArchiveArrowUp /> : <Archive />}
          shortcut="E"
          onClick={() => toggleArchive(notes, notes.noteById(note.id) ?? note)}
        />
        <NoteActionsMenu noteId={note.id} surface="card" onOpenChange={onOverlayChange} />
      </div>
    </TooltipProvider>
  );
});
