"use client";

import { lazy, Suspense, useEffect, useRef, useState, type ReactNode } from "react";
import {
  Archive,
  BellPlus,
  CalendarDays,
  CheckSquare,
  CircleAlert,
  Code,
  EllipsisVertical,
  FileText,
  ImagePlus,
  Palette,
  Paperclip,
  Plus,
  Tag,
  Trash2,
  UserPlus,
  X,
} from "lucide-react";
import { AnimatePresence, motion } from "motion/react";
import { cn } from "cn";

import { AppLogo } from "@/components/common/app-logo";
import { BackgroundPicker } from "@/components/common/color-picker";
import { IconButton } from "@/components/common/icon-button";
import { MenuLabel } from "@/components/common/menu-label";
import { NotePattern } from "@/components/common/note-pattern";
import { REPEAT_LABELS, formatWhen } from "@/components/common/reminder-format";
import { ReminderPicker } from "@/components/common/reminder-picker";
import { showAppSnack } from "@/components/common/snack";
import { Button } from "@/components/ui/button";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuSeparator, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { TooltipProvider } from "@/components/ui/tooltip";
import { makeNote, type ChecklistItem, type NoteKind, type NotePattern as NotePatternId, type ReminderRepeat } from "@/lib/models/note";
import { convertNoteKind } from "@/lib/state/note-conversion";
import { useLabels, useNotesController, useSettings } from "@/lib/store";
import { LabelIcon, labelStyle } from "@/lib/theme/label-style";
import { TRANSITION } from "@/lib/theme/motion";
import { noteColor } from "@/lib/theme/palette";
import { newId } from "@/lib/util/id";

import { droppedFile, filesWithinLimit, toggleArchive, uploadFiles } from "./note-actions";
import { PinIcon } from "./pin-icon";
import { pickFiles, useBrightness } from "./platform";
import { QuickAddChecklist } from "./quick-add-checklist";
import { Spinner } from "./link-summary-indicator";

const ShareDialog = lazy(() => import("@/features/editor/share-dialog").then((m) => ({ default: m.ShareDialog })));

const CONVERT: readonly { kind: NoteKind; label: string; icon: typeof FileText }[] = [
  { kind: "text", label: "Convert to text note", icon: FileText },
  { kind: "checklist", label: "Convert to checklist", icon: CheckSquare },
  { kind: "markdown", label: "Convert to markdown note", icon: Code },
];

interface Draft {
  kind: NoteKind;
  title: string;
  content: string;
  items: readonly ChecklistItem[];
  color: string;
  pattern: NotePatternId;
  labelIds: readonly string[];
  reminder: { at: Date; repeat?: ReminderRepeat } | null;
  pinned: boolean;
  files: readonly File[];
}

const emptyDraft = (kind: NoteKind, labelIds: readonly string[]): Draft => ({
  kind,
  title: "",
  content: "",
  items: [],
  color: "default",
  pattern: "none",
  labelIds,
  reminder: null,
  pinned: false,
  files: [],
});

/** Whether a draft is worth a note. A reminder counts: it is an alarm someone set. */
export function draftHasContent(draft: Pick<Draft, "kind" | "title" | "content" | "items" | "files" | "reminder">): boolean {
  if (draft.title.trim() !== "" || draft.files.length > 0 || draft.reminder !== null) {
    return true;
  }
  if (draft.kind === "checklist") {
    return draft.items.some((i) => i.text.trim() !== "");
  }
  return draft.content.trim() !== "";
}

/**
 * Inline quick add above the grid (`quick_add_bar.dart`): pick a kind and
 * compose the whole note in place. Close, a click outside and Escape all save
 * (an empty composer just collapses). Everything a note can carry is held
 * locally until the note is created, so an abandoned composer leaves nothing
 * behind and the properties ride along on the create request.
 */
