import { describe, expect, it } from "vitest";
import type { ChecklistItem } from "@/lib/models/note";
import {
  canShiftDepth,
  hasSubtasks,
  isFinished,
  moveSubtree,
  normalizeDepths,
  removeItem,
  reopenWhereWritten,
  rootIndexOf,
  setDoneCascading,
  shiftDepth,
  subtreeEnd,
} from "./checklist-tree";

// Ported from `app/test/checklist_tree_test.dart`. A list is written as
// "depth:text", with "*" marking a checked row.

function list(rows: string[]): ChecklistItem[] {
  return rows.map((row, i) => {
    const [depth = "0", text = ""] = row.split(":");
    return { id: `i${i}`, text: text.replace("*", ""), depth: Number(depth), done: row.includes("*") };
  });
}

const shape = (items: readonly ChecklistItem[]): string[] => items.map((i) => `${i.depth}:${i.done ? "*" : ""}${i.text}`);

describe("normalizing", () => {
  it("keeps a legal shape and repairs an impossible one", () => {
    const legal = list(["0:Trip", "1:Pack", "2:Socks", "1:Book", "0:Water"]);
    expect(shape(normalizeDepths(legal))).toEqual(shape(legal));
    expect(shape(normalizeDepths(list(["2:Trip", "2:Pack"])))).toEqual(["0:Trip", "1:Pack"]);
    expect(shape(normalizeDepths(list(["0:Trip", "2:Socks"])))).toEqual(["0:Trip", "1:Socks"]);
    expect(normalizeDepths([])).toEqual([]);
  });
});

describe("subtrees", () => {
  const trip = list(["0:Trip", "1:Pack", "2:Socks", "1:Book", "0:Water"]);
  it("span every row below the root and stop at the next peer", () => {
    expect(subtreeEnd(trip, 0)).toBe(4);
    expect(subtreeEnd(trip, 1)).toBe(3);
    expect(subtreeEnd(trip, 2)).toBe(3);
    expect(subtreeEnd(trip, 4)).toBe(5);
    expect(hasSubtasks(trip, 0)).toBe(true);
    expect(hasSubtasks(trip, 2)).toBe(false);
    expect(rootIndexOf(trip, 2)).toBe(0);
    expect(rootIndexOf(trip, 4)).toBe(4);
  });
});

describe("checking off", () => {
  it("a task takes its subtasks with it, both ways", () => {
    const trip = list(["0:Trip", "1:Pack", "2:Socks", "0:Water"]);
    const done = setDoneCascading(trip, "i0", true);
    expect(shape(done)).toEqual(["0:*Trip", "1:*Pack", "2:*Socks", "0:Water"]);
    expect(shape(setDoneCascading(done, "i0", false))).toEqual(shape(trip));
  });

  it("a subtask never finishes the task holding it", () => {
    expect(shape(setDoneCascading(list(["0:Trip", "1:Pack", "2:Socks"]), "i1", true))).toEqual(["0:Trip", "1:*Pack", "2:*Socks"]);
  });

  it("an unfinished row is never filed away", () => {
    expect(isFinished(list(["0:*Trip", "1:Pack"]), 1)).toBe(false);
  });

  it("only whole tasks move to the checked section", () => {
    const partly = list(["0:Trip", "1:*Pack", "0:Water"]);
    expect([0, 1, 2].map((i) => isFinished(partly, i))).toEqual([false, false, false]);
    const finished = list(["0:*Trip", "1:*Pack", "0:Water"]);
    expect([0, 1, 2].map((i) => isFinished(finished, i))).toEqual([true, true, false]);
  });
});

