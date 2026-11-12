"use client";

import { lazy, Suspense, useRef, useState, type ReactNode } from "react";
import {
  CheckSquare,
  Code,
  Columns3,
  Copy,
  CopyPlus,
  Download,
  EllipsisVertical,
  FileText,
  Folder,
  FolderInput,
  Globe,
  History,
  Kanban,
  RotateCcw,
  Tag,
  Trash2,
  UserPlus,
  WandSparkles,
  X,
} from "lucide-react";

import { IconButton } from "@/components/common/icon-button";
import { MenuLabel } from "@/components/common/menu-label";
import { showAppSnack } from "@/components/common/snack";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { NoteLabelPicker } from "@/features/editor/label-picker";
import { isNoteEmpty, type NoteKind } from "@/lib/models/note";
import { closeTo, navigate } from "@/lib/router";
import { useIsRewriting, useNote, useNoteAvailability, useNotesController, useStagesForNote, useWorkspace, useWorkspaces } from "@/lib/store";
import { LabelIcon } from "@/lib/theme/label-style";
import { exportNotes, exportFormatSpec, type ExportFormat } from "@/lib/util/note-export";

import { copyNoteText, duplicateNote, rewriteWithAi, trashNote } from "./note-actions";
import { downloadFile } from "./platform";

// Everything you do *to* a note, flat and split by intent (`note_card/actions.dart`
// menu, `editor/note_actions_button.dart`, `note_actions.dart`, gated by
// `note_availability`). Families that would add several near-identical rows
// (AI rewrites, conversions, card width, destinations) are one submenu each.

const ShareDialog = lazy(() => import("@/features/editor/share-dialog").then((m) => ({ default: m.ShareDialog })));
const PublicLinkDialog = lazy(() => import("@/features/editor/public-link-dialog").then((m) => ({ default: m.PublicLinkDialog })));

const KIND_TARGETS: readonly { kind: NoteKind; label: string; icon: typeof FileText }[] = [
  { kind: "text", label: "Text", icon: FileText },
  { kind: "checklist", label: "Checklist", icon: CheckSquare },
  { kind: "markdown", label: "Markdown", icon: Code },
];

const GRID_SPANS = [1, 2, 3] as const;

const DOWNLOAD_FORMATS: readonly ExportFormat[] = ["markdown", "text", "json"];

type Dialog = "share" | "publicLink" | "deleteForever" | null;

export interface NoteActionsMenuProps {
  noteId: string;
  surface: "card" | "editor";
  /** A custom trigger; defaults to a "more" icon button. */
  children?: ReactNode;
  /** Tells the card its menu is open, so its hover row stays while the pointer is on the menu. */
  onOpenChange?(open: boolean): void;
  /** Editor: closes it after archive, trash or delete. Defaults to closing the note route. */
  onClose?(): void;
  /** Editor: converts the open draft itself (it holds the text being typed). */
  onConvert?(kind: NoteKind): void;
}