export function QuickAddBar({ labelIds }: { labelIds: readonly string[] }) {
  const notes = useNotesController();
  const palette = useSettings((s) => s.palette);
  const use24h = useSettings((s) => s.use24hTime);
  const brightness = useBrightness();
  const [draft, setDraft] = useState<Draft | null>(null);
  const [checklistFocus, setChecklistFocus] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [shareId, setShareId] = useState<string | null>(null);
  const root = useRef<HTMLDivElement | null>(null);
  const titleRef = useRef<HTMLInputElement | null>(null);
  const bodyRef = useRef<HTMLTextAreaElement | null>(null);
  // A picker, menu or file dialog of ours is open: a click on it is not a click outside.
  const modalOpen = useRef(0);
  const draftRef = useRef(draft);
  useEffect(() => {
    draftRef.current = draft;
  }, [draft]);

  const addFiles = (picked: readonly File[]): void => {
    const kept = filesWithinLimit(picked);
    if (kept.length > 0) {
      setDraft((d) => (d ? { ...d, files: [...d.files, ...kept] } : d));
    }
  };

  const patch = (change: Partial<Draft>): void => setDraft((d) => (d ? { ...d, ...change } : d));

  const expand = (kind: NoteKind): void => {
    setDraft(emptyDraft(kind, labelIds));
    setChecklistFocus(false);
    requestAnimationFrame(() => titleRef.current?.focus());
  };

  /** Creates the note from the draft; null when there was nothing to keep. */
  const commit = (current: Draft): string | null => {
    if (!draftHasContent(current)) {
      return null;
    }
    const note = notes.createDraft({ kind: current.kind, labelIds: current.labelIds });
    // Properties first, while the note is still a draft: they ride on the create request.
    if (current.color !== "default") {
      notes.setColor(note.id, current.color);
    }
    if (current.pattern !== "none") {
      notes.setPattern(note.id, current.pattern);
    }
    if (current.reminder) {
      notes.setReminder(note.id, current.reminder.at, current.reminder.repeat ?? null);
    }
    if (current.pinned) {
      notes.togglePin(note.id);
    }
    if (current.kind === "checklist") {
      notes.updateNoteContent(note.id, { title: current.title, items: current.items.filter((i) => i.text.trim() !== "") });
    } else {
      notes.updateNoteContent(note.id, { title: current.title, content: current.content });
    }
    if (current.files.length > 0) {
      void uploadFiles(notes, note.id, current.files);
    }
    return note.id;
  };

  const saveAndCollapse = (): void => {
    const current = draftRef.current;
    if (!current || modalOpen.current > 0) {
      return;
    }
    commit(current);
    setDraft(null);
  };

  // A click anywhere outside saves and collapses.
  useEffect(() => {
    if (!draft) {
      return;
    }
    const onDown = (event: PointerEvent): void => {
      const target = event.target as Node | null;
      if (!target || root.current?.contains(target) || modalOpen.current > 0) {
        return;
      }
      // Portalled popovers of ours count as inside.
      if (target instanceof Element && target.closest("[data-radix-popper-content-wrapper],[role=dialog]")) {
        return;
      }
      saveAndCollapse();
    };
    document.addEventListener("pointerdown", onDown, true);
    return () => document.removeEventListener("pointerdown", onDown, true);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [draft !== null]);

  // A paste of files lands on the note being composed, like a pick.
  useEffect(() => {
    if (!draft) {
      return;
    }
    const onPaste = (event: ClipboardEvent): void => {
      const files = Array.from(event.clipboardData?.files ?? []);
      if (files.length === 0 || !root.current?.contains(document.activeElement)) {
        return;
      }
      event.preventDefault();
      addFiles(files);
    };
    document.addEventListener("paste", onPaste);
    return () => document.removeEventListener("paste", onPaste);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [draft !== null]);

  const withModal = async (action: () => Promise<void>): Promise<void> => {
    modalOpen.current++;
    try {
      await action();
    } finally {
      modalOpen.current--;
    }
  };

  const tracked = (open: boolean): void => {
    modalOpen.current = Math.max(0, modalOpen.current + (open ? 1 : -1));
  };

  const pick = (accept?: string) => withModal(async () => addFiles(await pickFiles({ accept, multiple: !accept })));

  const quickImageNote = async (): Promise<void> => {
    const picked = filesWithinLimit(await pickFiles({ accept: "image/*" }));
    if (picked.length === 0) {
      return;
    }
    setUploading(true);
    try {
      const id = await notes.createNoteWithFiles(picked.map(droppedFile), labelIds);
      if (id === null) {
        showAppSnack("Couldn't upload the image", { icon: CircleAlert, kind: "danger" });
      }
    } finally {
      setUploading(false);
    }
  };

  const share = (): void => {
    const current = draftRef.current;
    if (!current || !draftHasContent(current)) {
      showAppSnack("Add some content before sharing");
      return;
    }
    const id = commit(current);
    setDraft(null);
    setShareId(id);
  };

  const archive = (): void => {
    const current = draftRef.current;
    const id = current ? commit(current) : null;
    setDraft(null);
    const note = id ? notes.noteById(id) : null;
    if (note) {
      toggleArchive(notes, note);
    }
  };

  const convert = (target: NoteKind): void => {
    const current = draftRef.current;
    if (!current || target === current.kind) {
      return;
    }
    const converted = convertNoteKind(makeNote({ id: "", kind: current.kind, title: current.title, content: current.content, items: current.items }), target, newId);
    patch({ kind: target, content: converted.content, items: converted.items });
    setChecklistFocus(true);
    if (target !== "checklist") {
      requestAnimationFrame(() => bodyRef.current?.focus());
    }
  };

  const fill = draft ? noteColor(draft.color, brightness, palette) : null;

  return (
    <TooltipProvider>
      <motion.div
        ref={root}
        layout
        transition={TRANSITION.base}
        className="relative overflow-hidden rounded-md border border-outline-variant bg-surface shadow-raised"
        style={fill ? { background: fill } : undefined}
        onKeyDown={(event) => {
          if (event.key === "Escape" && draft) {
            event.stopPropagation();
            saveAndCollapse();
          }
        }}
      >
        {draft ? <NotePattern pattern={draft.pattern} /> : null}
        <AnimatePresence initial={false} mode="popLayout">
          {draft ? (
            <motion.div key="composer" className="relative" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0, transition: { duration: 0 } }} transition={TRANSITION.base}>
              <div className="px-4 pt-2">
                <div className="flex items-start gap-1">
                  <input
                    ref={titleRef}
                    value={draft.title}
                    placeholder="Title"
                    aria-label="Title"
                    onChange={(event) => patch({ title: event.target.value })}
                    onKeyDown={(event) => {
                      if (event.key === "Enter" || (event.key === "Tab" && !event.shiftKey && draft.kind !== "checklist")) {
                        if (draft.kind !== "checklist") {
                          event.preventDefault();
                          bodyRef.current?.focus();
                        }
                      }
                    }}
                    className="min-w-0 flex-1 bg-transparent py-2 text-base font-semibold outline-none placeholder:text-on-surface-variant"
                  />
                  <IconButton label={draft.pinned ? "Unpin" : "Pin"} size="sm" icon={<PinIcon pinned={draft.pinned} />} onClick={() => patch({ pinned: !draft.pinned })} />
                </div>
                {draft.kind === "checklist" ? (
                  <QuickAddChecklist items={draft.items} onChange={(items) => patch({ items })} autoFocus={checklistFocus} />
                ) : (
                  <AutoGrowArea
                    ref={bodyRef}
                    value={draft.content}
                    placeholder={draft.kind === "markdown" ? "Markdown…" : "Take a note…"}
                    monospace={draft.kind === "markdown"}
                    onChange={(content) => patch({ content })}
                  />
                )}
                <PendingFiles files={draft.files} onRemove={(file) => patch({ files: draft.files.filter((f) => f !== file) })} />
                <MetaChips
                  draft={draft}
                  use24h={use24h}
                  onClearReminder={() => patch({ reminder: null })}
                  onRemoveLabel={(id) => patch({ labelIds: draft.labelIds.filter((l) => l !== id) })}
                />
              </div>
              <div className="flex items-center gap-0.5 px-2 py-1">
                <Popover onOpenChange={tracked}>
                  <PopoverTrigger asChild>
                    <IconButton label="Note color" size="sm" icon={<Palette />} />
                  </PopoverTrigger>
                  <PopoverContent className="w-[332px]">
                    <BackgroundPicker
                      color={draft.color}
                      onColorChange={(color) => patch({ color })}
                      pattern={draft.pattern}
                      onPatternChange={(pattern) => patch({ pattern })}
                      brightness={brightness}
                      palette={palette}
                    />
                  </PopoverContent>
                </Popover>
                <DraftLabelPicker selected={draft.labelIds} onChange={(ids) => patch({ labelIds: ids })} onOpenChange={tracked}>
                  <IconButton label="Labels" size="sm" icon={<Tag />} />
                </DraftLabelPicker>
                <ReminderButton value={draft.reminder} use24h={use24h} onChange={(reminder) => patch({ reminder })} onOpenChange={tracked} />
                <IconButton label="Add image" size="sm" icon={<ImagePlus />} onClick={() => void pick("image/*")} />
                <IconButton label="Attach file" size="sm" icon={<Paperclip />} onClick={() => void pick()} />
                <IconButton label="Collaborators" size="sm" icon={<UserPlus />} onClick={share} />
                <IconButton label="Archive" size="sm" icon={<Archive />} onClick={archive} />
                <DropdownMenu modal={false} onOpenChange={tracked}>
                  <DropdownMenuTrigger asChild>
                    <IconButton label="More" size="sm" icon={<EllipsisVertical />} />
                  </DropdownMenuTrigger>
                  <DropdownMenuContent align="start" className="w-60">
                    {CONVERT.filter((c) => c.kind !== draft.kind).map(({ kind, label, icon: Icon }) => (
                      <DropdownMenuItem key={kind} onSelect={() => convert(kind)}>
                        <Icon />
                        <MenuLabel label={label} />
                      </DropdownMenuItem>
                    ))}
                    <DropdownMenuSeparator />
                    <DropdownMenuItem variant="destructive" onSelect={() => setDraft(null)}>
                      <Trash2 />
                      <MenuLabel label="Discard note" tone="destructive" />
                    </DropdownMenuItem>
                  </DropdownMenuContent>
                </DropdownMenu>
                <span className="flex-1" />
                <Button variant="ghost" size="sm" onClick={saveAndCollapse}>
                  Close
                </Button>
              </div>
            </motion.div>
          ) : (
            <motion.div key="bar" className="relative flex cursor-text items-center gap-2 py-1 pr-1 pl-3" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0, transition: { duration: 0 } }} transition={TRANSITION.base} onClick={() => expand("text")}>
              <AppLogo size={22} />
              <span className="flex-1 text-base text-on-surface-variant">Take a note…</span>
              <span className="flex items-center" onClick={(event) => event.stopPropagation()}>
                <IconButton label="New checklist" icon={<CheckSquare />} onClick={() => expand("checklist")} />
                <IconButton label="New markdown note" icon={<Code />} onClick={() => expand("markdown")} />
                <AnimatePresence initial={false} mode="popLayout">
                  {uploading ? (
                    <motion.span key="spin" className="inline-flex size-9 items-center justify-center" initial={{ opacity: 0, scale: 0.6 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0, scale: 0.6 }} transition={TRANSITION.fast}>
                      <Spinner className="size-[18px]" />
                    </motion.span>
                  ) : (
                    <motion.span key="image" className="inline-flex" initial={{ opacity: 0, scale: 0.6 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0, scale: 0.6 }} transition={TRANSITION.fast}>
                      <IconButton label="New note with image" icon={<ImagePlus />} onClick={() => void quickImageNote()} />
                    </motion.span>
                  )}
                </AnimatePresence>
              </span>
            </motion.div>
          )}
        </AnimatePresence>
      </motion.div>
      <Suspense fallback={null}>{shareId ? <ShareDialog noteId={shareId} open onOpenChange={(open) => !open && setShareId(null)} /> : null}</Suspense>
    </TooltipProvider>
  );
}

