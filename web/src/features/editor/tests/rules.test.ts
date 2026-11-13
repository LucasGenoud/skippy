import { describe, expect, it } from "vitest";
import type { ChecklistItem } from "@/lib/models/note";
import { bodySegments, findMatches } from "../lib/body-segments";
import { applyMarkdownAction, headingLine, setTaskLine } from "../lib/markdown-format";
import { MORPH_REST, morphFrom } from "../lib/morph";
import { activeTexts, checkedRows, completesList, dropBlock, prunedRows, rowKeyAction } from "../checklist/checklist-view";
import { cycleIndex } from "../checklist/checklist-editor";

const row = (id: string, depth = 0, done = false, text = id): ChecklistItem => ({ id, text, done, depth });
const ids = (items: readonly ChecklistItem[]): string => items.map((i) => `${i.id}${i.depth}`).join(" ");

describe("markdown toolbar edits", () => {
  it("wraps a selection and keeps it selected inside the markers", () => {
    expect(applyMarkdownAction({ text: "make bold here", start: 5, end: 9 }, "bold")).toEqual({ text: "make **bold** here", start: 7, end: 11 });
  });

  it("parks the caret between markers when nothing is selected", () => {
    expect(applyMarkdownAction({ text: "ab", start: 1, end: 1 }, "code")).toEqual({ text: "a``b", start: 2, end: 2 });
  });

  it("swaps heading levels instead of stacking them", () => {
    expect(headingLine(2, "# Title")).toBe("## Title");
    expect(applyMarkdownAction({ text: "one\ntwo", start: 5, end: 5 }, "h1").text).toBe("one\n# two");
  });

  it("toggles a list prefix on every line the selection touches", () => {
    const listed = applyMarkdownAction({ text: "a\nb\nc", start: 0, end: 3 }, "bullets");
    expect(listed.text).toBe("- a\n- b\nc");
    expect(applyMarkdownAction({ text: listed.text, start: 0, end: 5 }, "bullets").text).toBe("a\nb\nc");
  });

  it("inserts a link with the url placeholder selected", () => {
    const edit = applyMarkdownAction({ text: "see docs", start: 4, end: 8 }, "link");
    expect(edit.text).toBe("see [docs](url)");
    expect(edit.text.slice(edit.start, edit.end)).toBe("url");
  });

  it("ticks a task line from the preview and leaves other lines alone", () => {
    expect(setTaskLine("intro\n- [ ] milk\n- [x] eggs", 1, true)).toBe("intro\n- [x] milk\n- [x] eggs");
    expect(setTaskLine("intro\n- [ ] milk", 0, true)).toBe("intro\n- [ ] milk");
  });
});

describe("body painting", () => {
  it("finds every case-insensitive match without overlap", () => {
    expect(findMatches("Aaa aa", "aa")).toEqual([
      { start: 0, end: 2 },
      { start: 4, end: 6 },
    ]);
    expect(findMatches("abc", "  ")).toEqual([]);
  });

  it("keeps the text intact and fades a note link's id", () => {
    const id = "3f2c1a4e-0000-4000-8000-000000000000";
    const text = `see [[${id}|Groceries]] now`;
    const segments = bodySegments(text, { markdown: false });
    expect(segments.map((s) => s.text).join("")).toBe(text);
    expect(segments.find((s) => s.text === "Groceries")?.styles).toContain("linkTitle");
    expect(segments.find((s) => s.text.startsWith("[["))?.styles).toContain("linkSyntax");
  });

  it("marks the current find match apart from the others", () => {
    const segments = bodySegments("a b a", { markdown: false, matches: findMatches("a b a", "a"), current: 1 });
    expect(segments.filter((s) => s.styles.includes("match")).length).toBe(1);
    expect(segments[segments.length - 1]?.styles).toContain("current");
  });

  it("styles markdown structure only in markdown", () => {
    expect(bodySegments("**b**", { markdown: true }).find((s) => s.text === "b")?.styles).toContain("bold");
    expect(bodySegments("**b**", { markdown: false })).toEqual([{ text: "**b**", styles: [] }]);
  });
});

