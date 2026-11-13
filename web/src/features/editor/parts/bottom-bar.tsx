"use client";

import { cn } from "cn";
import { useState } from "react";
import { BellPlus, CirclePlus, Image as ImageIcon, Palette, Paperclip, Redo2, Tag, Undo2 } from "lucide-react";

import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { TooltipProvider } from "@/components/ui/tooltip";
import { BackgroundPicker } from "@/components/common/color-picker";
import { IconButton } from "@/components/common/icon-button";
import { MenuLabel } from "@/components/common/menu-label";
import { ReminderPicker, type ReminderValue } from "@/components/common/reminder-picker";
import type { NotePattern } from "@/lib/models/note";
import type { Brightness } from "@/lib/theme/accent";
import type { PaletteEntry } from "@/lib/theme/palette";
import { useMediaQuery } from "../lib/hooks";
import { NoteLabelPicker } from "../label-picker";

// The editor's bottom strip (`editor_bottom_bar.dart`): what goes into the
// note on the left, the edited stamp and sync state in the middle, undo and
// redo on the right. Below 360px the two insert actions fold into one.

export interface BottomBarProps {
  noteId: string;
  trashed: boolean;
  wide: boolean;
  editedStamp: string;
  color: string;
  pattern: NotePattern;
  brightness: Brightness;
  palette: readonly PaletteEntry[];
  onColor(key: string): void;
  onPattern(pattern: NotePattern): void;
  reminder: ReminderValue | null;
  use24h: boolean;
  onReminder(value: ReminderValue | null): void;
  onImage: (() => void) | null;
  onAttach: (() => void) | null;
  onUndo: (() => void) | null;
  onRedo: (() => void) | null;
}

export function BottomBar(props: BottomBarProps) {
  const [reminderOpen, setReminderOpen] = useState(false);
  const veryNarrow = !useMediaQuery("(min-width: 360px)");
  const live = !props.trashed;
  return (
    <TooltipProvider>
      {/* Full screen on a phone, the bar is chrome with a seam, as the top bar is. */}
      <div className={cn("flex h-12 shrink-0 items-center gap-0.5 px-3 pb-1", !props.wide && "border-t border-hairline")}>
        <Popover>
          <PopoverTrigger asChild>
            <IconButton label="Note color" icon={<Palette />} side="top" disabled={!live} />
          </PopoverTrigger>
          <PopoverContent side="top" align="start" className="w-[min(380px,calc(100vw-2rem))]">
            <BackgroundPicker
              color={props.color}
              onColorChange={props.onColor}
              pattern={props.pattern}
              onPatternChange={(p) => props.onPattern(p as NotePattern)}
              brightness={props.brightness}
              palette={props.palette}
            />
          </PopoverContent>
        </Popover>
        {live ? (
          <NoteLabelPicker noteIds={[props.noteId]}>
            <IconButton label="Labels" icon={<Tag />} side="top" />
          </NoteLabelPicker>
        ) : (
          <IconButton label="Labels" icon={<Tag />} side="top" disabled />
        )}
        <Popover open={reminderOpen} onOpenChange={setReminderOpen}>
          <PopoverTrigger asChild>
            <IconButton label="Remind me" icon={<BellPlus />} side="top" disabled={!live} />
          </PopoverTrigger>
          <PopoverContent side="top" align="start" className="w-[360px]">
            <ReminderPicker
              value={props.reminder}
              use24h={props.use24h}
              onChange={(value) => {
                props.onReminder(value);
                setReminderOpen(false);
              }}
            />
          </PopoverContent>
        </Popover>
        {veryNarrow ? (
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <IconButton label="Add to note" icon={<CirclePlus />} side="top" disabled={!props.onImage && !props.onAttach} />
            </DropdownMenuTrigger>
            <DropdownMenuContent side="top" align="start">
              <DropdownMenuItem disabled={!props.onImage} onSelect={() => props.onImage?.()}>
                <ImageIcon />
                <MenuLabel label="Add image" />
              </DropdownMenuItem>
              <DropdownMenuItem disabled={!props.onAttach} onSelect={() => props.onAttach?.()}>
                <Paperclip />
                <MenuLabel label="Attach file" />
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        ) : (
          <>
            <IconButton label="Add image" icon={<ImageIcon />} side="top" disabled={!props.onImage} onClick={() => props.onImage?.()} />
            <IconButton label="Attach file" icon={<Paperclip />} side="top" disabled={!props.onAttach} onClick={() => props.onAttach?.()} />
          </>
        )}
        {/* The whole middle band, so the stamp is not cut down to "Edit…". */}
        <div className="flex min-w-0 flex-1 items-center justify-center px-2">
          {props.wide ? <span className="min-w-0 truncate text-xs text-on-surface-variant">{props.editedStamp}</span> : null}
        </div>
        <IconButton label="Undo" icon={<Undo2 />} side="top" disabled={!props.onUndo} onClick={() => props.onUndo?.()} />
        <IconButton label="Redo" icon={<Redo2 />} side="top" disabled={!props.onRedo} onClick={() => props.onRedo?.()} />
      </div>
    </TooltipProvider>
  );
}
