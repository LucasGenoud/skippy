import { describe, expect, it } from "vitest";
import { makeNote, type ChecklistItem } from "@/lib/models/note";

import { cardClickIntent, checklistPreview, linkPreviewUrls, MAX_CHECKLIST_PREVIEW_ITEMS, rangeSelection, rewriteFailureSentence, sharedByLabel, swipeCommitDistance, swipeOpacity, swipeOutcome, titleHasMarkdown } from "./card-rules";
import { cardTags } from "./card-tags";
import { highlightCode } from "./code-highlight";
import { gridMetrics, mergeDuringDrag, orderAtPoint, packMasonry } from "./masonry-layout";
import { draftHasContent } from "./quick-add-bar";

const item = (id: string, text: string, done = false, depth = 0): ChecklistItem => ({ id, text, done, depth });

describe("packMasonry", () => {
  const heights = new Map([
    ["a", 100],
    ["b", 50],
    ["c", 80],
    ["d", 40],
  ]);

  it("puts each card in the shortest column, ties to the left", () => {
    const layout = packMasonry({ order: ["a", "b", "c", "d"], spans: new Map(), heights, columns: 2, spacing: 8, width: 208 });
    expect(layout.columnWidth).toBe(100);
    expect(layout.slots.get("a")).toEqual({ x: 0, y: 0, width: 100 });
    expect(layout.slots.get("b")).toEqual({ x: 108, y: 0, width: 100 });
    expect(layout.slots.get("c")).toEqual({ x: 108, y: 58, width: 100 });
    expect(layout.slots.get("d")).toEqual({ x: 0, y: 108, width: 100 });
    expect(layout.totalHeight).toBe(148);
  });

  it("lays a spanning card over the lowest run of columns", () => {
    const layout = packMasonry({ order: ["a", "b", "c"], spans: new Map([["c", 2]]), heights, columns: 3, spacing: 8, width: 316 });
    // a and b fill columns 0 and 1; c needs two adjacent columns, lowest is 1-2 (b: 50) vs 0-1 (a: 100).
    expect(layout.slots.get("c")).toEqual({ x: 108, y: 58, width: 208 });
  });

  it("guesses a height for cards nobody measured", () => {
    const layout = packMasonry({ order: ["x", "y"], spans: new Map(), heights: new Map(), columns: 1, spacing: 8, width: 100 });
    expect(layout.slots.get("y")?.y).toBe(128);
  });
});

describe("orderAtPoint", () => {
  const order = ["a", "b", "c", "d"];
  const heights = new Map(order.map((id) => [id, 100]));
  const layout = packMasonry({ order, spans: new Map(), heights, columns: 1, spacing: 0, width: 100 });
  const target = (dragging: string[], draggingId: string) => ({ order, layout, heights, dragging: new Set(dragging), draggingId, gridWidth: 100 });

  it("moves the card after a target below it and before one above it", () => {
    expect(orderAtPoint(target(["a"], "a"), { x: 50, y: 250 })).toEqual(["b", "c", "a", "d"]);
    expect(orderAtPoint(target(["d"], "d"), { x: 50, y: 50 })).toEqual(["d", "a", "b", "c"]);
  });

  it("moves a selected group together, in its order", () => {
    expect(orderAtPoint(target(["a", "c"], "a"), { x: 50, y: 350 })).toEqual(["b", "d", "a", "c"]);
  });

  it("drops at the end below the last card, and nowhere off to the side", () => {
    expect(orderAtPoint(target(["a"], "a"), { x: 50, y: 900 })).toEqual(["b", "c", "d", "a"]);
    expect(orderAtPoint(target(["a"], "a"), { x: 500, y: 50 })).toBeNull();
  });
});

describe("grid metrics and drag merge", () => {
  const comfortable = { targetWidth: 250, maxColumns: 6 };

  it("fits columns to the density, at least two, and one in a list", () => {
    expect(gridMetrics(1400, comfortable, 1400, "masonry")).toEqual({ pad: 32, maxWidth: 1400, columns: 5 });
    expect(gridMetrics(400, comfortable, 1400, "masonry").columns).toBe(2);
    expect(gridMetrics(1400, comfortable, 1400, "list")).toEqual({ pad: 32, maxWidth: 600, columns: 1 });
  });

  it("keeps a drag's order while notes come and go underneath it", () => {
    expect(mergeDuringDrag(["b", "a", "c"], ["a", "b", "d"])).toEqual(["b", "a", "d"]);
  });
});

