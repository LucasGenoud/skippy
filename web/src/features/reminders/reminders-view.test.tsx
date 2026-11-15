import { act, cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { MemoryKeyValueStore } from "@/lib/state/local-cache";
import { SessionProvider } from "@/lib/store/hooks";
import { Session } from "@/lib/store/session";
import { FakeApi } from "@/tests/fake-api";

import { RemindersView } from "./reminders-view";

// Thursday 12 November 2026, 10:00 local time. Only Date is faked, so
// animations and the store's timers run normally.
const NOW = new Date(2026, 10, 12, 10, 0);

let api: FakeApi;
let session: Session;

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(NOW);
  api = new FakeApi();
  session = new Session({ api, userId: "u-me", cache: new MemoryKeyValueStore(), accountOrigin: "existing", restoredSession: false, offlineGraceMs: 20 });
});

afterEach(() => {
  cleanup();
  session.dispose();
  vi.useRealTimers();
});

async function renderView() {
  await act(async () => {
    await session.notes.load();
  });
  return render(
    <SessionProvider session={session}>
      <RemindersView />
    </SessionProvider>,
  );
}

describe("RemindersView", () => {
  it("invites setting a reminder when there are none", async () => {
    await renderView();
    expect(screen.getByText("Notes with reminders appear here")).toBeTruthy();
    expect(screen.getByText("Nothing coming up")).toBeTruthy();
  });

  it("groups reminders by day and folds earlier ones away", async () => {
    api.seedNote({ id: "old", title: "Pay rent", reminderAt: new Date(2026, 10, 10, 9, 0) });
    api.seedNote({ id: "today", title: "Call Sam", reminderAt: new Date(2026, 10, 12, 18, 0) });
    api.seedNote({ id: "next", title: "Dentist", reminderAt: new Date(2026, 10, 13, 9, 0), reminderRepeat: "weekly" });
    await renderView();

    expect(screen.getByText("1 later today · 2 upcoming")).toBeTruthy();
    expect(screen.getByRole("heading", { name: "Today" })).toBeTruthy();
    expect(screen.getByRole("heading", { name: "Tomorrow" })).toBeTruthy();
    expect(screen.getByText("Every week")).toBeTruthy();
    expect(screen.queryByText("Pay rent")).toBeNull();

    fireEvent.click(screen.getByRole("button", { name: "Show earlier" }));
    expect(await screen.findByText("Pay rent")).toBeTruthy();
  });

  it("clears every earlier reminder at once", async () => {
    api.seedNote({ id: "a", title: "One", reminderAt: new Date(2026, 10, 9, 9, 0) });
    api.seedNote({ id: "b", title: "Two", reminderAt: new Date(2026, 10, 10, 9, 0) });
    await renderView();
    fireEvent.click(screen.getByRole("button", { name: "Show earlier" }));
    fireEvent.click(await screen.findByRole("button", { name: "Clear all" }));
    expect(session.notes.noteById("a")?.reminderAt).toBeNull();
    expect(session.notes.noteById("b")?.reminderAt).toBeNull();
  });

  it("ticks off a checklist row's reminder from its row", async () => {
    api.seedNote({
      id: "list",
      title: "Groceries",
      kind: "checklist",
      items: [{ id: "i1", text: "Buy milk", done: false, depth: 0 }],
      itemReminders: { i1: { itemId: "i1", at: new Date(2026, 10, 12, 17, 0), repeat: null } },
    });
    await renderView();
    const row = screen.getByText("Buy milk").closest("div") as HTMLElement;
    expect(within(row.parentElement as HTMLElement).getByText("Groceries")).toBeTruthy();
    fireEvent.click(screen.getByRole("checkbox", { name: "Mark done" }));
    await waitFor(() => expect(session.notes.noteById("list")?.items[0]?.done).toBe(true));
  });
});
