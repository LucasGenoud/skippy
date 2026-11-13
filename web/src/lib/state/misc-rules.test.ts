import { describe, expect, it } from "vitest";
import { makeNote, type Label } from "@/lib/models/note";
import { convertNoteKind, copyTitle } from "./note-conversion";
import { positionAt, positionBetween, POSITION_GAP } from "./sparse-position";
import { syncFailureDecision } from "./sync-retry-policy";
import { reconcileWorkspaceDeparture } from "./workspace-reconciliation";
import { EditorHistory } from "./editor-history";

// Ported from `sparse_position_test`, `sync_retry_policy_test`,
// `workspace_reconciliation_test` and the conversion half of `note_logic_test`.

describe("sparse positions", () => {
  it("places between neighbours or a gap past an end", () => {
    expect(positionBetween(null, null)).toBe(POSITION_GAP);
    expect(positionBetween(1024, null)).toBe(2048);
    expect(positionBetween(null, 1024)).toBe(0);
    expect(positionBetween(1024, 2048)).toBe(1536);
    expect(positionAt([1024, 2048], 1, 9)).toBe(1536);
    expect(positionAt([], 0, 9)).toBe(9);
    expect(positionAt([1024], 5, 9)).toBe(2048);
  });
});

describe("sync retry policy", () => {
  it("drops permanent 4xx failures and retries the rest", () => {
    expect(syncFailureDecision(404)).toEqual({ kind: "drop" });
    expect(syncFailureDecision(409)).toEqual({ kind: "drop" });
    expect(syncFailureDecision(408)).toEqual({ kind: "retry", markConnectionDown: true, retryDelayMs: 5000 });
    for (const status of [401, 425, 429]) {
      expect(syncFailureDecision(status)).toEqual({ kind: "retry", markConnectionDown: false, retryDelayMs: 10000 });
    }
    expect(syncFailureDecision(503)).toEqual({ kind: "retry", markConnectionDown: true, retryDelayMs: 5000 });
  });
});

describe("workspace departure", () => {
  it("keeps directly shared notes without workspace labels or stage", () => {
    const labels: Label[] = [{ id: "l", workspaceId: "w", name: "L", color: null, icon: null, position: 0 }];
    const kept = makeNote({ id: "kept", workspaceId: "w", labelIds: ["l", "other"], stageId: "s", collaborators: [{ id: "me", name: "me" }] });
    const gone = makeNote({ id: "gone", workspaceId: "w" });
    const elsewhere = makeNote({ id: "else", workspaceId: "x" });
    const result = reconcileWorkspaceDeparture([kept, gone, elsewhere], labels, "w", "me");
    expect(result.notes.map((n) => n.id)).toEqual(["kept", "else"]);
    expect(result.notes[0]).toMatchObject({ labelIds: ["other"], stageId: null });
    expect([...result.directlySharedIds]).toEqual(["kept"]);
  });
});

describe("note conversion", () => {
  let counter = 0;
  const newId = (): string => `i${counter++}`;

  it("maps lines to items and back, keeping markdown task syntax and nesting", () => {
    const text = makeNote({ id: "n", content: "- [x] milk\n  - [ ] eggs\n\nbread" });
    const list = convertNoteKind(text, "checklist", newId);
    expect(list.items.map((i) => [i.text, i.done, i.depth])).toEqual([
      ["milk", true, 0],
      ["eggs", false, 1],
      ["bread", false, 0],
    ]);
    expect(list.content).toBe("");
    expect(convertNoteKind(list, "markdown", newId).content).toBe("- [x] milk\n  - [ ] eggs\n- [ ] bread");
    expect(convertNoteKind(list, "text", newId).content).toBe("milk\n  eggs\nbread");
  });

  it("drops item reminders with the rows they pointed at", () => {
    const list = makeNote({
      id: "n",
      kind: "checklist",
      items: [{ id: "a", text: "A", done: false, depth: 0 }],
      itemReminders: { a: { itemId: "a", at: new Date(2030, 0, 1), repeat: null } },
    });
    expect(convertNoteKind(list, "text", newId).itemReminders).toEqual({});
  });

  it("titles a copy", () => {
    expect(copyTitle("Groceries")).toBe("Groceries (copy)");
    expect(copyTitle("")).toBe("(copy)");
  });
});

describe("editor history", () => {
  it("groups typing bursts and splits discrete steps", () => {
    let now = 0;
    const snap = (title: string) => ({ kind: "text" as const, title, content: "", items: [] });
    const history = new EditorHistory(snap(""), () => now);
    history.record(snap("a"));
    now = 100;
    history.record(snap("ab"));
    now = 2000;
    history.record(snap("ab!"), "discrete");
    expect(history.canUndo).toBe(true);
    const undone = history.undo(snap("ab!"));
    expect(undone?.title).toBe("ab");
    expect(history.undo(snap("ab"))?.title).toBe("");
    expect(history.redo(snap(""))?.title).toBe("ab");
  });
});
