import { describe, expect, it } from "vitest";
import { makeNote, type Label } from "@/lib/models/note";
import { DragDepth, clipboardHandles, dragHasFiles, toDroppedFiles } from "./browser-files";
import { chipState, chipText, filterGroups, querySegments, quotedToken } from "./search-rules";
import { allSelected, commonValue, labelsDroppedByMove, pinsSelection, selectionLabel, selectionOffer, trashMessage, trashPlan } from "./selection-rules";
import { isEditableTarget, modifierName, shortcutFor, type ShortcutKey } from "./shortcuts";
import { emptyCopy, viewTitle } from "./view-rules";

const key = (k: string, mods: Partial<ShortcutKey> = {}): ShortcutKey => ({ key: k, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false, ...mods });

describe("shortcutFor", () => {
  it("maps the printable keys while idle", () => {
    expect(shortcutFor(key("c"), "idle")).toEqual({ type: "newNote", kind: "text" });
    expect(shortcutFor(key("n"), "idle")).toEqual({ type: "newNote", kind: "text" });
    expect(shortcutFor(key("l"), "idle")).toEqual({ type: "newNote", kind: "checklist" });
    expect(shortcutFor(key("m"), "idle")).toEqual({ type: "newNote", kind: "markdown" });
    expect(shortcutFor(key("/"), "idle")).toEqual({ type: "focusSearch" });
  });

  it("matches the character produced, so Shift is allowed for ? and /", () => {
    expect(shortcutFor(key("?", { shiftKey: true }), "idle")).toEqual({ type: "help" });
    expect(shortcutFor(key("/", { shiftKey: true }), "idle")).toEqual({ type: "focusSearch" });
    // Shift+C types "C", which is not the shortcut.
    expect(shortcutFor(key("C", { shiftKey: true }), "idle")).toBeNull();
  });

  it("lets printable keys reach a focused text field", () => {
    expect(shortcutFor(key("c"), "typing")).toBeNull();
    expect(shortcutFor(key("/"), "typing")).toBeNull();
    expect(shortcutFor(key("?"), "typing")).toBeNull();
  });

  it("keeps chords and Escape live while typing", () => {
    expect(shortcutFor(key("k", { ctrlKey: true }), "typing")).toEqual({ type: "focusSearch" });
    expect(shortcutFor(key("k", { metaKey: true }), "typing")).toEqual({ type: "focusSearch" });
    expect(shortcutFor(key("g", { ctrlKey: true }), "typing")).toEqual({ type: "toggleLayout" });
    expect(shortcutFor(key("G", { metaKey: true }), "idle")).toEqual({ type: "toggleLayout" });
    expect(shortcutFor(key("Escape"), "typing")).toEqual({ type: "escape" });
  });

  it("ignores chords with extra modifiers and unknown keys", () => {
    expect(shortcutFor(key("k", { ctrlKey: true, shiftKey: true }), "idle")).toBeNull();
    expect(shortcutFor(key("k", { ctrlKey: true, altKey: true }), "idle")).toBeNull();
    expect(shortcutFor(key("c", { ctrlKey: true }), "idle")).toBeNull();
    expect(shortcutFor(key("c", { altKey: true }), "idle")).toBeNull();
    expect(shortcutFor(key("x"), "idle")).toBeNull();
    expect(shortcutFor(key("Escape", { metaKey: true }), "idle")).toBeNull();
  });

  it("names the modifier by platform", () => {
    expect(modifierName("MacIntel")).toBe("Cmd");
    expect(modifierName("iPhone")).toBe("Cmd");
    expect(modifierName("Win32")).toBe("Ctrl");
  });
});

describe("isEditableTarget", () => {
  it("treats text inputs, textareas and contenteditable as typing", () => {
    const input = document.createElement("input");
    const checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    const area = document.createElement("textarea");
    const editable = document.createElement("div");
    editable.setAttribute("contenteditable", "true");
    const child = document.createElement("span");
    editable.append(child);
    expect(isEditableTarget(input)).toBe(true);
    expect(isEditableTarget(checkbox)).toBe(false);
    expect(isEditableTarget(area)).toBe(true);
    expect(isEditableTarget(child)).toBe(true);
    expect(isEditableTarget(document.createElement("button"))).toBe(false);
    expect(isEditableTarget(null)).toBe(false);
  });
});

