"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import { motion, useReducedMotion } from "motion/react";
import { Archive, Bell, Bookmark, Folder, Pencil, Trash2, type LucideIcon } from "lucide-react";
import { cn } from "cn";
import { SectionLabel } from "@/components/common/section-label";
import { Separator } from "@/components/ui/separator";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import {
  isWorkspaceWide,
  useActiveCollection,
  useCollections,
  useLabels,
  useNotesController,
  useSavedViews,
  useUi,
  useUiController,
  type Destination,
} from "@/lib/store";
import { NOTE_DROP_EVENT, type NoteDropDetail } from "@/features/notes/masonry";
import { labelColor, labelIconFor } from "@/lib/theme/label-style";
import { DURATION, TRANSITION, prefersReducedMotion, transitionFor } from "@/lib/theme/motion";
import { useOpenDestination } from "./shell-actions";
import { useShellDialogs } from "./shell-dialogs";
import { WorkspaceMenu } from "./workspace-menu";

/** Docked widths, open and as an icon rail (`AppSidebar`). */
export const SIDEBAR_OPEN_PX = 268;
export const SIDEBAR_RAIL_PX = 72;

export type SidebarPlacement = "docked" | "drawer";

/**
 * The sidebar's contents: the workspace switcher, the open workspace's
 * collections, labels and smart views, and the library (reminders, archive,
 * trash). [onNavigate] closes the phone drawer once a row is chosen.
 */
export function SidebarContent({ compact, placement, onNavigate }: { compact: boolean; placement: SidebarPlacement; onNavigate?: () => void }) {
  const destination = useUi((s) => s.destination);
  const done = (): void => onNavigate?.();
  // A dialog or page opened from the phone drawer waits for the drawer to
  // finish closing, so the two surfaces never animate through each other.
  const after = (show: () => void): void => {
    if (placement !== "drawer") {
      show();
      return;
    }
    done();
    window.setTimeout(show, prefersReducedMotion() ? 0 : DURATION.base);
  };

  return (
    <nav aria-label="Main" className="flex flex-col py-3">
      <div className="px-2 pb-3">
        <WorkspaceMenu compact={compact} beforeAction={placement === "drawer" ? after : undefined} />
      </div>
      <Collections compact={compact} destination={destination} done={done} after={after} />
      <Separator className="mx-4 my-4 w-auto bg-hairline" />
      <Labels compact={compact} destination={destination} done={done} after={after} />
      <Separator className="mx-4 my-4 w-auto bg-hairline" />
      <SmartViews compact={compact} destination={destination} done={done} after={after} />
      <Separator className="mx-4 my-4 w-auto bg-hairline" />
      <LibraryRows compact={compact} destination={destination} done={done} after={after} />
    </nav>
  );
}

interface SectionProps {
  readonly compact: boolean;
  readonly destination: Destination;
  readonly done: () => void;
  /** Runs [show] once the phone drawer is out of the way. */
  readonly after: (show: () => void) => void;
}

function Collections({ compact, destination, done, after }: SectionProps) {
  const collections = useCollections();
  const active = useActiveCollection();
  const notes = useNotesController();
  const ui = useUiController();
  const dialogs = useShellDialogs();
  const open = useOpenDestination();

  return (
    <section>
      <SectionHeader label="Collections" compact={compact} />
      {collections.map((c) => (
        <SidebarRow
          key={c.id}
          icon={labelIconFor(c.icon)}
          fallbackIcon={Folder}
          hasCustomIcon={c.icon !== null}
          iconColor={c.color}
          label={c.name}
          compact={compact}
          selected={active?.id === c.id && !isWorkspaceWide(destination)}
          washed={active?.id === c.id && !isWorkspaceWide(destination) && typeof destination === "string"}
          onNoteDrop={(ids) => {
            for (const id of ids) {
              if (notes.noteById(id)?.workspaceId === c.workspaceId) {
                notes.restoreToCollection(id, c.id);
              }
            }
            ui.clearSelection();
          }}
          onClick={() => {
            open("notes", c.id);
            done();
          }}
        />
      ))}
      <SidebarRow
        icon={Pencil}
        label="Manage collections"
        compact={compact}
        tone="action"
        onClick={() => {
          after(() => dialogs.open({ type: "collections" }));
        }}
      />
    </section>
  );
}