describe("indenting", () => {
  it("needs a row above it and stops at the last level", () => {
    const trip = list(["0:Trip", "1:Pack", "2:Socks"]);
    expect(canShiftDepth(trip, "i0", 1)).toBe(false);
    expect(canShiftDepth(trip, "i2", 1)).toBe(false);
    expect(canShiftDepth(list(["0:A", "1:B", "1:C"]), "i2", 1)).toBe(true);
    expect(canShiftDepth(trip, "i0", -1)).toBe(false);
    expect(canShiftDepth(trip, "i1", -1)).toBe(true);
  });

  it("carries the subtasks along", () => {
    const trip = list(["0:Trip", "1:Pack", "2:Socks", "0:Water"]);
    expect(shape(shiftDepth(trip, "i1", -1))).toEqual(["0:Trip", "0:Pack", "1:Socks", "0:Water"]);
    expect(shape(shiftDepth(trip, "i0", 1))).toEqual(shape(trip));
    expect(shape(shiftDepth(list(["0:Trip", "0:Pack", "1:Socks"]), "i1", 1))).toEqual(["0:Trip", "1:Pack", "2:Socks"]);
  });
});

describe("removing", () => {
  it("promotes what was under the row rather than deleting it", () => {
    const trip = list(["0:Trip", "1:Pack", "2:Socks", "1:Book", "0:Water"]);
    expect(shape(removeItem(trip, "i0"))).toEqual(["0:Pack", "1:Socks", "0:Book", "0:Water"]);
    expect(shape(removeItem(trip, "i1"))).toEqual(["0:Trip", "1:Socks", "1:Book", "0:Water"]);
    expect(shape(removeItem(trip, "nope"))).toEqual(shape(trip));
  });
});

describe("indenting past what is filed away", () => {
  it("a row cannot be nested under a task that is done", () => {
    const rows = list(["0:*Trip", "0:Water"]);
    expect(canShiftDepth(rows, "i1", 1)).toBe(false);
    expect(shape(shiftDepth(rows, "i1", 1))).toEqual(["0:*Trip", "0:Water"]);
  });

  it("nests under the row it is actually shown under", () => {
    const rows = list(["0:Shop", "0:*Trip", "0:Water"]);
    expect(canShiftDepth(rows, "i2", 1)).toBe(true);
    expect(shape(shiftDepth(rows, "i2", 1))).toEqual(["0:Shop", "1:Water", "0:*Trip"]);
  });

  it("a finished row still indents inside the checked section", () => {
    expect(shape(shiftDepth(list(["0:*Trip", "0:*Pack", "0:Water"]), "i1", 1))).toEqual(["0:*Trip", "1:*Pack", "0:Water"]);
  });
});

describe("re-adding from history", () => {
  it("comes back where it is written, not where it was checked off", () => {
    const rows = list(["0:*Milk", "0:Bread", "0:Eggs"]);
    expect(shape(reopenWhereWritten(rows, "i0"))).toEqual(["0:Bread", "0:Eggs", "0:Milk"]);
    expect(shape(reopenWhereWritten(rows, "i0", "i1"))).toEqual(["0:Bread", "0:Milk", "0:Eggs"]);
    expect(shape(reopenWhereWritten(rows, "gone"))).toEqual(shape(rows));
  });

  it("brings its subtasks along and takes the depth it lands at", () => {
    const trip = list(["0:*Pack", "1:*Socks", "1:*Book", "0:Trip", "1:Van"]);
    expect(shape(reopenWhereWritten(trip, "i0", "i4"))).toEqual(["0:Trip", "1:Van", "1:Pack", "2:Socks", "2:Book"]);
    expect(shape(reopenWhereWritten(trip, "i0", "i3"))).toEqual(["0:Trip", "1:Van", "0:Pack", "1:Socks", "1:Book"]);
  });

  it("a subtask ticked off in place comes back out to the composer", () => {
    expect(shape(reopenWhereWritten(list(["0:Trip", "1:*Socks", "1:Book"]), "i1"))).toEqual(["0:Trip", "1:Book", "1:Socks"]);
  });
});

describe("moving", () => {
  it("takes the subtree and lands somewhere drawable", () => {
    const trip = list(["0:Trip", "1:Pack", "2:Socks", "0:Water"]);
    expect(shape(moveSubtree(trip, "i0", 1))).toEqual(["0:Water", "0:Trip", "1:Pack", "2:Socks"]);
    expect(shape(moveSubtree(trip, "i1", 0))).toEqual(["0:Pack", "1:Socks", "0:Trip", "0:Water"]);
  });
});
