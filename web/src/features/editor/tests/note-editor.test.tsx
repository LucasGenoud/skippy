import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { TooltipProvider } from "@/components/ui/tooltip";
import { MemoryKeyValueStore } from "@/lib/state/local-cache";
import { SessionProvider } from "@/lib/store/hooks";
import { Session } from "@/lib/store/session";
import { FakeApi } from "@/tests/fake-api";
import { NoteEditor } from "../note-editor";

// The editor's own rules, through the real stores and a fake API: typing goes
// to the store, undo groups and restores, the checklist keys behave like an
// outliner, and an untouched draft is thrown away on close.

let api: FakeApi;
let session: Session;

beforeEach(async () => {
  vi.useFakeTimers();
  window.matchMedia ??= ((query: string) => ({
    matches: query.includes("min-width"),
    media: query,
    addEventListener: () => undefined,
    removeEventListener: () => undefined,
  })) as unknown as typeof window.matchMedia;
  Element.prototype.scrollIntoView ??= () => undefined;
  globalThis.ResizeObserver ??= class {
    observe(): void {}
    unobserve(): void {}
    disconnect(): void {}
  } as unknown as typeof ResizeObserver;
  api = new FakeApi();
  api.seedNote({ id: "t", title: "Hello", content: "Body" });
  api.seedNote({
    id: "c",
    kind: "checklist",
    title: "List",
    items: [
      { id: "i1", text: "Milk", done: false, depth: 0 },
      { id: "i2", text: "Eggs", done: false, depth: 0 },
    ],
  });
  session = new Session({ api, userId: "u-me", cache: new MemoryKeyValueStore(), accountOrigin: "existing", restoredSession: false, offlineGraceMs: 20 });
  await session.notes.load();
});

afterEach(() => {
  cleanup();
  session.dispose();
  vi.useRealTimers();
});

function open(noteId: string, onClose = vi.fn()) {
  render(
    <SessionProvider session={session}>
      <TooltipProvider>
        <NoteEditor noteId={noteId} onClose={onClose} />
      </TooltipProvider>
    </SessionProvider>,
  );
  return onClose;
}

function type(element: HTMLElement, value: string): void {
  (element as HTMLTextAreaElement).value = value;
  fireEvent.input(element);
}

describe("NoteEditor", () => {
  it("writes typing through the store and undoes it with the shortcut", () => {
    open("t");
    const title = screen.getByLabelText("Title");
    type(title, "Hello world");
    expect(session.notes.noteById("t")?.title).toBe("Hello world");

    fireEvent.keyDown(title, { key: "z", ctrlKey: true });
    expect(session.notes.noteById("t")?.title).toBe("Hello");
    expect((title as HTMLTextAreaElement).value).toBe("Hello");

    fireEvent.keyDown(title, { key: "z", ctrlKey: true, shiftKey: true });
    expect(session.notes.noteById("t")?.title).toBe("Hello world");
  });

  it("freezes the card while open and releases it on close", async () => {
    open("t");
    expect("t" in session.notes.state.editingCards).toBe(true);
    cleanup();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1);
    });
    expect("t" in session.notes.state.editingCards).toBe(false);
  });

  it("throws away an untouched draft on close", async () => {
    const draft = session.notes.createDraft();
    session.notes.beginEditing(draft.id, "new");
    open(draft.id);
    cleanup();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1);
    });
    expect(session.notes.noteById(draft.id)).toBeNull();
  });

  it("continues a checklist with Enter and nests with Tab", () => {
    open("c");
    const rows = screen.getAllByLabelText("List item") as HTMLTextAreaElement[];
    const milk = rows.find((r) => r.value === "Milk") as HTMLTextAreaElement;
    fireEvent.keyDown(milk, { key: "Enter" });
    let items = session.notes.noteById("c")?.items ?? [];
    expect(items.map((i) => i.text)).toEqual(["Milk", "", "Eggs"]);

    const eggs = (screen.getAllByLabelText("List item") as HTMLTextAreaElement[]).find((r) => r.value === "Eggs") as HTMLTextAreaElement;
    fireEvent.keyDown(eggs, { key: "Tab" });
    items = session.notes.noteById("c")?.items ?? [];
    expect(items.find((i) => i.text === "Eggs")?.depth).toBe(1);
  });

  it("removes an empty top-level row on Backspace", () => {
    open("c");
    const milk = (screen.getAllByLabelText("List item") as HTMLTextAreaElement[]).find((r) => r.value === "Milk") as HTMLTextAreaElement;
    fireEvent.keyDown(milk, { key: "Enter" });
    const empty = (screen.getAllByLabelText("List item") as HTMLTextAreaElement[]).find((r) => r.value === "" && r.placeholder !== "List item") as HTMLTextAreaElement;
    fireEvent.keyDown(empty, { key: "Backspace" });
    expect(session.notes.noteById("c")?.items.map((i) => i.text)).toEqual(["Milk", "Eggs"]);
  });

  it("creates a row from the composer's first keystroke", () => {
    open("c");
    const composer = screen.getByPlaceholderText("List item");
    type(composer, "B");
    expect(session.notes.noteById("c")?.items.map((i) => i.text)).toEqual(["Milk", "Eggs", "B"]);
    type(composer, "Bread");
    fireEvent.keyDown(composer, { key: "Enter" });
    expect(session.notes.noteById("c")?.items.map((i) => i.text)).toEqual(["Milk", "Eggs", "Bread"]);
    expect((composer as HTMLTextAreaElement).value).toBe("");
  });

  it("links a note picked while typing [[ and removes the link as one unit", async () => {
    const target = "3f2c1a4e-0000-4000-8000-000000000001";
    api.seedNote({ id: target, title: "Linked" });
    await session.notes.load();
    open("t");
    const body = screen.getByLabelText("Note") as HTMLTextAreaElement;
    body.focus();
    body.value = "Body [[Lin";
    body.setSelectionRange(10, 10);
    fireEvent.input(body);
    fireEvent.click(screen.getByRole("option", { name: "Linked" }));
    const content = session.notes.noteById("t")?.content ?? "";
    expect(content).toBe(`Body [[${target}|Linked]] `);

    // Backspace into the token takes the whole link with it.
    body.value = content.slice(0, -2);
    fireEvent.input(body);
    expect(session.notes.noteById("t")?.content).toBe("Body ");
  });

  it("opens find with the shortcut and counts matches", () => {
    open("t");
    const title = screen.getByLabelText("Title");
    fireEvent.keyDown(title, { key: "f", metaKey: true });
    const find = screen.getByLabelText("Find in note");
    fireEvent.change(find, { target: { value: "o" } });
    expect(screen.getByText("1 of 1")).toBeTruthy();
  });
});