function Labels({ compact, destination, done, after }: SectionProps) {
  const labels = useLabels();
  const notes = useNotesController();
  const dialogs = useShellDialogs();
  const open = useOpenDestination();
  const current = typeof destination !== "string" && "label" in destination ? destination.label : null;

  return (
    <section>
      <SectionHeader label="Labels" compact={compact} />
      {labels.map((label) => (
        <SidebarRow
          key={label.id}
          icon={labelIconFor(label.icon)}
          iconColor={label.color}
          hasCustomIcon
          label={label.name}
          compact={compact}
          selected={current === label.id}
          onNoteDrop={(ids) => {
            for (const id of ids) {
              const note = notes.noteById(id);
              if (note && !note.trashed && note.workspaceId === notes.activeWorkspaceId) {
                notes.addLabelToNote(id, label.id);
              }
            }
          }}
          onClick={() => {
            open(current === label.id ? "notes" : { label: label.id });
            done();
          }}
        />
      ))}
      <SidebarRow
        icon={Pencil}
        label={labels.length === 0 ? "Create labels" : "Manage labels"}
        compact={compact}
        tone="action"
        onClick={() => {
          after(() => dialogs.open({ type: "labels" }));
        }}
      />
    </section>
  );
}

function SmartViews({ compact, destination, done, after }: SectionProps) {
  const views = useSavedViews();
  const dialogs = useShellDialogs();
  const open = useOpenDestination();
  const current = typeof destination !== "string" && "smartView" in destination ? destination.smartView : null;

  return (
    <section>
      <SectionHeader label="Smart views" compact={compact} />
      {views.map((view) => (
        <SidebarRow
          key={view.id}
          icon={view.icon === null ? Bookmark : labelIconFor(view.icon)}
          iconColor={view.color}
          hasCustomIcon
          label={view.name}
          compact={compact}
          selected={current === view.id}
          onClick={() => {
            open(current === view.id ? "notes" : { smartView: view.id });
            done();
          }}
        />
      ))}
      <SidebarRow
        icon={Pencil}
        label={views.length === 0 ? "Create a smart view" : "Manage smart views"}
        compact={compact}
        tone="action"
        onClick={() => {
          after(() => dialogs.open(views.length === 0 ? { type: "savedView", savedViewId: null } : { type: "smartViews" }));
        }}
      />
    </section>
  );
}

const LIBRARY: readonly { destination: "reminders" | "archive" | "trash"; icon: LucideIcon; label: string }[] = [
  { destination: "reminders", icon: Bell, label: "Reminders" },
  { destination: "archive", icon: Archive, label: "Archive" },
  { destination: "trash", icon: Trash2, label: "Trash" },
];

function LibraryRows({ compact, destination, done }: SectionProps) {
  const open = useOpenDestination();
  const notes = useNotesController();
  const ui = useUiController();
  // Filing into Archive or Trash, as the Flutter drawer does; Reminders takes no drops.
  const fileInto = (target: "archive" | "trash", ids: readonly string[]): void => {
    for (const id of ids) {
      if (notes.noteById(id)?.trashed ?? true) {
        continue;
      }
      if (target === "archive") {
        notes.setArchived(id, true);
      } else if (notes.canTrash(id)) {
        notes.moveToTrash(id);
      }
    }
    ui.clearSelection();
  };
  return (
    <section>
      <SectionHeader label="Library" compact={compact} />
      {LIBRARY.map((entry) => (
        <SidebarRow
          key={entry.destination}
          icon={entry.icon}
          label={entry.label}
          compact={compact}
          selected={destination === entry.destination}
          onNoteDrop={entry.destination === "reminders" ? undefined : (ids) => fileInto(entry.destination as "archive" | "trash", ids)}
          dropTone={entry.destination === "trash" ? "danger" : "default"}
          onClick={() => {
            open(entry.destination);
            done();
          }}
        />
      ))}
    </section>
  );
}

function SectionHeader({ label, compact }: { label: string; compact: boolean }) {
  return (
    <div aria-hidden={compact || undefined} className={cn("flex h-7 items-center px-7 transition-opacity duration-240 ease-standard", compact ? "opacity-0" : "opacity-100")}>
      <SectionLabel className="truncate px-0">{label}</SectionLabel>
    </div>
  );
}

/**
 * One sidebar entry. The selection is an accent wash that fades in, nothing
 * snaps. A rail shows
 * only the icon, with the name in a tooltip.
 */
