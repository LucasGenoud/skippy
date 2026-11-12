import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeAll, beforeEach, expect, it, vi } from "vitest";
import { MemoryKeyValueStore } from "@/lib/state/local-cache";
import { SessionProvider } from "@/lib/store/hooks";
import { Session } from "@/lib/store/session";
import { FakeApi } from "@/tests/fake-api";
import { AppShell } from "./index";

// The shell's own rules, end to end over a real session: the keyboard
// shortcuts, sidebar navigation, empty states, and the selection bar.

// The avatar menu reads the auth store, which this test does not build.
vi.mock("./top-bar-controls", async (importOriginal) => ({
  ...(await importOriginal<typeof import("./top-bar-controls")>()),
  UserMenu: () => <span data-testid="user-menu" />,
}));

beforeAll(() => {
  class Observer {
    observe(): void {}
    unobserve(): void {}
    disconnect(): void {}
  }
  Object.assign(globalThis, { ResizeObserver: Observer });
});

let api: FakeApi;
let session: Session;

beforeEach(async () => {
  window.history.replaceState(null, "", "/");
  api = new FakeApi();
  api.seedNote({ id: "a", title: "Alpha", position: 1 });
  api.labels.set("l1", { id: "l1", workspaceId: "w-default", name: "Work", color: null, icon: null, position: 0 });
  session = new Session({ api, userId: "u-me", cache: new MemoryKeyValueStore(), accountOrigin: "existing", restoredSession: false, offlineGraceMs: 20 });
  await session.notes.load();
});

afterEach(() => {
  cleanup();
  session.dispose();
});

function renderShell() {
  return render(
    <SessionProvider session={session}>
      <AppShell>
        <div data-testid="view" />
      </AppShell>
    </SessionProvider>,
  );
}

const key = (k: string, init: KeyboardEventInit = {}): void => {
  act(() => {
    window.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...init }));
  });
};

it("focuses search with / and Cmd K, and Escape clears the search", () => {
  renderShell();
  const box = screen.getByRole("searchbox");
  key("/");
  expect(document.activeElement).toBe(box);

  fireEvent.change(box, { target: { value: "alp" } });
  expect(session.ui.state.query).toBe("alp");
  // Printable keys type while the field has focus.
  fireEvent.keyDown(box, { key: "c" });
  expect(session.notes.state.order).toEqual(["a"]);

  fireEvent.keyDown(box, { key: "Escape" });
  expect(session.ui.state.query).toBe("");

  (document.activeElement as HTMLElement).blur();
  key("k", { metaKey: true });
  expect(document.activeElement).toBe(box);
});

it("Escape leaves selection mode before it clears the search", () => {
  renderShell();
  act(() => {
    session.ui.setQuery("alpha");
    session.ui.setSelected("a", true);
  });
  key("Escape");
  expect(session.ui.state.selectedIds).toEqual([]);
  expect(session.ui.state.query).toBe("alpha");
  key("Escape");
  expect(session.ui.state.query).toBe("");
});

it("starts a note of the pressed kind and opens its editor", () => {
  renderShell();
  key("l");
  const ids = Object.keys(session.notes.state.drafts);
  expect(ids).toHaveLength(1);
  expect(session.notes.noteById(ids[0]!)?.kind).toBe("checklist");
  expect(window.location.pathname).toBe(`/n/${ids[0]}`);
});

it("opens the shortcut reference with ?", async () => {
  renderShell();
  key("?", { shiftKey: true });
  expect(await screen.findByText("Keyboard shortcuts")).toBeTruthy();
});

it("opens a label from the sidebar and toggles back to the notes", () => {
  renderShell();
  fireEvent.click(screen.getByRole("button", { name: "Work" }));
  expect(session.ui.state.destination).toEqual({ label: "l1" });
  fireEvent.click(screen.getByRole("button", { name: "Work" }));
  expect(session.ui.state.destination).toBe("notes");
});

it("shows the archive's empty state with a way back", () => {
  renderShell();
  fireEvent.click(screen.getByRole("button", { name: "Archive" }));
  expect(screen.getByText("Your archived notes appear here")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Browse notes" }));
  expect(session.ui.state.destination).toBe("notes");
});

it("trashes the selection from the selection bar and leaves selection mode", async () => {
  renderShell();
  act(() => session.ui.setSelected("a", true));
  expect(await screen.findByText("selected")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Move selected notes to Trash" }));
  expect(session.notes.noteById("a")?.trashed).toBe(true);
  expect(session.ui.state.selectedIds).toEqual([]);
});

it("ignores shortcuts while a note is open", async () => {
  renderShell();
  act(() => {
    window.history.pushState(null, "", "/n/a");
    window.dispatchEvent(new PopStateEvent("popstate"));
  });
  key("c");
  expect(Object.keys(session.notes.state.drafts)).toHaveLength(0);
  act(() => {
    window.history.pushState(null, "", "/");
    window.dispatchEvent(new PopStateEvent("popstate"));
  });
  await waitFor(() => undefined);
});

it("opens the shortcut reference from outside the shell through a host", async () => {
  const { ShortcutHelpHost, openShortcutHelp } = await import("./shortcut-help");
  render(<ShortcutHelpHost />);
  expect(screen.queryByText("Keyboard shortcuts")).toBeNull();
  act(() => openShortcutHelp());
  expect(await screen.findByText("Keyboard shortcuts")).toBeTruthy();
});

it("offers a label's actions on right-click, deleting only after a confirm", async () => {
  renderShell();
  const row = screen.getByRole("button", { name: "Work" }).parentElement as HTMLElement;
  fireEvent.contextMenu(row);
  expect(await screen.findByRole("menuitem", { name: "Edit label…" })).toBeTruthy();

  fireEvent.click(screen.getByRole("menuitem", { name: "Delete label…" }));
  const confirm = await screen.findByRole("button", { name: "Delete label" });
  expect(session.notes.state.labels.map((l) => l.id)).toEqual(["l1"]);
  fireEvent.click(confirm);
  await waitFor(() => expect(session.notes.state.labels).toEqual([]));
});
