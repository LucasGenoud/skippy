import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { MemoryKeyValueStore } from "@/lib/state/local-cache";
import { SessionProvider } from "@/lib/store/hooks";
import { Session } from "@/lib/store/session";
import { FakeApi } from "@/tests/fake-api";
import { makeWorkspace } from "@/lib/models";
import { CollectionSettingsDialog, deleteCollectionMessage } from "./collection-settings-dialog";
import { deletionMessage } from "./danger-zone";
import { copyName } from "./duplicate-workspace-dialog";
import { monthBarFraction } from "./stats-charts";
import { aiStatus, WorkspaceAiSection } from "./workspace-ai-section";
import { initialOf } from "./people-section";

let api: FakeApi;
let session: Session;

beforeAll(() => {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: (query: string) => ({ matches: false, media: query, addEventListener() {}, removeEventListener() {} }),
  });
});

beforeEach(async () => {
  api = new FakeApi();
  session = new Session({ api, userId: "u-me", cache: new MemoryKeyValueStore(), accountOrigin: "existing", restoredSession: false, offlineGraceMs: 20 });
  await session.notes.load();
});

afterEach(() => {
  cleanup();
  session.dispose();
});

const withSession = (ui: React.ReactNode) => <SessionProvider session={session}>{ui}</SessionProvider>;

describe("wording", () => {
  it("says what a delete takes with it", () => {
    expect(deletionMessage(0)).toBe("Its labels and board columns are removed. This can't be undone.");
    expect(deletionMessage(1)).toMatch(/^1 note and all its attachments/);
    expect(deletionMessage(3)).toMatch(/^3 notes and all their attachments/);
    expect(deleteCollectionMessage(1)).toMatch(/^1 note will move/);
    expect(deleteCollectionMessage(2)).toMatch(/^2 notes will move/);
  });

  it("names a copy within the length limit", () => {
    expect(copyName("Groceries")).toBe("Groceries copy");
    expect(copyName("x".repeat(70))).toBe(`${"x".repeat(55)} copy`);
  });

  it("explains whose provider runs the AI", () => {
    expect(aiStatus(true, true, "Ada")).toBe("Runs on your AI provider, for everyone here");
    expect(aiStatus(true, false, "Ada")).toBe("Runs on Ada's AI provider");
    expect(aiStatus(false, true, "Ada")).toBe("Needs your AI provider");
    expect(aiStatus(false, false, "Ada")).toBe("Ada hasn't set up an AI provider");
  });

  it("draws quiet months empty and busy ones above the floor", () => {
    expect(monthBarFraction(0, 5)).toBe(0);
    expect(monthBarFraction(5, 5)).toBe(1);
    expect(monthBarFraction(1, 100)).toBeGreaterThan(0.06);
    expect(initialOf("  ada")).toBe("A");
    expect(initialOf("")).toBe("?");
  });
});

describe("WorkspaceAiSection", () => {
  it("gives the owner switches, and turning AI off locks the features", () => {
    const workspace = session.notes.workspaceById("w-default");
    if (!workspace) {
      throw new Error("no workspace");
    }
    const view = render(withSession(<WorkspaceAiSection workspace={workspace} isOwner />));
    const master = screen.getByRole("switch", { name: /AI in this workspace/ });
    expect(master.getAttribute("aria-checked")).toBe("true");
    fireEvent.click(master);
    const updated = session.notes.workspaceById("w-default");
    expect(updated?.ai.switches.enabled).toBe(false);
    view.rerender(withSession(<WorkspaceAiSection workspace={updated ?? workspace} isOwner />));
    expect(screen.getByRole("switch", { name: /Automatic labeling/ }).hasAttribute("disabled")).toBe(true);
  });

  it("shows a member what is in effect, read-only", () => {
    const shared = makeWorkspace({
      id: "w-other",
      name: "Shared",
      owner: { id: "u-ada", name: "Ada" },
      ai: { switches: { enabled: false, labeling: true, chat: true, writing: true, assistantAccess: true }, providerReady: true, rewriteTasks: [] },
    });
    render(withSession(<WorkspaceAiSection workspace={shared} isOwner={false} />));
    expect(screen.queryByRole("switch")).toBeNull();
    expect(screen.getByText("Only Ada can change these.")).toBeTruthy();
    expect(screen.getByText("Runs on Ada's AI provider")).toBeTruthy();
    // Labeling is on, but AI is off here, so it reads Off.
    expect(screen.getAllByText("Off").length).toBe(4);
  });
});

describe("CollectionSettingsDialog", () => {
  it("refuses a blank name and saves a new collection", async () => {
    const onOpenChange = vi.fn();
    render(withSession(<CollectionSettingsDialog workspaceId="w-default" open onOpenChange={onOpenChange} />));
    fireEvent.click(screen.getByText("Save"));
    expect(screen.getByText("Enter a collection name")).toBeTruthy();
    fireEvent.change(screen.getByLabelText("Name"), { target: { value: "Recipes" } });
    fireEvent.click(screen.getByRole("radio", { name: /Board/ }));
    await act(async () => fireEvent.click(screen.getByText("Save")));
    const created = session.notes.workspaceById("w-default")?.collections.find((c) => c.name === "Recipes");
    expect(created?.layout).toBe("board");
    expect(onOpenChange).toHaveBeenCalledWith(false);
  });
});