describe("morph", () => {
  it("scales the editor to the card's width and clips it to the card's height", () => {
    const frame = morphFrom({ left: 10, top: 20, width: 200, height: 100 }, { left: 110, top: 70, width: 600, height: 500 });
    expect(frame?.transform).toBe("translate(-100px, -50px) scale(0.3333)");
    // 100px tall at a third of the scale is 300px of the editor: cut the other 200.
    // The card's 10px corner, in the editor's unscaled coordinates, is 30px.
    expect(frame?.clipPath).toBe("inset(0px 0px 200px 0px round 30px)");
  });

  it("rests in the panel's own corners, so dropping the clip changes nothing", () => {
    expect(MORPH_REST.clipPath).toBe("inset(0px 0px 0px 0px round 12px)");
  });

  it("refuses an empty box", () => {
    expect(morphFrom({ left: 0, top: 0, width: 0, height: 10 }, { left: 0, top: 0, width: 10, height: 10 })).toBeNull();
  });
});

describe("checklist view rules", () => {
  it("holds a just-ticked task out of the checked section", () => {
    const items = [row("a", 0, true), row("a1", 1, true), row("b")];
    expect(checkedRows(items, new Set()).map((i) => i.id)).toEqual(["a", "a1"]);
    expect(checkedRows(items, new Set(["a"]))).toEqual([]);
  });

  it("keeps a ticked subtask of an open task in place", () => {
    expect(checkedRows([row("a"), row("a1", 1, true)], new Set())).toEqual([]);
  });

  it("drops a task with its subtasks", () => {
    const items = [row("a"), row("a1", 1), row("b"), row("c")];
    const next = dropBlock(items, { order: ["a", "a1", "b", "c"], composingId: null, checked: [], activeId: "a", overId: "b", depthDelta: 0 });
    expect(ids(next)).toBe("b0 a0 a11 c0");
  });

  it("nests a dropped row where the rules allow, and no further", () => {
    const items = [row("a"), row("b"), row("c")];
    const once = dropBlock(items, { order: ["a", "b", "c"], composingId: null, checked: [], activeId: "c", overId: "c", depthDelta: 1 });
    expect(ids(once)).toBe("a0 b0 c1");
    const far = dropBlock(items, { order: ["a", "b", "c"], composingId: null, checked: [], activeId: "b", overId: "b", depthDelta: 2 });
    expect(ids(far)).toBe("a0 b1 c0");
  });

  it("keeps the row being composed and the checked rows on a drop", () => {
    const items = [row("a"), row("b"), row("x", 0, true), row("new")];
    const next = dropBlock(items, { order: ["a", "b"], composingId: "new", checked: [row("x", 0, true)], activeId: "b", overId: "a", depthDelta: 0 });
    expect(ids(next)).toBe("b0 a0 new0 x0");
  });

  it("maps keys to row actions", () => {
    expect(rowKeyAction({ key: "Tab", shiftKey: true }, "x", 1)).toEqual({ kind: "indent", delta: -1 });
    expect(rowKeyAction({ key: "Enter", shiftKey: false }, "x", 0)).toEqual({ kind: "insertAfter" });
    expect(rowKeyAction({ key: "Backspace", shiftKey: false }, "", 1)).toEqual({ kind: "outdentEmpty" });
    expect(rowKeyAction({ key: "Backspace", shiftKey: false }, "", 0)).toEqual({ kind: "removeEmpty" });
    expect(rowKeyAction({ key: "Backspace", shiftKey: false }, "x", 0)).toEqual({ kind: "none" });
    expect(rowKeyAction({ key: "Enter", shiftKey: false, isComposing: true }, "x", 0)).toEqual({ kind: "none" });
  });

  it("celebrates only the tick that finishes the list", () => {
    expect(completesList([row("a", 0, true), row("b")], row("b"))).toBe(true);
    expect(completesList([row("a"), row("b")], row("b"))).toBe(false);
    expect(completesList([row("a", 0, true)], row("a", 0, true))).toBe(false);
  });

  it("offers checked history back but not what is already on the list", () => {
    expect(activeTexts([row("a", 0, false, "Milk"), row("b", 0, true, "Eggs"), row("c", 0, false, " ")])).toEqual(["Milk"]);
  });

  it("drops whitespace rows on close, and only when there are any", () => {
    expect(prunedRows([row("a"), row("b", 0, false, "  ")])?.map((i) => i.id)).toEqual(["a"]);
    expect(prunedRows([row("a")])).toBeNull();
  });

  it("cycles suggestion highlight through none and back", () => {
    expect(cycleIndex(-1, 1, 2)).toBe(0);
    expect(cycleIndex(1, 1, 2)).toBe(-1);
    expect(cycleIndex(-1, -1, 2)).toBe(1);
  });
});
