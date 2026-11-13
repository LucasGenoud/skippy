import type { ChecklistItem } from "@/lib/models/note";
import { noteLinkToken } from "./note-links";

// The notes a just-created account opens on. Ported from `state/starter_notes.dart`.

/** Whether the signed-in account existed before this session. */
export type AccountOrigin = "existing" | "justCreated";

export const STARTER_WELCOME_TITLE = "Welcome to Skippy";
export const STARTER_CHECKLIST_TITLE = "Try a checklist";
export const STARTER_GUIDE_TITLE = "Ways to organize";

/** Links to the other two starter notes, so `[[` is shown working. */
export function starterWelcomeBody(checklistId: string, guideId: string): string {
  const checklist = noteLinkToken(checklistId, STARTER_CHECKLIST_TITLE);
  const guide = noteLinkToken(guideId, STARTER_GUIDE_TITLE);
  return `These notes will get you started. Change or delete them whenever you like.

- ${checklist} shows how tasks and subtasks work.
- ${guide} explains collections, boards, labels, and smart views.

**Things to try**

- Type \`[[\` in a note to link to another one.
- Keep writing offline. Your edits sync when you reconnect.
- Share a note, or invite someone to a workspace, to work on it together.`;
}

export const STARTER_GUIDE_BODY = `**Collections** keep related notes together. Each one has its own layout.

**Boards** are a collection layout. Drag notes between columns.

**Labels** cut across collections. Everyone in a workspace shares them.

**Smart views** save a search, so it stays one click away.`;

export function starterChecklistItems(newId: () => string): ChecklistItem[] {
  return [
    { id: newId(), text: "Tick this box", done: false, depth: 0 },
    { id: newId(), text: "Plan a weekend away", done: false, depth: 0 },
    { id: newId(), text: "Book the train", done: false, depth: 1 },
    { id: newId(), text: "Find somewhere to stay", done: false, depth: 1 },
  ];
}
