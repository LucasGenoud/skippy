"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import { Archive, ArrowRight, Bell, Bookmark, Folder, FolderPlus, MessagesSquare, Pencil, Plus, Settings, Sparkles, Tag, Trash2, Library, type LucideIcon } from "lucide-react";
import { cn } from "cn";
import { SectionLabel } from "@/components/common/section-label";
import { ContextMenu, ContextMenuContent, ContextMenuItem, ContextMenuSeparator, ContextMenuTrigger } from "@/components/ui/context-menu";
import { Separator } from "@/components/ui/separator";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { navigate } from "@/lib/router";
import {
  isWorkspaceWide,
  useActiveCollection,
  useActiveWorkspace,
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
import { DURATION, prefersReducedMotion } from "@/lib/theme/motion";
import { useChatAvailable, useOpenDestination } from "./shell-actions";
import { useShellDialogs } from "./shell-dialogs";
import { SortableRows } from "./sortable-rows";
import { WorkspaceMenu } from "./workspace-menu";

/** Docked widths, open and as an icon rail (`AppSidebar`). */
export const SIDEBAR_OPEN_PX = 264;
export const SIDEBAR_RAIL_PX = 64;

export type SidebarPlacement = "docked" | "drawer";

/**
 * The sidebar's contents: the workspace switcher, the open workspace's
 * collections, labels and smart views, and the library (reminders, archive,
 * trash). [onNavigate] closes the phone drawer once a row is chosen.
 */
export function SidebarContent({ compact, placement, onNavigate }: { compact: boolean; placement: SidebarPlacement; onNavigate?: () => void }) {
  const destination = useUi((s) => s.destination);
  const workspace = useActiveWorkspace();
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
    <nav aria-label="Main" className="flex flex-col gap-1 py-3">
      <div className="px-2 pb-3">
        <WorkspaceMenu compact={compact} beforeAction={placement === "drawer" ? after : undefined} />
      </div>
      <Collections compact={compact} destination={destination} done={done} after={after} />
      <Separator className="mx-4 my-2 w-auto bg-hairline" />
      <Labels compact={compact} destination={destination} done={done} after={after} />
      <Separator className="mx-4 my-2 w-auto bg-hairline" />
      <SmartViews compact={compact} destination={destination} done={done} after={after} />
      <Separator className="mx-4 my-2 w-auto bg-hairline" />
      <LibraryRows compact={compact} destination={destination} done={done} after={after} />
      {placement === "drawer" && workspace ? <DrawerLinks after={after} /> : null}
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
  const workspaceId = notes.activeWorkspaceId;

  return (
    <section>
      <SectionHeader icon={Folder} label="Collections" compact={compact} />
      <SortableRows items={collections} idOf={(c) => c.id} onMove={(id, index) => notes.moveCollection(id, index)} keyboard="disabled">
        {(c, handle) => (
          <SidebarRow
            icon={labelIconFor(c.icon)}
            fallbackIcon={Folder}
            hasCustomIcon={c.icon !== null}
            iconColor={c.color}
            label={c.name}
            compact={compact}
            selected={active?.id === c.id && !isWorkspaceWide(destination)}
            dragProps={handle.handleProps}
            dragging={handle.dragging}
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
            onEdit={
              workspaceId === null
                ? undefined
                : () => {
                    after(() => dialogs.open({ type: "collection", workspaceId, collectionId: c.id }));
                  }
            }
            editLabel="Collection settings"
            menu={
              workspaceId === null
                ? undefined
                : [
                    { label: "Open", icon: ArrowRight, onSelect: () => open("notes", c.id) },
                    { label: "Collection settings…", icon: Pencil, onSelect: () => dialogs.open({ type: "collection", workspaceId, collectionId: c.id }) },
                    "separator",
                    { label: "New collection…", icon: FolderPlus, onSelect: () => dialogs.open({ type: "collection", workspaceId }) },
                  ]
            }
          />
        )}
      </SortableRows>
      {workspaceId !== null ? (
        <SidebarRow
          icon={Plus}
          label="New collection"
          compact={compact}
          tone="action"
          onClick={() => {
            after(() => dialogs.open({ type: "collection", workspaceId }));
          }}
        />
      ) : null}
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
      <SectionHeader icon={Tag} label="Labels" compact={compact} />
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
          onEdit={() => {
            after(() => dialogs.open({ type: "labelEditor", labelId: label.id }));
          }}
          editLabel="Edit label"
          menu={[
            { label: current === label.id ? "Back to all notes" : "Show notes", icon: ArrowRight, onSelect: () => open(current === label.id ? "notes" : { label: label.id }) },
            { label: "Edit label…", icon: Pencil, onSelect: () => dialogs.open({ type: "labelEditor", labelId: label.id }) },
            "separator",
            {
              label: "Delete label…",
              icon: Trash2,
              tone: "destructive",
              onSelect: () =>
                dialogs.open({
                  type: "confirm",
                  title: `Delete "${label.name}"?`,
                  description: "It comes off every note that has it. The notes themselves stay.",
                  confirmLabel: "Delete label",
                  tone: "destructive",
                  onConfirm: () => notes.deleteLabel(label.id),
                }),
            },
          ]}
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
      <SectionHeader icon={Sparkles} label="Smart views" compact={compact} />
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
          onEdit={() => {
            after(() => dialogs.open({ type: "savedView", savedViewId: view.id }));
          }}
          editLabel="Edit smart view"
          menu={[
            { label: current === view.id ? "Back to all notes" : "Open", icon: ArrowRight, onSelect: () => open(current === view.id ? "notes" : { smartView: view.id }) },
            { label: "Edit smart view…", icon: Pencil, onSelect: () => dialogs.open({ type: "savedView", savedViewId: view.id }) },
          ]}
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
      <SectionHeader icon={Library} label="Library" compact={compact} />
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

/** On a phone the top bar has no room for these, so the drawer carries them. */
function DrawerLinks({ after }: { after: (show: () => void) => void }) {
  const chat = useChatAvailable();
  return (
    <section>
      <Separator className="mx-4 my-2 w-auto bg-hairline" />
      {chat ? (
        <SidebarRow
          icon={MessagesSquare}
          label="Chat with your notes"
          compact={false}
          selected={false}
          onClick={() => {
            after(() => navigate({ name: "chat" }));
          }}
        />
      ) : null}
      <SidebarRow
        icon={Settings}
        label="Settings"
        compact={false}
        selected={false}
        onClick={() => {
          after(() => navigate({ name: "settings", page: null }));
        }}
      />
    </section>
  );
}

function SectionHeader({ icon: Icon, label, compact }: { icon: LucideIcon; label: string; compact: boolean }) {
  return (
    <div aria-hidden={compact || undefined} className={cn("flex h-7 items-center gap-2 px-5 transition-opacity duration-240 ease-standard", compact ? "opacity-0" : "opacity-100")}>
      <Icon aria-hidden className="size-3.5 shrink-0 text-on-surface-variant" />
      <SectionLabel className="truncate px-0">{label}</SectionLabel>
    </div>
  );
}

/**
 * One sidebar entry. The selection is an accent wash plus a short accent bar
 * that grows from the row's middle; both fade, nothing snaps. A rail shows
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
  tone = "default",
  onClick,
  onEdit,
  editLabel,
  dragProps,
  dragging = false,
  onNoteDrop,
  dropTone = "default",
  menu,
}: {
  icon: LucideIcon;
  /** Shown when the entity has no icon of its own. */
  fallbackIcon?: LucideIcon;
  hasCustomIcon?: boolean;
  iconColor?: string | null;
  label: string;
  compact: boolean;
  selected?: boolean;
  /** "action" rows (create, manage) read quieter than destinations. */
  tone?: "default" | "action";
  onClick(): void;
  onEdit?: () => void;
  editLabel?: string;
  dragProps?: Record<string, unknown>;
  dragging?: boolean;
  /** Makes the row a target for cards dragged out of the grid. */
  onNoteDrop?: (noteIds: readonly string[]) => void;
  /** Trash highlights a hovered drop in the error colour. */
  dropTone?: "default" | "danger";
  /** What a right-click on the row offers (desktop). */
  menu?: readonly RowMenuEntry[];
}) {
  const dropRef = useNoteDropTarget(onNoteDrop);
  const Glyph = hasCustomIcon || !fallbackIcon ? Icon : fallbackIcon;
  const tint = labelColor(iconColor);
  const row: ReactNode = (
    <div
      ref={dropRef}
      data-note-drop={onNoteDrop ? "" : undefined}
      className={cn(
        "group/row relative mx-2 flex h-9 items-center rounded-md transition-[background-color,box-shadow] duration-150 ease-standard",
        selected ? "bg-secondary-container" : "hover:bg-hover",
        dragging && "bg-surface shadow-raised",
        dropTone === "danger"
          ? "data-[drop-hover]:bg-error-container data-[drop-hover]:ring-2 data-[drop-hover]:ring-error"
          : "data-[drop-hover]:bg-secondary-container data-[drop-hover]:ring-2 data-[drop-hover]:ring-primary",
      )}
    >
      <span
        aria-hidden
        className={cn(
          "pointer-events-none absolute top-1/2 left-0 h-5 w-[3px] -translate-y-1/2 rounded-xs bg-primary transition-[transform,opacity] duration-150 ease-standard",
          selected ? "scale-y-100 opacity-100" : "scale-y-0 opacity-0",
        )}
      />
      <button
        type="button"
        onClick={onClick}
        aria-current={selected ? "page" : undefined}
        aria-label={compact ? label : undefined}
        {...dragProps}
        className={cn(
          "flex h-full min-w-0 flex-1 items-center gap-3 rounded-md pl-3.5 text-left text-sm outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50",
          tone === "action" ? "text-on-surface-variant/80" : selected ? "font-semibold text-on-secondary-container" : "font-medium text-on-surface",
          dragProps && "touch-none",
        )}
      >
        <Glyph
          aria-hidden
          className={cn("size-[18px] shrink-0", tint ? undefined : selected ? "text-on-secondary-container" : "text-on-surface-variant")}
          style={tint ? { color: tint } : undefined}
        />
        <span className={cn("truncate pr-2 transition-opacity duration-150 ease-standard", compact ? "opacity-0" : "opacity-100")}>{label}</span>
      </button>
      {onEdit && !compact ? (
        <button
          type="button"
          aria-label={`${editLabel ?? "Edit"}: ${label}`}
          onClick={onEdit}
          className="mr-1 inline-flex size-7 shrink-0 items-center justify-center rounded-md text-on-surface-variant opacity-0 transition-opacity duration-150 ease-standard outline-none group-hover/row:opacity-100 hover:bg-hover focus-visible:opacity-100 focus-visible:ring-[3px] focus-visible:ring-ring/50 [@media(hover:none)]:hidden"
        >
          <Pencil className="size-3.5" />
        </button>
      ) : null}
    </div>
  );

  const withMenu = menu ? <RowContextMenu entries={menu}>{row}</RowContextMenu> : row;
  if (!compact) {
    return withMenu;
  }
  return (
    <Tooltip>
      <TooltipTrigger asChild>{withMenu}</TooltipTrigger>
      <TooltipContent side="right">{label}</TooltipContent>
    </Tooltip>
  );
}

type RowMenuEntry = { label: string; icon: LucideIcon; onSelect(): void; tone?: "default" | "destructive" } | "separator";

/** A row's right-click menu: the same actions its click and pencil reach, plus the occasional one. */
function RowContextMenu({ entries, children }: { entries: readonly RowMenuEntry[]; children: ReactNode }) {
  return (
    <ContextMenu>
      <ContextMenuTrigger asChild>{children}</ContextMenuTrigger>
      <ContextMenuContent className="w-56">
        {entries.map((entry, i) =>
          entry === "separator" ? (
            <ContextMenuSeparator key={`separator-${i}`} />
          ) : (
            <ContextMenuItem key={entry.label} variant={entry.tone ?? "default"} onSelect={entry.onSelect}>
              <entry.icon aria-hidden />
              {entry.label}
            </ContextMenuItem>
          ),
        )}
      </ContextMenuContent>
    </ContextMenu>
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
