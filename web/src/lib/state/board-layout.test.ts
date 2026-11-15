import { describe, expect, it } from "vitest";
import { makeNote, type Note, type Stage } from "@/lib/models/note";
import { boardHasNoStages, boardPositionForInsertion, boardPositionForReorder, buildBoard, columnTitle, hiddenCount, UNASSIGNED_PREVIEW_LIMIT } from "./board-layout";

// Ported from `app/test/board_test.dart`.

const now = new Date(2026, 6, 27);
const note = (id: string, fields: Partial<Note> = {}): Note => makeNote({ id, workspaceId: "w1", createdAt: now, updatedAt: now, ...fields });
const stage = (id: string, position: number): Stage => ({ id, name: id, workspaceId: "w1", collectionId: null, color: null, position });
const ids = (notes: readonly Note[]): string[] => notes.map((n) => n.id);

describe("buildBoard", () => {
  it("orders columns by stage position, unassigned first", () => {
    const board = buildBoard({ notes: [], stages: [stage("done", 3072), stage("todo", 1024), stage("doing", 2048)] });
    expect(board.columns.map(columnTitle)).toEqual(["Unassigned", "todo", "doing", "done"]);
  });

  it("groups by stage, orders by stage position, pinned first", () => {
    const board = buildBoard({
      notes: [
        note("c", { stageId: "todo", stagePosition: 3072 }),
        note("a", { stageId: "todo", stagePosition: 1024 }),
        note("b", { stageId: "todo", stagePosition: 2048 }),
        note("p", { stageId: "todo", stagePosition: 9000, pinned: true }),
        note("loose"),
      ],
      stages: [stage("todo", 1024)],
    });
    expect(ids(board.columns[0]?.notes ?? [])).toEqual(["loose"]);
    expect(ids(board.columns[1]?.notes ?? [])).toEqual(["p", "a", "b", "c"]);
  });

  it("drops archived and trashed notes; unknown stages read as unassigned", () => {
    const board = buildBoard({
      notes: [note("live", { stageId: "s" }), note("arch", { stageId: "s", archived: true }), note("bin", { stageId: "s", trashed: true }), note("orphan", { stageId: "gone" })],
      stages: [stage("s", 1)],
    });
    expect(ids(board.columns[1]?.notes ?? [])).toEqual(["live"]);
    expect(ids(board.columns[0]?.notes ?? [])).toEqual(["orphan"]);
  });

  it("filters by search inside columns and ignores labels for placement", () => {
    const board = buildBoard({
      notes: [note("hit", { stageId: "s", title: "milk" }), note("miss", { stageId: "s", title: "eggs" }), note("b", { labelIds: ["s"] })],
      stages: [stage("s", 1)],
      query: "milk",
    });
    expect(ids(board.columns[1]?.notes ?? [])).toEqual(["hit"]);
  });

  it("caps the unassigned column unless asked, never a stage column", () => {
    const many = Array.from({ length: UNASSIGNED_PREVIEW_LIMIT + 5 }, (_, i) => note(`n${i}`));
    const capped = buildBoard({ notes: many, stages: [] });
    const column = capped.columns[0];
    expect(column?.notes.length).toBe(UNASSIGNED_PREVIEW_LIMIT);
    expect(column && hiddenCount(column)).toBe(5);
    expect(buildBoard({ notes: many, stages: [], showAllUnassigned: true }).columns[0] && hiddenCount(buildBoard({ notes: many, stages: [], showAllUnassigned: true }).columns[0] as never)).toBe(0);
    const staged = many.map((n) => ({ ...n, stageId: "s" }));
    expect(buildBoard({ notes: staged, stages: [stage("s", 1)] }).columns[1]?.notes.length).toBe(UNASSIGNED_PREVIEW_LIMIT + 5);
    expect(boardHasNoStages(capped)).toBe(true);
  });
});

describe("board reorder positions", () => {
  it("places a card at the head, tail, and between", () => {
    const a = note("a", { stagePosition: 1024 });
    const b = note("b", { stagePosition: 2048 });
    const moved = note("moved", { stagePosition: 4096 });
    expect(boardPositionForInsertion(moved, [moved])).toBe(1024);
    expect(boardPositionForInsertion(moved, [moved, a, b])).toBeLessThan(1024);
    expect(boardPositionForInsertion(moved, [a, b, moved])).toBeGreaterThan(2048);
    expect(boardPositionForInsertion(moved, [a, moved, b])).toBe(1536);
  });

  it("uses only the dragged card's pin group as neighbours", () => {
    const pinned = note("p", { stagePosition: 4096, pinned: true });
    const a = note("a", { stagePosition: 1024 });
    const b = note("b", { stagePosition: 2048 });
    expect(boardPositionForReorder(b, [pinned, a, b], [pinned, b, a])).toBeLessThan(1024);
    const incoming = note("incoming", { stagePosition: 8192 });
    expect(boardPositionForInsertion(incoming, [incoming, pinned, a])).toBeLessThan(1024);
  });

  it("treats crossing the pin boundary or an incomplete group as no move", () => {
    const pinned = note("p", { stagePosition: 4096, pinned: true });
    const plain = note("a", { stagePosition: 1024 });
    expect(boardPositionForReorder(plain, [pinned, plain], [plain, pinned])).toBeNull();
    const b = note("b", { stagePosition: 2048 });
    expect(boardPositionForReorder(b, [plain, b], [b])).toBeNull();
  });
});
