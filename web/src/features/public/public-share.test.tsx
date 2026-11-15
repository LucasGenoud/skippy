import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import { makeNote, type Stage } from "@/lib/models/note";
import type { PublicShare } from "@/lib/models/misc";
import { FakeApi } from "@/tests/fake-api";
import { boardColumns, checklistPreview, gridColumnCount, masonryColumns } from "./public-layout";
import { PublicShareScreen } from "./public-share-screen";

beforeAll(() => {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: (query: string) => ({ matches: false, media: query, addEventListener() {}, removeEventListener() {} }),
  });
});

afterEach(cleanup);

const stage = (id: string, position: number): Stage => ({ id, workspaceId: "w", collectionId: null, name: id.toUpperCase(), color: null, position });

describe("layout rules", () => {
  it("fits one column per 250px, one to four", () => {
    expect(gridColumnCount(0)).toBe(1);
    expect(gridColumnCount(520)).toBe(2);
    expect(gridColumnCount(2000)).toBe(4);
  });

  it("deals each card into the shortest column", () => {
    const tall = makeNote({ id: "tall", content: "x\n".repeat(12) });
    const short = (id: string) => makeNote({ id, content: "hi" });
    const columns = masonryColumns([tall, short("a"), short("b"), short("c")], 2);
    expect(columns.map((c) => c.map((n) => n.id))).toEqual([["tall"], ["a", "b", "c"]]);
  });

  it("orders the board: unassigned first, stages by position, cards by stage position", () => {
    const notes = [
      makeNote({ id: "n1", stageId: "b", stagePosition: 2 }),
      makeNote({ id: "n2", stageId: "b", stagePosition: 1 }),
      makeNote({ id: "n3" }),
    ];
    const columns = boardColumns(notes, [stage("b", 2), stage("a", 1)]);
    expect(columns.map((c) => [c.title, c.notes.map((n) => n.id)])).toEqual([
      ["Unassigned", ["n3"]],
      ["A", []],
      ["B", ["n2", "n1"]],
    ]);
    expect(boardColumns([], [stage("a", 1)]).map((c) => c.key)).toEqual(["a"]);
  });

  it("lists pending rows first and caps the preview at eight", () => {
    const items = Array.from({ length: 10 }, (_, i) => ({ id: `i${i}`, text: `${i}`, done: i === 0, depth: 0 }));
    const preview = checklistPreview(items, "preview");
    expect(preview.shown.map((i) => i.id)[0]).toBe("i1");
    expect(preview.shown).toHaveLength(8);
    expect(preview.hidden).toBe(2);
    const full = checklistPreview(items, "full");
    expect(full.hidden).toBe(0);
    expect(full.shown.at(-1)?.id).toBe("i0");
  });
});

describe("PublicShareScreen", () => {
  const share = (fields: Partial<PublicShare>): PublicShare => ({
    target: "notes",
    title: "Trip",
    sharedBy: "Ada",
    notes: [],
    labels: [],
    stages: [],
    expiresAt: null,
    ...fields,
  });

  it("draws the shared notes read only", async () => {
    const api = new FakeApi();
    api.publicShares.set(
      "ab12",
      share({
        notes: [
          makeNote({ id: "n1", title: "Packing", kind: "checklist", items: [{ id: "i", text: "Socks", done: true, depth: 0 }] }),
          makeNote({ id: "n2", content: "See https://example.com" }),
        ],
      }),
    );
    render(<PublicShareScreen token="ab12" api={api} />);
    // The spinner fades out before the page fades in.
    expect(await screen.findByRole("heading", { name: "Trip" })).toBeTruthy();
    expect(screen.getByText("Shared by Ada")).toBeTruthy();
    expect(screen.getByText("Read only")).toBeTruthy();
    expect(screen.getByText("Socks")).toBeTruthy();
    expect(screen.getByRole("link", { name: "https://example.com" })).toBeTruthy();
    expect(screen.queryByRole("textbox")).toBeNull();
  });

  it("says the same thing for any link that does not resolve, and can retry", async () => {
    const api = new FakeApi();
    render(<PublicShareScreen token="dead" api={api} />);
    expect(await screen.findByText("This link is not available")).toBeTruthy();

    api.publicShares.set("dead", share({ target: "note", title: "Late" }));
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: /try again/i }));
    });
    expect(await screen.findByText("This note is empty", {}, { timeout: 2000 })).toBeTruthy();
  });
});