describe("selection rules", () => {
  const a = makeNote({ id: "a", pinned: true });
  const b = makeNote({ id: "b", pinned: false });

  it("offers per destination", () => {
    expect(selectionOffer("notes")).toEqual({ archive: "archive", restore: false, trash: true, deleteForever: false });
    expect(selectionOffer("archive").archive).toBe("unarchive");
    expect(selectionOffer("trash")).toEqual({ archive: null, restore: true, trash: false, deleteForever: true });
  });

  it("pins while any is unpinned", () => {
    expect(pinsSelection([a, b])).toBe(true);
    expect(pinsSelection([a])).toBe(false);
  });

  it("knows when everything visible is selected", () => {
    expect(allSelected(["a", "b"], ["b", "a", "c"])).toBe(true);
    expect(allSelected(["a", "b"], ["a"])).toBe(false);
    expect(allSelected([], [])).toBe(false);
  });

  it("skips notes the user cannot trash and says so", () => {
    const plan = trashPlan([a, b], (id) => id === "a");
    expect(plan.trash.map((n) => n.id)).toEqual(["a"]);
    expect(plan.skipped).toBe(1);
    expect(trashMessage(1, 1)).toEqual({ text: "1 note moved to Trash; shared notes were skipped", kind: "danger" });
    expect(trashMessage(2, 0)?.text).toBe("2 notes moved to Trash");
    expect(trashMessage(0, 2)).toEqual({ text: "Only note owners can move notes to Trash", kind: "warning" });
    expect(trashMessage(0, 0)).toBeNull();
  });

  it("shares a value only when all agree", () => {
    expect(commonValue(["red", "red"], "default")).toBe("red");
    expect(commonValue(["red", "blue"], "default")).toBe("default");
    expect(commonValue([], "default")).toBe("default");
  });

  it("counts labels a workspace move drops", () => {
    const labels: Record<string, Label> = {
      l1: { id: "l1", workspaceId: "w1", name: "x", color: null, icon: null, position: 0 },
      l2: { id: "l2", workspaceId: "w2", name: "y", color: null, icon: null, position: 0 },
    };
    const note = makeNote({ id: "n", labelIds: ["l1", "l2", "gone"] });
    expect(labelsDroppedByMove(note, "w2", (id) => labels[id] ?? null)).toBe(2);
  });

  it("labels the count", () => {
    expect(selectionLabel(0)).toBe("Select notes");
    expect(selectionLabel(3)).toBe("3 selected");
  });
});

describe("search rules", () => {
  it("cuts a query into text and operators", () => {
    expect(querySegments("bread label:work -is:pinned")).toEqual([
      { text: "bread ", kind: "text" },
      { text: "label:work", kind: "filter" },
      { text: " ", kind: "text" },
      { text: "-is:pinned", kind: "excluded" },
    ]);
    expect(querySegments("plain words")).toEqual([{ text: "plain words", kind: "text" }]);
    expect(querySegments("")).toEqual([]);
  });

  it("quotes names with spaces", () => {
    expect(quotedToken("label", "To do")).toBe('label:"To do"');
    expect(quotedToken("label", "work")).toBe("label:work");
  });

  it("lists labels first, only when there are some", () => {
    expect(filterGroups([]).map((g) => g.title)).toEqual(["State", "Contents", "Kind", "Color"]);
    expect(filterGroups(["a b"])[0]).toEqual({ title: "Labels", tokens: ['label:"a b"'] });
  });

  it("reads a chip's state from the query", () => {
    expect(chipState("", "has:link")).toBe("off");
    expect(chipState("has:link", "has:link")).toBe("matching");
    expect(chipState("hasnot:link", "has:link")).toBe("excluding");
    expect(chipText("excluding", "has:link")).toBe("hasnot:link");
    expect(chipText("matching", "has:link")).toBe("has:link");
  });
});

describe("view rules", () => {
  it("titles each view", () => {
    const names = { collection: "Home", label: "Work", smartView: null };
    expect(viewTitle({ view: "notes" }, names)).toBe("Home");
    expect(viewTitle({ view: "board" }, { ...names, collection: null })).toBe("Collections");
    expect(viewTitle({ view: "label", labelId: "l" }, names)).toBe("Work");
    expect(viewTitle({ view: "smart", savedViewId: "s" }, names)).toBe("Smart view");
    expect(viewTitle({ view: "trash" }, names)).toBe("Trash");
  });

  it("offers a way out of an empty view", () => {
    expect(emptyCopy({ view: "notes" }, true).message).toBe("No matching notes");
    expect(emptyCopy({ view: "notes" }, false)).toMatchObject({ action: "create", mark: "logo" });
    expect(emptyCopy({ view: "smart", savedViewId: "s" }, false).action).toBe("browse");
    expect(emptyCopy({ view: "trash" }, false).action).toBe("browse");
    expect(emptyCopy({ view: "label", labelId: "l" }, false).action).toBe("create");
  });
});

describe("browser files", () => {
  const transfer = (files: File[], types: string[] = ["Files"]): DataTransfer =>
    ({ types, files, items: [] }) as unknown as DataTransfer;

  it("recognises a file drag", () => {
    expect(dragHasFiles(transfer([]))).toBe(true);
    expect(dragHasFiles(transfer([], ["text/plain"]))).toBe(false);
    expect(dragHasFiles(null)).toBe(false);
  });

  it("falls back to clipboard items", () => {
    const file = new File(["x"], "a.png", { type: "image/png" });
    const data = { files: [], items: [{ kind: "string", getAsFile: () => null }, { kind: "file", getAsFile: () => file }] } as unknown as DataTransfer;
    expect(clipboardHandles(data)).toEqual([file]);
  });

  it("stamps generic pasted names, keeps dropped ones, and drops over-size files", () => {
    const at = new Date(2026, 0, 2, 3, 4, 5);
    const shot = new File(["x"], "image.png", { type: "image/png" });
    const doc = new File(["x"], "report.pdf", { type: "" });
    const big = new File(["x"], "big.bin");
    Object.defineProperty(big, "size", { value: 26 * 1024 * 1024 });
    const pasted = toDroppedFiles([shot, big], "paste", at);
    expect(pasted).toHaveLength(1);
    expect(pasted[0]?.name).toMatch(/^pasted-20260102-030405\.png$/);
    const dropped = toDroppedFiles([doc], "drop", at);
    expect(dropped[0]).toMatchObject({ name: "report.pdf", mime: "application/pdf" });
  });

  it("nets nested drag boundaries", () => {
    const depth = new DragDepth();
    depth.enter();
    depth.enter();
    expect(depth.leave()).toBe(true);
    expect(depth.leave()).toBe(false);
    expect(depth.leave()).toBe(false);
  });
});
