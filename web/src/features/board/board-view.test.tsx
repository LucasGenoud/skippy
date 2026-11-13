import { act, cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { MemoryKeyValueStore } from "@/lib/state/local-cache";
import { SessionProvider } from "@/lib/store/hooks";
import { Session } from "@/lib/store/session";
import { FakeApi } from "@/tests/fake-api";

import { BoardView } from "./board-view";
import { MoveToStageDialog } from "./move-to-stage-dialog";
import { StageEditorDialog, stageNameError } from "./stage-editor";

const COLLECTION = "w-default-general";

let api: FakeApi;
let session: Session;

beforeEach(() => {
  api = new FakeApi();
  session = new Session({ api, userId: "u-me", cache: new MemoryKeyValueStore(), accountOrigin: "existing", restoredSession: false, offlineGraceMs: 20 });
});

afterEach(() => {
  cleanup();
  session.dispose();
});

function seedStage(id: string, name: string, position: number): void {
  api.stages.set(id, { id, workspaceId: api.defaultWorkspaceId, collectionId: COLLECTION, name, color: null, position });
}

async function renderWith(node: React.ReactNode) {
  await act(async () => {
    await session.notes.load();
  });
  return render(<SessionProvider session={session}>{node}</SessionProvider>);
}

describe("stageNameError", () => {
  const stages = [{ id: "s1", workspaceId: "w", collectionId: null, name: "Doing", color: null, position: 1 }];

  it("asks for a name and refuses a clash, case-insensitively", () => {
    expect(stageNameError("  ", stages, null)).toBe("Name a column");
    expect(stageNameError("doing", stages, null)).toBe("That column already exists");
    expect(stageNameError("doing", stages, "s1")).toBeNull();
    expect(stageNameError("Done", stages, null)).toBeNull();
  });
});

describe("BoardView", () => {
  it("invites setting up a board that has no columns", async () => {
    api.seedNote({ id: "n1", title: "Loose", collectionId: COLLECTION });
    await renderWith(<BoardView />);
    expect(screen.getByText("Add columns to build a board for this workspace")).toBeTruthy();
    expect(screen.getByRole("button", { name: /Add a column/ })).toBeTruthy();
  });

  it("files cards into their stage columns, Unassigned first", async () => {
    seedStage("s1", "Doing", 1000);
    seedStage("s2", "Done", 2000);
    api.seedNote({ id: "n1", title: "Write tests", collectionId: COLLECTION, stageId: "s1", stagePosition: 1000 });
    api.seedNote({ id: "n2", title: "Loose idea", collectionId: COLLECTION });
    await renderWith(<BoardView />);

    const doing = screen.getByRole("region", { name: "Doing" });
    expect(within(doing).getByText("Write tests")).toBeTruthy();
    const unassigned = screen.getByRole("region", { name: "Unassigned" });
    expect(within(unassigned).getByText("Loose idea")).toBeTruthy();
    expect(within(screen.getByRole("region", { name: "Done" })).getByText("Drop notes here")).toBeTruthy();
    // The phone layout's strip names every column (jsdom has no wide viewport).
    const tabs = screen.getAllByRole("tab").map((t) => t.textContent);
    expect(tabs[0]).toContain("Unassigned");
    expect(tabs[1]).toContain("Doing");
  });

  it("composes a note straight into a column", async () => {
    seedStage("s1", "Doing", 1000);
    await renderWith(<BoardView />);
    const doing = screen.getByRole("region", { name: "Doing" });
    fireEvent.click(within(doing).getByRole("button", { name: /Add note/ }));
    const drafts = Object.keys(session.notes.state.drafts);
    expect(drafts).toHaveLength(1);
    expect(session.notes.noteById(drafts[0]!)?.stageId).toBe("s1");
  });
});

describe("StageEditorDialog", () => {
  it("refuses a duplicate name, then adds the column", async () => {
    seedStage("s1", "Doing", 1000);
    await renderWith(<StageEditorDialog stageId={null} open onOpenChange={() => {}} />);
    const name = screen.getByLabelText("Name");
    fireEvent.change(name, { target: { value: "doing" } });
    fireEvent.click(screen.getByRole("button", { name: "Add" }));
    expect(screen.getByText("That column already exists")).toBeTruthy();

    fireEvent.change(name, { target: { value: "Review" } });
    fireEvent.click(screen.getByRole("button", { name: "Add" }));
    expect(session.notes.stages.map((s) => s.name)).toEqual(["Doing", "Review"]);
  });
});

describe("MoveToStageDialog", () => {
  it("marks the current column and moves the note", async () => {
    seedStage("s1", "Doing", 1000);
    api.seedNote({ id: "n1", title: "Card", collectionId: COLLECTION });
    let open = true;
    await renderWith(<MoveToStageDialog noteIds={["n1"]} open onOpenChange={(v) => (open = v)} />);
    expect(screen.getByRole("option", { name: "Unassigned" }).getAttribute("aria-selected")).toBe("true");
    fireEvent.click(screen.getByRole("option", { name: "Doing" }));
    expect(open).toBe(false);
    expect(session.notes.noteById("n1")?.stageId).toBe("s1");
  });
});
