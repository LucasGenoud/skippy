import { describe, expect, it } from "vitest";

import { makeNote, type Note } from "@/lib/models/note";
import { buildBoard } from "@/lib/state/board-layout";

import {
  UNASSIGNED_KEY,
  canDropOnExit,
  canDropOnStage,
  columnIdsEqual,
  columnIdsOf,
  columnSelectionOf,
  containerOf,
  draggedIdsFor,
  moveToColumn,
  moveWithin,
  pageAt,
  planCardDrop,
} from "./board-drag";

const card = (id: string, stageId: string | null, stagePosition: number, extra: Partial<Note> = {}): Note => makeNote({ id, stageId, stagePosition, ...extra });

function lookup(...notes: Note[]): (id: string) => Note | null {
  const byId = new Map(notes.map((n) => [n.id, n]));
  return (id) => byId.get(id) ?? null;
}

describe("planCardDrop", () => {
  const a = card("a", "s1", 1000);
  const b = card("b", "s1", 2000);
  const c = card("c", "s1", 3000);

  it("writes one midpoint position for a reorder within the column", () => {
    const writes = planCardDrop({ moved: c, draggedIds: ["c"], targetStageId: "s1", shownIds: ["a", "c", "b"], before: [a, b, c], noteById: lookup(a, b, c) });
    expect(writes).toEqual([{ noteId: "c", stageId: "s1", position: 1500 }]);
  });

  it("writes nothing when the order did not change", () => {
    expect(planCardDrop({ moved: b, draggedIds: ["b"], targetStageId: "s1", shownIds: ["a", "b", "c"], before: [a, b, c], noteById: lookup(a, b, c) })).toEqual([]);
  });

  it("lands a card from another column in the slot it was shown in", () => {
    const x = card("x", null, 500);
    const writes = planCardDrop({ moved: x, draggedIds: ["x"], targetStageId: "s1", shownIds: ["a", "x", "b", "c"], before: [a, b, c], noteById: lookup(a, b, c, x) });
    expect(writes).toEqual([{ noteId: "x", stageId: "s1", position: 1500 }]);
  });

  it("sends the rest of a selection to the end of the target column", () => {
    const x = card("x", null, 500);
    const y = card("y", "s2", 100);
    const already = card("z", "s1", 4000);
    const writes = planCardDrop({ moved: x, draggedIds: ["x", "y", "z"], targetStageId: "s1", shownIds: ["x", "a"], before: [a], noteById: lookup(a, x, y, already) });
    expect(writes.map((w) => [w.noteId, w.stageId])).toEqual([
      ["x", "s1"],
      ["y", "s1"],
    ]);
    // The carried card goes above `a`; the follower goes to the end.
    expect(writes[0]?.position).toBeLessThan(a.stagePosition);
    expect(writes[1]?.position).toBeUndefined();
  });

  it("moves to Unassigned as a null stage", () => {
    const writes = planCardDrop({ moved: a, draggedIds: ["a"], targetStageId: null, shownIds: ["a"], before: [], noteById: lookup(a) });
    expect(writes[0]?.stageId).toBeNull();
  });

  it("orders a pinned card among pinned peers only", () => {
    const pinned = card("p", "s1", 100, { pinned: true });
    const x = card("x", null, 0, { pinned: true });
    const writes = planCardDrop({ moved: x, draggedIds: ["x"], targetStageId: "s1", shownIds: ["p", "a", "x", "b"], before: [pinned, a, b], noteById: lookup(pinned, a, b, x) });
    // Only `p` is a peer, so the card goes after it.
    expect(writes[0]?.position).toBeGreaterThan(100);
  });
});

describe("column state while dragging", () => {
  it("moves an id between columns at a clamped index", () => {
    const columns = { [UNASSIGNED_KEY]: ["a", "b"], s1: ["c"] };
    const next = moveToColumn(columns, "a", "s1", 99);
    expect(next).toEqual({ [UNASSIGNED_KEY]: ["b"], s1: ["c", "a"] });
    expect(containerOf(next, "a")).toBe("s1");
    expect(containerOf(next, "nope")).toBeNull();
  });

  it("moves within a list like arrayMove", () => {
    expect(moveWithin(["a", "b", "c"], 0, 2)).toEqual(["b", "c", "a"]);
  });

  it("carries the selection only when the card is in it", () => {
    expect(draggedIdsFor("a", ["a", "b"])).toEqual(["a", "b"]);
    expect(draggedIdsFor("c", ["a", "b"])).toEqual(["c"]);
  });
});

describe("drop targets", () => {
  it("lights a chip only when something would move", () => {
    expect(canDropOnStage([card("a", "s1", 0)], "s1")).toBe(false);
    expect(canDropOnStage([card("a", "s1", 0), card("b", null, 0)], "s1")).toBe(true);
  });

  it("refuses an exit when any carried card cannot go there", () => {
    const live = card("a", null, 0);
    const archived = card("b", null, 0, { archived: true });
    expect(canDropOnExit([live], "archive", () => false)).toBe(true);
    expect(canDropOnExit([live], "trash", () => false)).toBe(false);
    expect(canDropOnExit([live, archived], "archive", () => true)).toBe(false);
    expect(canDropOnExit([null], "archive", () => true)).toBe(false);
  });
});

describe("board columns as ids", () => {
  it("keys columns by stage and compares by ids", () => {
    const stage = { id: "s1", workspaceId: "w", collectionId: null, name: "Doing", color: null, position: 1 };
    const notes = [card("a", "s1", 1), card("b", null, 1)];
    const first = columnIdsOf(buildBoard({ notes, stages: [stage] }));
    expect(first.map((c) => [c.key, c.ids])).toEqual([
      [UNASSIGNED_KEY, ["b"]],
      ["s1", ["a"]],
    ]);
    const again = columnIdsOf(buildBoard({ notes: [card("a", "s1", 1, { title: "edited" }), notes[1]!], stages: [stage] }));
    expect(columnIdsEqual(first, again)).toBe(true);
  });

  it("summarises the selection over a column", () => {
    expect(columnSelectionOf(["a", "b"], new Set())).toBe("none");
    expect(columnSelectionOf(["a", "b"], new Set(["a"]))).toBe("some");
    expect(columnSelectionOf(["a", "b"], new Set(["a", "b", "z"]))).toBe("all");
  });

  it("reads the open page from the scroll offset", () => {
    expect(pageAt(0, 300, 3)).toBe(0);
    expect(pageAt(320, 300, 3)).toBe(1);
    expect(pageAt(5000, 300, 3)).toBe(2);
    expect(pageAt(100, 0, 3)).toBe(0);
  });
});
