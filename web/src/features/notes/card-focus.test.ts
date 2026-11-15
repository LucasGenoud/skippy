import { describe, expect, it } from "vitest";

import { arrowDirection, nearestInDirection, type CardBox, type Candidate } from "./card-focus";

// A three-column masonry, 100px wide columns with 10px gaps:
//
//   a(0-120)    b(0-60)     e(0-200)
//   c(130-200)  d(70-300)
const box = (left: number, top: number, bottom: number): CardBox => ({ left, top, right: left + 100, bottom });
const a = box(0, 0, 120);
const b = box(110, 0, 60);
const c = box(0, 130, 200);
const d = box(110, 70, 300);
const e = box(220, 0, 200);
const all: Candidate[] = [
  { id: "a", box: a },
  { id: "b", box: b },
  { id: "c", box: c },
  { id: "d", box: d },
  { id: "e", box: e },
];
const others = (self: string) => all.filter((x) => x.id !== self);

describe("nearestInDirection", () => {
  it("goes down its own column, not into the next", () => {
    expect(nearestInDirection(a, others("a"), "down")).toBe("c");
    expect(nearestInDirection(b, others("b"), "down")).toBe("d");
  });

  it("goes right to the nearest column, the card closest in height", () => {
    expect(nearestInDirection(a, others("a"), "right")).toBe("b");
    expect(nearestInDirection(c, others("c"), "right")).toBe("d");
    expect(nearestInDirection(d, others("d"), "right")).toBe("e");
  });

  it("goes back left and up", () => {
    expect(nearestInDirection(e, others("e"), "left")).toBe("d");
    expect(nearestInDirection(c, others("c"), "up")).toBe("a");
  });

  it("stops at the edge", () => {
    expect(nearestInDirection(a, others("a"), "left")).toBeNull();
    expect(nearestInDirection(a, others("a"), "up")).toBeNull();
  });

  it("reads only the arrow keys", () => {
    expect(arrowDirection("ArrowDown")).toBe("down");
    expect(arrowDirection("Enter")).toBeNull();
  });
});
