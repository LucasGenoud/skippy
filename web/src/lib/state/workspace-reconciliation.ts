import type { Label, Note } from "@/lib/models/note";

// Removing one workspace from a user's shelf while keeping notes that also
// carry a direct share for them. Ported from `state/workspace_reconciliation.dart`.

export interface WorkspaceDeparture {
  readonly notes: Note[];
  readonly directlySharedIds: ReadonlySet<string>;
}

export function reconcileWorkspaceDeparture(notes: readonly Note[], labels: readonly Label[], workspaceId: string, userId: string): WorkspaceDeparture {
  const directlySharedIds = new Set(
    notes.filter((n) => n.workspaceId === workspaceId && n.collaborators.some((c) => c.id === userId)).map((n) => n.id),
  );
  const leaving = new Set(labels.filter((l) => l.workspaceId === workspaceId).map((l) => l.id));
  const reconciled: Note[] = [];
  for (const note of notes) {
    if (note.workspaceId !== workspaceId) {
      reconciled.push(note);
    } else if (directlySharedIds.has(note.id)) {
      // Retained notes lose workspace-only labels and board placement.
      reconciled.push({ ...note, labelIds: note.labelIds.filter((id) => !leaving.has(id)), stageId: null });
    }
  }
  return { notes: reconciled, directlySharedIds };
}
