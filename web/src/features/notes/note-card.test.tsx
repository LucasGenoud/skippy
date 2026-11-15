import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { MemoryKeyValueStore } from "@/lib/state/local-cache";
import { SessionProvider } from "@/lib/store";
import { Session } from "@/lib/store/session";
import { FakeApi } from "@/tests/fake-api";

import { NoteCard } from "./note-card";

// What a click, a key and a checkbox on a card do: open, select, or tick an
// item without opening.

const navigate = vi.hoisted(() => vi.fn());
vi.mock("@/lib/router", async (importOriginal) => ({ ...(await importOriginal<typeof import("@/lib/router")>()), navigate }));

let api: FakeApi;
let session: Session;

beforeEach(async () => {
  vi.useFakeTimers();
  navigate.mockReset();
  api = new FakeApi();
  api.seedNote({ id: "n1", title: "Groceries", kind: "checklist", items: [{ id: "i1", text: "milk", done: false, depth: 0 }, { id: "i2", text: "eggs", done: false, depth: 1 }] });
  api.seedNote({ id: "n2", title: "Plain", content: "see https://example.com" });
  session = new Session({ api, userId: "u-me", cache: new MemoryKeyValueStore(), accountOrigin: "existing", restoredSession: false, offlineGraceMs: 20 });
  await session.notes.load();
});

afterEach(() => {
  cleanup();
  session.dispose();
  vi.useRealTimers();
});

function renderCard(id: string) {
  return render(
    <SessionProvider session={session}>
      <NoteCard noteId={id} variant="grid" />
    </SessionProvider>,
  );
}

it("opens the note on a plain click and selects on a modifier click", () => {
  renderCard("n2");
  const card = screen.getByRole("button", { name: "Open Plain" });
  fireEvent.click(card);
  expect(navigate).toHaveBeenCalledWith({ name: "note", noteId: "n2" });

  fireEvent.click(card, { metaKey: true });
  expect(session.ui.state.selectedIds).toEqual(["n2"]);
  expect(navigate).toHaveBeenCalledTimes(1);
});

it("toggles in selection mode, and Enter / Space follow the same rules", () => {
  renderCard("n2");
  const card = screen.getByRole("button", { name: "Open Plain" });
  fireEvent.keyDown(card, { key: " " });
  expect(session.ui.state.selectedIds).toEqual(["n2"]);
  // In selection mode a click toggles rather than opens.
  fireEvent.click(screen.getByRole("button", { name: "Deselect Plain" }));
  expect(session.ui.state.selectedIds).toEqual([]);
  fireEvent.keyDown(screen.getByRole("button", { name: "Open Plain" }), { key: "Enter" });
  expect(navigate).toHaveBeenCalledWith({ name: "note", noteId: "n2" });
});

it("ticks a checklist row from the card without opening the note", async () => {
  renderCard("n1");
  expect(screen.getByTestId("checklist-card-row-i2").style.paddingLeft).toBe("12px");
  fireEvent.click(screen.getByRole("checkbox", { name: "milk" }));
  expect(navigate).not.toHaveBeenCalled();
  await act(async () => {
    await vi.advanceTimersByTimeAsync(200);
  });
  expect(session.notes.noteById("n1")?.items.find((i) => i.id === "i1")?.done).toBe(true);
});