function AutoGrowArea({
  ref,
  value,
  placeholder,
  monospace,
  onChange,
}: {
  ref: React.Ref<HTMLTextAreaElement>;
  value: string;
  placeholder: string;
  monospace: boolean;
  onChange: (value: string) => void;
}) {
  return (
    <textarea
      ref={ref}
      value={value}
      rows={2}
      placeholder={placeholder}
      aria-label="Note"
      onChange={(event) => onChange(event.target.value)}
      className={cn(
        "field-sizing-content block min-h-12 w-full resize-none bg-transparent py-2 outline-none placeholder:text-on-surface-variant",
        monospace ? "font-mono text-sm leading-[1.4]" : "text-base leading-[1.4]",
      )}
    />
  );
}

/** Images and files picked while composing, removable until the note is saved. */
function PendingFiles({ files, onRemove }: { files: readonly File[]; onRemove: (file: File) => void }) {
  const [urls] = useState(() => new Map<File, string>());
  useEffect(() => () => urls.forEach((url) => URL.revokeObjectURL(url)), [urls]);
  if (files.length === 0) {
    return null;
  }
  const urlFor = (file: File): string => {
    let url = urls.get(file);
    if (!url) {
      url = URL.createObjectURL(file);
      urls.set(file, url);
    }
    return url;
  };
  return (
    <div className="flex flex-wrap gap-2 pt-2.5">
      <AnimatePresence initial={false}>
        {files.map((file, i) => (
          <motion.div key={`${file.name}-${i}`} initial={{ opacity: 0, scale: 0.9 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0, scale: 0.9 }} transition={TRANSITION.fast} className="relative">
            {file.type.startsWith("image/") ? (
              <>
                <img src={urlFor(file)} alt={file.name} className="size-[72px] rounded-md object-cover" />
                <button
                  type="button"
                  aria-label={`Remove ${file.name}`}
                  onClick={() => onRemove(file)}
                  className="absolute top-0.5 right-0.5 inline-flex size-5 items-center justify-center rounded-md bg-black/55 text-white outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50"
                >
                  <X aria-hidden className="size-3.5" />
                </button>
              </>
            ) : (
              <span className="inline-flex h-7 max-w-56 items-center gap-1.5 rounded-md border border-outline-variant pr-1 pl-2 text-xs">
                <FileText aria-hidden className="size-4 shrink-0 text-on-surface-variant" />
                <span className="truncate">{file.name}</span>
                <button type="button" aria-label={`Remove ${file.name}`} onClick={() => onRemove(file)} className="inline-flex size-5 items-center justify-center rounded-xs hover:bg-hover">
                  <X aria-hidden className="size-3.5" />
                </button>
              </span>
            )}
          </motion.div>
        ))}
      </AnimatePresence>
    </div>
  );
}