describe("card rules", () => {
  it("lists open rows with text, counts the done ones, and caps the list", () => {
    const items = [item("1", "milk"), item("2", " "), item("3", "eggs", true), ...Array.from({ length: 20 }, (_, i) => item(`x${i}`, `row ${i}`))];
    const preview = checklistPreview(items);
    expect(preview.visible).toHaveLength(22);
    expect(preview.checkedCount).toBe(1);
    expect(preview.rows).toHaveLength(MAX_CHECKLIST_PREVIEW_ITEMS);
    expect(preview.hidden).toBe(21 - MAX_CHECKLIST_PREVIEW_ITEMS);
  });

  it("previews each URL once, at most five", () => {
    const text = "a https://x.com b https://x.com https://1.io https://2.io https://3.io https://4.io https://5.io";
    expect(linkPreviewUrls(text)).toEqual(["https://x.com", "https://1.io", "https://2.io", "https://3.io", "https://4.io"]);
  });

  it("names the owner of a shared note, shortened, and nobody for your own", () => {
    const owner = { id: "u-other", name: "Bartholomew Longname" };
    expect(sharedByLabel(makeNote({ id: "n", owner }), "u-me")).toBe("Bartholomew Lon…");
    expect(sharedByLabel(makeNote({ id: "n", owner: { id: "u-me", name: "Me" } }), "u-me")).toBeNull();
  });

  it("commits a swipe past the distance or on a fling the same way", () => {
    expect(swipeCommitDistance(1000)).toBe(120);
    expect(swipeOutcome(130, 1000, 0)).toBe("commit");
    expect(swipeOutcome(-40, 300, -900)).toBe("commit");
    expect(swipeOutcome(40, 300, -900)).toBe("settle");
    expect(swipeOutcome(40, 300, 100)).toBe("settle");
    expect(swipeOpacity(0.5)).toBe(1);
    expect(swipeOpacity(1)).toBe(0);
  });

  it("reads modifier clicks as selection", () => {
    const plain = { metaKey: false, ctrlKey: false, shiftKey: false };
    expect(cardClickIntent(plain, false)).toBe("open");
    expect(cardClickIntent(plain, true)).toBe("toggle");
    expect(cardClickIntent({ ...plain, metaKey: true }, false)).toBe("toggle");
    expect(cardClickIntent({ ...plain, ctrlKey: true }, false)).toBe("toggle");
    expect(cardClickIntent({ ...plain, shiftKey: true }, false)).toBe("range");
  });

  it("selects a range from the anchor, in either direction", () => {
    const visible = ["a", "b", "c", "d", "e"];
    expect(rangeSelection(visible, ["b"], "b", "d")).toEqual(["b", "c", "d"]);
    expect(rangeSelection(visible, [], "d", "b")).toEqual(["b", "c", "d"]);
    expect(rangeSelection(visible, ["a"], null, "c")).toEqual(["a", "c"]);
  });

  it("renders titles with markdown only when they carry some", () => {
    expect(titleHasMarkdown("Groceries")).toBe(false);
    expect(titleHasMarkdown("# Plan")).toBe(true);
    expect(titleHasMarkdown("a **bold** move")).toBe(true);
  });

  it("phrases a rewrite failure as a sentence", () => {
    expect(rewriteFailureSentence("the note changed while the AI was editing it")).toBe("The note changed while the AI was editing it.");
    expect(rewriteFailureSentence("")).toBe("The server could not be reached.");
  });

  it("sorts a card's labels by name and skips unknown ids", () => {
    const labels = [
      { id: "1", workspaceId: "w", name: "zeta", color: "", icon: null, position: 0 },
      { id: "2", workspaceId: "w", name: "Alpha", color: "#ff0000", icon: "star", position: 1 },
    ];
    expect(cardTags(["1", "2", "gone"], labels as never).map((t) => [t.name, t.color])).toEqual([
      ["Alpha", "#ff0000"],
      ["zeta", null],
    ]);
  });
});

describe("highlightCode", () => {
  it("always concatenates back to the source", () => {
    const source = 'fn main() {\n  // hi\n  let x = "a\\"b" + 42;\n  Thing::new(x)\n}';
    expect(highlightCode(source, "rust").map((t) => t.text).join("")).toBe(source);
  });

  it("colours keywords, strings, numbers, comments, calls and types", () => {
    const kinds = Object.fromEntries(highlightCode('let s = "x"; // c\nFoo(1)', "js").map((t) => [t.text, t.kind]));
    expect(kinds).toMatchObject({ let: "keyword", '"x"': "string", "// c": "comment", Foo: "call", "1": "number" });
    const python = highlightCode("# note\nclass Bar: pass", "python");
    expect(python[0]).toEqual({ text: "# note", kind: "comment" });
    expect(python.find((t) => t.text === "Bar")?.kind).toBe("type");
  });

  it("ends a stray quote at the line", () => {
    const tokens = highlightCode("it's\nnext", "");
    expect(tokens.find((t) => t.kind === "string")?.text).toBe("'s");
  });
});

describe("quick add", () => {
  const base = { kind: "text" as const, title: "", content: "", items: [], files: [], reminder: null };

  it("keeps a draft with text, files, a reminder, or a non-blank row", () => {
    expect(draftHasContent(base)).toBe(false);
    expect(draftHasContent({ ...base, content: "  " })).toBe(false);
    expect(draftHasContent({ ...base, title: "x" })).toBe(true);
    expect(draftHasContent({ ...base, reminder: { at: new Date() } })).toBe(true);
    expect(draftHasContent({ ...base, kind: "checklist", items: [item("1", " ")] })).toBe(false);
    expect(draftHasContent({ ...base, kind: "checklist", items: [item("1", "eggs")] })).toBe(true);
  });
});
