import { aiAllows, type WorkspaceAi } from "@/lib/models/workspace";
import { isNoteEmpty, isNoteOwnedBy, type Note, type NoteRewriteTask, type Stage, type Workspace } from "@/lib/models";

// Which actions a note offers right now, so the card's menu and the editor's
// cannot disagree. A null note is the editor's unsaved draft. Ported from
// `state/note_availability.dart`.

/** What availability needs from the notes store. */
export interface AvailabilitySource {
  readonly currentUserId: string | null;
  readonly workspaces: readonly Workspace[];
  canAutoDiscard(id: string): boolean;
  aiIn(workspaceId: string | null | undefined): WorkspaceAi;
  workspaceById(id: string | null | undefined): Workspace | null;
  stagesForNote(note: Note | null): Stage[];
}

export interface NoteAvailability {
  /** Trash and moving between workspaces are the owner's calls. */
  readonly isOwner: boolean;
  /** Everything except reading is off in Trash. */
  readonly canEdit: boolean;
  readonly canArchive: boolean;
  readonly canTrash: boolean;
  readonly canCopy: boolean;
  readonly canDuplicate: boolean;
  readonly canShowHistory: boolean;
  readonly canSetGridSpan: boolean;
  readonly canMoveToCollection: boolean;
  readonly canMoveToWorkspace: boolean;
  readonly canMoveToStage: boolean;
  /** AI editing follows the note's workspace: its switch, its owner's tasks. */
  readonly canRewrite: boolean;
  readonly rewriteTasks: readonly NoteRewriteTask[];
  /** A page summary is appended to the body, which checklists and audio lack. */
  readonly canSummarizeLinks: boolean;
}

export function noteAvailability(source: AvailabilitySource, note: Note | null): NoteAvailability {
  const live = !(note?.trashed ?? false);
  const hasContent = note !== null && !isNoteEmpty(note);
  // An empty draft is thrown away on close; filing it first would let it outlive its editor.
  const discardable = note === null ? true : source.canAutoDiscard(note.id);
  const ai = source.aiIn(note?.workspaceId);
  const isOwner = note === null ? true : isNoteOwnedBy(note, source.currentUserId);
  const isAudio = note?.kind === "audio";
  const isChecklist = note?.kind === "checklist";
  return {
    isOwner,
    canEdit: live,
    canArchive: live && !discardable,
    canTrash: live && isOwner && !discardable,
    canCopy: hasContent,
    canDuplicate: live && hasContent,
    canShowHistory: hasContent,
    canSetGridSpan: live && note !== null,
    canMoveToCollection: live && source.workspaceById(note?.workspaceId) !== null,
    canMoveToWorkspace: live && hasContent && isOwner && source.workspaces.length > 1,
    canMoveToStage: live && hasContent && source.stagesForNote(note).length > 0,
    canRewrite: live && hasContent && !isAudio && aiAllows(ai, "writing") && ai.rewriteTasks.length > 0,
    rewriteTasks: ai.rewriteTasks,
    canSummarizeLinks: live && !isChecklist && !isAudio && aiAllows(ai, "writing"),
  };
}

export function availabilityEqual(a: NoteAvailability, b: NoteAvailability): boolean {
  return (Object.keys(a) as (keyof NoteAvailability)[]).every((k) => a[k] === b[k]);
}