/** The reminder and labels the note will be born with, each removable. */
function MetaChips({ draft, use24h, onClearReminder, onRemoveLabel }: { draft: Draft; use24h: boolean; onClearReminder: () => void; onRemoveLabel: (id: string) => void }) {
  const labels = useLabels();
  const chosen = labels.filter((l) => draft.labelIds.includes(l.id)).sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()));
  if (!draft.reminder && chosen.length === 0) {
    return null;
  }
  return (
    <div className="flex flex-wrap gap-2 pt-2.5">
      {draft.reminder ? (
        <span className="inline-flex h-7 items-center gap-1.5 rounded-md bg-on-surface/8 pr-1 pl-2 text-xs">
          <CalendarDays aria-hidden className="size-4 text-on-surface-variant" />
          {formatWhen(draft.reminder.at, { use24h })}
          {draft.reminder.repeat ? ` · ${REPEAT_LABELS[draft.reminder.repeat]}` : ""}
          <button type="button" aria-label="Remove reminder" onClick={onClearReminder} className="inline-flex size-5 items-center justify-center rounded-xs hover:bg-hover">
            <X aria-hidden className="size-3.5" />
          </button>
        </span>
      ) : null}
      {chosen.map((label) => (
        <span key={label.id} className="inline-flex h-7 items-center gap-1.5 rounded-md border pr-1 pl-2 text-xs" style={labelStyle(label.color)}>
          <LabelIcon iconKey={label.icon} aria-hidden className="size-3.5" />
          {label.name}
          <button type="button" aria-label={`Remove ${label.name}`} onClick={() => onRemoveLabel(label.id)} className="inline-flex size-5 items-center justify-center rounded-xs hover:bg-hover">
            <X aria-hidden className="size-3.5" />
          </button>
        </span>
      ))}
    </div>
  );
}