function SidebarRow({
  icon: Icon,
  fallbackIcon,
  hasCustomIcon = false,
  iconColor,
  label,
  compact,
  selected = false,
  washed = selected,
  tone = "default",
  onClick,
  onNoteDrop,
  dropTone = "default",
}: {
  icon: LucideIcon;
  /** Shown when the entity has no icon of its own. */
  fallbackIcon?: LucideIcon;
  hasCustomIcon?: boolean;
  iconColor?: string | null;
  label: string;
  compact: boolean;
  selected?: boolean;
  /**
   * Whether the sliding selection wash sits under this row. A collection stays
   * selected while a label or smart view filters it, but the wash goes to the
   * more specific row: there is one wash, so it marks one row.
   */
  washed?: boolean;
  /** "action" rows (create, manage) read quieter than destinations. */
  tone?: "default" | "action";
  onClick(): void;
  /** Makes the row a target for cards dragged out of the grid. */
  onNoteDrop?: (noteIds: readonly string[]) => void;
  /** Trash highlights a hovered drop in the error colour. */
  dropTone?: "default" | "danger";
}) {
  const dropRef = useNoteDropTarget(onNoteDrop);
  const reduced = useReducedMotion();
  const Glyph = hasCustomIcon || !fallbackIcon ? Icon : fallbackIcon;
  const tint = labelColor(iconColor);
  const row: ReactNode = (
    <div
      ref={dropRef}
      data-note-drop={onNoteDrop ? "" : undefined}
      className={cn(
        // 34px rows for a pointer, a 44px target for a finger (`_SidebarItem`).
        "group/row relative mx-3 mb-0.5 flex h-8.5 items-center rounded-sm transition-[background-color,box-shadow] duration-150 ease-standard [@media(hover:none)_and_(pointer:coarse)]:h-11",
        !washed && "hover:bg-hover",
        dropTone === "danger"
          ? "data-[drop-hover]:bg-error-container data-[drop-hover]:ring-2 data-[drop-hover]:ring-error"
          : "data-[drop-hover]:bg-secondary-container data-[drop-hover]:ring-2 data-[drop-hover]:ring-primary",
      )}
    >
      {/* One wash for the whole sidebar: it slides from the old row to the new one. */}
      {washed ? (
        <motion.span
          aria-hidden
          layoutId="sidebar-selection"
          data-sidebar-selection=""
          className="absolute inset-0 rounded-sm bg-secondary-container"
          transition={transitionFor(TRANSITION.base, reduced)}
        />
      ) : null}
      <button
        type="button"
        onClick={onClick}
        aria-current={selected ? "page" : undefined}
        aria-label={compact ? label : undefined}
        className={cn(
          "relative flex h-full min-w-0 flex-1 items-center gap-1 rounded-sm text-left text-sm outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50",
          tone === "action" ? "text-on-surface-variant/80" : selected ? "font-medium text-on-secondary-container" : "text-on-surface",
        )}
      >
        {/* The icon keeps a 48px column, the collapsed rail's width, open or not. */}
        <span className="flex w-12 shrink-0 justify-center">
          <Glyph
            aria-hidden
            className={cn("size-4.5", tint ? undefined : selected ? "text-on-secondary-container" : "text-on-surface-variant")}
            style={tint ? { color: tint } : undefined}
          />
        </span>
        <span className={cn("truncate pr-2 transition-opacity duration-150 ease-standard", compact ? "opacity-0" : "opacity-100")}>{label}</span>
      </button>
    </div>
  );

  if (!compact) {
    return row;
  }
  return (
    <Tooltip>
      <TooltipTrigger asChild>{row}</TooltipTrigger>
      <TooltipContent side="right">{label}</TooltipContent>
    </Tooltip>
  );
}

/** Listens for the grid's `skippy:note-drop` on the row while [onDrop] is set. */
function useNoteDropTarget(onDrop: ((noteIds: readonly string[]) => void) | undefined) {
  const latest = useRef(onDrop);
  useEffect(() => {
    latest.current = onDrop;
  });
  const [node, setNode] = useState<HTMLDivElement | null>(null);
  const enabled = onDrop !== undefined;
  useEffect(() => {
    if (!node || !enabled) {
      return;
    }
    const listener = (event: Event): void => {
      const detail = (event as CustomEvent<NoteDropDetail>).detail;
      latest.current?.(detail.noteIds);
    };
    node.addEventListener(NOTE_DROP_EVENT, listener);
    return () => node.removeEventListener(NOTE_DROP_EVENT, listener);
  }, [node, enabled]);
  return setNode;
}
