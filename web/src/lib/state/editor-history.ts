import type { ChecklistItem, NoteKind } from "@/lib/models/note";

// The editor's session-local undo/redo history. Typing groups into bursts;
// discrete ops always start a new step. Ported from `state/editor_history.dart`.

export interface EditorSnapshot {
  readonly kind: NoteKind;
  readonly title: string;
  readonly content: string;
  readonly items: readonly ChecklistItem[];
}

function itemsEqual(a: readonly ChecklistItem[], b: readonly ChecklistItem[]): boolean {
  if (a.length !== b.length) {
    return false;
  }
  return a.every((x, i) => {
    const y = b[i];
    return y !== undefined && x.id === y.id && x.text === y.text && x.done === y.done && x.depth === y.depth;
  });
}

export function snapshotsEqual(a: EditorSnapshot, b: EditorSnapshot): boolean {
  return a.kind === b.kind && a.title === b.title && a.content === b.content && itemsEqual(a.items, b.items);
}

/** Whether a recorded edit is part of a typing burst or a step of its own. */
export type EditKind = "typing" | "discrete";

const BURST_GAP_MS = 800;
const MAX_STEPS = 100;

export class EditorHistory {
  private readonly undoStack: EditorSnapshot[] = [];
  private readonly redoStack: EditorSnapshot[] = [];
  private mirror: EditorSnapshot;
  private lastEdit = Number.NEGATIVE_INFINITY;

  constructor(
    initial: EditorSnapshot,
    private readonly now: () => number = Date.now,
  ) {
    this.mirror = initial;
  }

  get canUndo(): boolean {
    return this.undoStack.length > 0;
  }

  get canRedo(): boolean {
    return this.redoStack.length > 0;
  }

  /** Record history after a mutation; a no-op when nothing changed. */
  record(current: EditorSnapshot, kind: EditKind = "typing"): void {
    if (snapshotsEqual(current, this.mirror)) {
      return;
    }
    const now = this.now();
    if (kind === "discrete" || now - this.lastEdit > BURST_GAP_MS) {
      this.undoStack.push(this.mirror);
      if (this.undoStack.length > MAX_STEPS) {
        this.undoStack.shift();
      }
      this.redoStack.length = 0;
    }
    this.lastEdit = now;
    this.mirror = current;
  }

  /** The previous state, saving [current] for redo; null when there is none. */
  undo(current: EditorSnapshot): EditorSnapshot | null {
    const previous = this.undoStack.pop();
    if (!previous) {
      return null;
    }
    this.redoStack.push(current);
    return previous;
  }

  redo(current: EditorSnapshot): EditorSnapshot | null {
    const next = this.redoStack.pop();
    if (!next) {
      return null;
    }
    this.undoStack.push(current);
    return next;
  }

  /** Re-baseline after a snapshot is applied: the next edit starts a fresh burst. */
  resetTo(snapshot: EditorSnapshot): void {
    this.mirror = snapshot;
    this.lastEdit = Number.NEGATIVE_INFINITY;
  }
}