function ReminderButton({
  value,
  use24h,
  onChange,
  onOpenChange,
}: {
  value: Draft["reminder"];
  use24h: boolean;
  onChange: (value: Draft["reminder"]) => void;
  onOpenChange: (open: boolean) => void;
}) {
  const [open, setOpen] = useState(false);
  const set = (next: boolean): void => {
    setOpen(next);
    onOpenChange(next);
  };
  return (
    <Popover open={open} onOpenChange={set}>
      <PopoverTrigger asChild>
        <IconButton label="Remind me" size="sm" icon={<BellPlus />} />
      </PopoverTrigger>
      <PopoverContent className="w-[360px]">
        <ReminderPicker
          value={value}
          use24h={use24h}
          onChange={(next) => {
            onChange(next);
            set(false);
          }}
        />
      </PopoverContent>
    </Popover>
  );
}

/** Labels for a note that does not exist yet: toggles on a local set, plus creating one. */
function DraftLabelPicker({
  selected,
  onChange,
  onOpenChange,
  children,
}: {
  selected: readonly string[];
  onChange: (ids: readonly string[]) => void;
  onOpenChange: (open: boolean) => void;
  children: ReactNode;
}) {
  const notes = useNotesController();
  const labels = useLabels();
  const [query, setQuery] = useState("");
  const trimmed = query.trim();
  const shown = labels.filter((l) => l.name.toLowerCase().includes(trimmed.toLowerCase()));
  const exact = labels.some((l) => l.name.toLowerCase() === trimmed.toLowerCase());
  const toggle = (id: string): void => onChange(selected.includes(id) ? selected.filter((s) => s !== id) : [...selected, id]);
  return (
    <Popover onOpenChange={onOpenChange}>
      <PopoverTrigger asChild>{children}</PopoverTrigger>
      <PopoverContent className="w-64 p-1">
        <input
          value={query}
          placeholder="Find or create a label"
          aria-label="Find or create a label"
          onChange={(event) => setQuery(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && trimmed && !exact) {
              const label = notes.createLabel(trimmed);
              toggle(label.id);
              setQuery("");
            }
          }}
          className="mb-1 h-8 w-full rounded-sm bg-transparent px-2 text-sm outline-none placeholder:text-on-surface-variant"
        />
        <div className="max-h-64 overflow-y-auto">
          {shown.map((label) => {
            const on = selected.includes(label.id);
            return (
              <button
                key={label.id}
                type="button"
                role="menuitemcheckbox"
                aria-checked={on}
                onClick={() => toggle(label.id)}
                className="flex h-8 w-full items-center gap-2 rounded-sm px-2 text-left text-sm outline-none hover:bg-hover focus-visible:bg-hover"
              >
                <LabelIcon iconKey={label.icon} aria-hidden className="size-4 shrink-0" style={label.color ? { color: label.color } : undefined} />
                <span className="flex-1 truncate">{label.name}</span>
                <span
                  className={cn(
                    "inline-flex size-4 items-center justify-center rounded-check border transition-colors duration-150 ease-standard",
                    on ? "border-primary-container bg-primary-container text-on-primary-container" : "border-outline",
                  )}
                >
                  {on ? (
                    <svg viewBox="0 0 16 16" aria-hidden className="size-3">
                      <path d="M3.5 8.5l3 3 6-7" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />
                    </svg>
                  ) : null}
                </span>
              </button>
            );
          })}
          {trimmed && !exact ? (
            <button
              type="button"
              onClick={() => {
                const label = notes.createLabel(trimmed);
                toggle(label.id);
                setQuery("");
              }}
              className="flex h-8 w-full items-center gap-2 rounded-sm px-2 text-left text-sm outline-none hover:bg-hover focus-visible:bg-hover"
            >
              <Plus aria-hidden className="size-4" />
              <span className="truncate">Create “{trimmed}”</span>
            </button>
          ) : null}
          {labels.length === 0 && !trimmed ? <p className="px-2 py-1.5 text-xs text-on-surface-variant">Type a name to create a label</p> : null}
        </div>
      </PopoverContent>
    </Popover>
  );
}