export function NoteActionsMenu({ noteId, surface, children, onOpenChange, onClose, onConvert }: NoteActionsMenuProps) {
  const notes = useNotesController();
  const note = useNote(noteId);
  const can = useNoteAvailability(noteId);
  const rewriting = useIsRewriting(noteId);
  const workspace = useWorkspace(note?.workspaceId);
  const workspaces = useWorkspaces();
  const stages = useStagesForNote(noteId);
  const [dialog, setDialog] = useState<Dialog>(null);
  const labelAnchor = useRef<HTMLButtonElement | null>(null);
  // An action that opens something else once the menu has finished closing.
  const afterClose = useRef<(() => void) | null>(null);

  if (!note) {
    return children ? <>{children}</> : null;
  }

  const editor = surface === "editor";
  const close = (): void => (onClose ? onClose() : closeTo());
  /** Runs [action] once the menu has finished closing, so a dialog never opens under it. */
  const queue = (action: () => void): void => {
    afterClose.current = action;
  };


  const trash = (): void => {
    trashNote(notes, note.id);
    if (editor) {
      close();
    }
  };

  const share = (): void => {
    if (isNoteEmpty(note)) {
      showAppSnack("Add some content before sharing");
      return;
    }
    setDialog("share");
  };

  const restore = (collectionId?: string): void => {
    notes.restoreFromTrash(note.id, collectionId);
    showAppSnack("Note restored", { icon: RotateCcw, undo: () => notes.moveToTrash(note.id) });
  };

  const moveToWorkspace = (targetId: string): void => {
    if (targetId === note.workspaceId) {
      return;
    }
    const dropped = note.labelIds.filter((id) => notes.labelById(id)?.workspaceId !== targetId).length;
    notes.moveNoteToWorkspace(note.id, targetId);
    if (dropped > 0) {
      showAppSnack(`${dropped} ${dropped === 1 ? "label was" : "labels were"} removed when moving the note`, { kind: "warning" });
    }
  };

  const convert = (kind: NoteKind): void => (onConvert ? onConvert(kind) : notes.convertKind(note.id, kind));

  const download = (format: ExportFormat): void => {
    const spec = exportFormatSpec(format);
    const content = exportNotes([note], format, { labels: notes.labelsInWorkspace(note.workspaceId), workspaces });
    const base = (note.title.trim() || "note").replace(/[\\/:*?"<>|]+/g, " ").trim().slice(0, 60) || "note";
    downloadFile(`${base}.${spec.extension}`, content, spec.mime);
  };

  const collections = workspace?.collections ?? [];
  const collectionLive = collections.some((c) => c.id === note.collectionId);
  const convertTargets = KIND_TARGETS.filter((t) => t.kind !== note.kind);

  const trigger = children ?? (
    <IconButton
      label={editor ? "Note actions" : "More note options"}
      size="sm"
      icon={<EllipsisVertical />}
      onClick={(event) => event.stopPropagation()}
      onPointerDown={(event) => event.stopPropagation()}
    />
  );

  return (
    <>
      <DropdownMenu modal={false} onOpenChange={onOpenChange}>
        <DropdownMenuTrigger asChild>{trigger}</DropdownMenuTrigger>
        <DropdownMenuContent
          align="end"
          className="w-64"
          onClick={(event) => event.stopPropagation()}
          onCloseAutoFocus={(event) => {
            const action = afterClose.current;
            afterClose.current = null;
            if (action) {
              event.preventDefault();
              action();
            }
          }}
        >
          {note.trashed ? (
            <>
              {collectionLive || collections.length === 0 ? (
                <DropdownMenuItem onSelect={() => restore()}>
                  <RotateCcw />
                  <MenuLabel label="Restore" hint="Back to its collection" />
                </DropdownMenuItem>
              ) : (
                <DropdownMenuSub>
                  <DropdownMenuSubTrigger>
                    <RotateCcw />
                    <MenuLabel label="Restore to…" hint="Its collection is gone" />
                  </DropdownMenuSubTrigger>
                  <DropdownMenuSubContent>
                    {collections.map((c) => (
                      <DropdownMenuItem key={c.id} onSelect={() => restore(c.id)}>
                        {c.icon ? <LabelIcon iconKey={c.icon} /> : <Folder />}
                        <span className="truncate">{c.name}</span>
                      </DropdownMenuItem>
                    ))}
                  </DropdownMenuSubContent>
                </DropdownMenuSub>
              )}
              {can.canCopy ? (
                <DropdownMenuItem onSelect={() => void copyNoteText(note)}>
                  <Copy />
                  <MenuLabel label="Copy to clipboard" hint="As plain text" />
                </DropdownMenuItem>
              ) : null}
              {can.canShowHistory ? (
                <DropdownMenuItem onSelect={() => navigate({ name: "history", noteId: note.id })}>
                  <History />
                  <MenuLabel label="Version history" hint="Restore an earlier copy" />
                </DropdownMenuItem>
              ) : null}
              {can.isOwner ? (
                <>
                  <DropdownMenuSeparator />
                  <DropdownMenuItem variant="destructive" onSelect={() => queue(() => setDialog("deleteForever"))}>
                    <X />
                    <MenuLabel label="Delete forever" hint="Cannot be undone" tone="destructive" />
                  </DropdownMenuItem>
                </>
              ) : null}
            </>
          ) : (
            <>
              {can.canRewrite && !editor ? (
                <>
                  <DropdownMenuSub>
                    <DropdownMenuSubTrigger disabled={rewriting}>
                      <WandSparkles />
                      <MenuLabel label="AI edit" hint={rewriting ? "Working…" : "Rewrite with AI"} />
                    </DropdownMenuSubTrigger>
                    <DropdownMenuSubContent>
                      {can.rewriteTasks.map((task) => (
                        <DropdownMenuItem key={task.id} disabled={rewriting} onSelect={() => void rewriteWithAi(notes, note.id, task)}>
                          <WandSparkles />
                          <span className="truncate">{task.name}</span>
                        </DropdownMenuItem>
                      ))}
                    </DropdownMenuSubContent>
                  </DropdownMenuSub>
                  <DropdownMenuSeparator />
                </>
              ) : null}


              {can.canEdit ? (
                <DropdownMenuItem onSelect={() => queue(() => labelAnchor.current?.click())}>
                  <Tag />
                  <MenuLabel label="Labels" hint="Add or remove" />
                </DropdownMenuItem>
              ) : null}
              {can.canEdit ? (
                <DropdownMenuItem onSelect={() => queue(share)}>
                  <UserPlus />
                  <MenuLabel label="Collaborators" hint="Share with people" />
                </DropdownMenuItem>
              ) : null}
              {can.canEdit && !isNoteEmpty(note) ? (
                <DropdownMenuItem onSelect={() => queue(() => setDialog("publicLink"))}>
                  <Globe />
                  <MenuLabel label="Public link" hint="Anyone with the link" />
                </DropdownMenuItem>
              ) : null}
              <DropdownMenuItem disabled={!can.canCopy} onSelect={() => void copyNoteText(note)}>
                <Copy />
                <MenuLabel label="Copy to clipboard" hint="As plain text" />
              </DropdownMenuItem>
              <DropdownMenuItem disabled={!can.canDuplicate} onSelect={() => duplicateNote(notes, note.id)}>
                <CopyPlus />
                <MenuLabel label="Duplicate" hint="Make a copy" />
              </DropdownMenuItem>

              {can.canEdit && !editor && convertTargets.length > 0 ? (
                <DropdownMenuSub>
                  <DropdownMenuSubTrigger>
                    <FileText />
                    <MenuLabel label="Turn into" hint="Another kind of note" />
                  </DropdownMenuSubTrigger>
                  <DropdownMenuSubContent>
                    {convertTargets.map(({ kind, label, icon: Icon }) => (
                      <DropdownMenuItem key={kind} onSelect={() => convert(kind)}>
                        <Icon />
                        {label}
                      </DropdownMenuItem>
                    ))}
                  </DropdownMenuSubContent>
                </DropdownMenuSub>
              ) : null}

              {can.canSetGridSpan ? (
                <DropdownMenuSub>
                  <DropdownMenuSubTrigger>
                    <Columns3 />
                    <MenuLabel label="Card width" hint={note.gridSpan === 1 ? "Standard" : `${note.gridSpan} columns`} />
                  </DropdownMenuSubTrigger>
                  <DropdownMenuSubContent>
                    <DropdownMenuRadioGroup value={String(note.gridSpan)} onValueChange={(value) => notes.setGridSpan(note.id, Number(value))}>
                      {GRID_SPANS.map((span) => (
                        <DropdownMenuRadioItem key={span} value={String(span)}>
                          {span === 1 ? "Standard" : `${span} columns`}
                        </DropdownMenuRadioItem>
                      ))}
                    </DropdownMenuRadioGroup>
                  </DropdownMenuSubContent>
                </DropdownMenuSub>
              ) : null}

              {can.canMoveToStage || can.canMoveToCollection || can.canMoveToWorkspace ? <DropdownMenuSeparator /> : null}

              {can.canMoveToStage ? (
                <DropdownMenuSub>
                  <DropdownMenuSubTrigger>
                    <Kanban />
                    <MenuLabel label="Move to column" hint="Another column on this board" />
                  </DropdownMenuSubTrigger>
                  <DropdownMenuSubContent>
                    <DropdownMenuRadioGroup value={note.stageId ?? ""} onValueChange={(value) => notes.setNoteStage(note.id, value === "" ? null : value)}>
                      {stages.map((stage) => (
                        <DropdownMenuRadioItem key={stage.id} value={stage.id}>
                          <span className="truncate">{stage.name}</span>
                        </DropdownMenuRadioItem>
                      ))}
                      <DropdownMenuRadioItem value="">Unassigned</DropdownMenuRadioItem>
                    </DropdownMenuRadioGroup>
                  </DropdownMenuSubContent>
                </DropdownMenuSub>
              ) : null}

              {can.canMoveToCollection && collections.length > 0 ? (
                <DropdownMenuSub>
                  <DropdownMenuSubTrigger>
                    <Folder />
                    <MenuLabel label="Move to collection" hint="Within this workspace" />
                  </DropdownMenuSubTrigger>
                  <DropdownMenuSubContent>
                    <DropdownMenuRadioGroup
                      value={note.collectionId ?? ""}
                      onValueChange={(value) => {
                        if (value !== note.collectionId) {
                          notes.moveToCollection(note.id, value);
                        }
                      }}
                    >
                      {collections.map((c) => (
                        <DropdownMenuRadioItem key={c.id} value={c.id}>
                          <span className="truncate">{c.name}</span>
                        </DropdownMenuRadioItem>
                      ))}
                    </DropdownMenuRadioGroup>
                  </DropdownMenuSubContent>
                </DropdownMenuSub>
              ) : null}

              {can.canMoveToWorkspace ? (
                <DropdownMenuSub>
                  <DropdownMenuSubTrigger>
                    <FolderInput />
                    <MenuLabel label="Move to workspace" hint="To another workspace" />
                  </DropdownMenuSubTrigger>
                  <DropdownMenuSubContent>
                    <DropdownMenuRadioGroup value={note.workspaceId} onValueChange={moveToWorkspace}>
                      {workspaces.map((w) => (
                        <DropdownMenuRadioItem key={w.id} value={w.id}>
                          <span className="truncate">{w.name}</span>
                        </DropdownMenuRadioItem>
                      ))}
                    </DropdownMenuRadioGroup>
                  </DropdownMenuSubContent>
                </DropdownMenuSub>
              ) : null}

              <DropdownMenuSeparator />

              {can.canShowHistory ? (
                <DropdownMenuItem onSelect={() => navigate({ name: "history", noteId: note.id })}>
                  <History />
                  <MenuLabel label="Version history" hint="Restore an earlier copy" />
                </DropdownMenuItem>
              ) : null}
              {!isNoteEmpty(note) ? (
                <DropdownMenuSub>
                  <DropdownMenuSubTrigger>
                    <Download />
                    <MenuLabel label="Download" hint="As a file" />
                  </DropdownMenuSubTrigger>
                  <DropdownMenuSubContent>
                    {DOWNLOAD_FORMATS.map((format) => (
                      <DropdownMenuItem key={format} onSelect={() => download(format)}>
                        {exportFormatSpec(format).label}
                      </DropdownMenuItem>
                    ))}
                  </DropdownMenuSubContent>
                </DropdownMenuSub>
              ) : null}
              <DropdownMenuItem variant={can.canTrash ? "destructive" : "default"} disabled={!can.canTrash} onSelect={trash}>
                <Trash2 />
                <MenuLabel label={can.canTrash ? "Move to Trash" : "Only the owner can delete"} hint={can.canTrash ? "Undo for a moment" : undefined} tone={can.canTrash ? "destructive" : "default"} />
              </DropdownMenuItem>
            </>
          )}
        </DropdownMenuContent>
      </DropdownMenu>

      {/* The labels picker opens from the menu's place once the menu has closed. */}
      {can.canEdit && !note.trashed ? (
        <NoteLabelPicker noteIds={[note.id]}>
          <button ref={labelAnchor} type="button" tabIndex={-1} aria-hidden className="pointer-events-none absolute size-0 opacity-0" onClick={(e) => e.stopPropagation()} />
        </NoteLabelPicker>
      ) : null}

      <Suspense fallback={null}>
        {dialog === "share" ? <ShareDialog noteId={note.id} open onOpenChange={(open) => !open && setDialog(null)} /> : null}
        {dialog === "publicLink" ? <PublicLinkDialog noteId={note.id} open onOpenChange={(open) => !open && setDialog(null)} /> : null}
      </Suspense>

      <AlertDialog open={dialog === "deleteForever"} onOpenChange={(open) => !open && setDialog(null)}>
        <AlertDialogContent onClick={(event) => event.stopPropagation()}>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete forever?</AlertDialogTitle>
            <AlertDialogDescription>This note and its files will be permanently deleted.</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                notes.deleteForever(note.id);
                if (editor) {
                  close();
                }
              }}
            >
              Delete forever
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}
