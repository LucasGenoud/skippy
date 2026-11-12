import { plural } from "../kit/files";

// The words a restore or import ends with, success or partial failure.

export function restoredMessage(result: { notes: number; attachments: number; workspaces: number }): string {
  return `Restored ${plural(result.notes, "note")} and ${plural(result.attachments, "file")} across ${plural(result.workspaces, "workspace")}`;
}

export function importedMessage(result: { notes: number; attachments: number }): string {
  return `Imported ${plural(result.notes, "note")} and ${plural(result.attachments, "file")} from Google Keep`;
}

/** A failure that stopped partway says how far it got. */
export function partialMessage(message: string, done: number, verb: "restored" | "imported"): string {
  return done === 0 ? message : `${message}. ${done} notes were ${verb} before it stopped.`;
}

/** "Adding files… 3 of 10". */
export const progressText = (prefix: string, done: number, total: number): string => `${prefix}… ${done} of ${total}`;
