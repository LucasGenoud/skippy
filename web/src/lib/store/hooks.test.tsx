import { act, render } from "@testing-library/react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { MemoryKeyValueStore } from "@/lib/state/local-cache";
import { FakeApi } from "@/tests/fake-api";
import { SessionProvider, useNote, useNotesController, useVisibleNoteIds } from "./hooks";
import { Session } from "./session";

// The narrow-subscription contract the feature agents rely on: editing one
// note re-renders that note's card, not its siblings, and the visible id list
// keeps its identity while membership and order are unchanged.

let api: FakeApi;
let session: Session;

beforeEach(() => {
  vi.useFakeTimers();
  api = new FakeApi();
  api.seedNote({ id: "a", title: "A", position: 1 });
  api.seedNote({ id: "b", title: "B", position: 2 });
  session = new Session({ api, userId: "u-me", cache: new MemoryKeyValueStore(), accountOrigin: "existing", restoredSession: false, offlineGraceMs: 20 });
});

afterEach(() => {
  session.dispose();
  vi.useRealTimers();
});

it("re-renders only the card whose note changed, and keeps the id list stable", async () => {
  await session.notes.load();
  const renders: Record<string, number> = { a: 0, b: 0, list: 0 };
  const lists: (readonly string[])[] = [];

  function Card({ id }: { id: string }) {
    const note = useNote(id);
    renders[id] = (renders[id] ?? 0) + 1;
    return <span>{note?.title}</span>;
  }

  function List() {
    const { others } = useVisibleNoteIds();
    useNotesController();
    renders.list = (renders.list ?? 0) + 1;
    lists.push(others);
    return (
      <>
        {others.map((id) => (
          <Card key={id} id={id} />
        ))}
      </>
    );
  }

  const view = render(
    <SessionProvider session={session}>
      <List />
    </SessionProvider>,
  );
  expect(view.container.textContent).toBe("AB");
  const before = { ...renders };

  act(() => session.notes.setColor("a", "teal"));
  expect(renders.a).toBe((before.a ?? 0) + 1);
  expect(renders.b).toBe(before.b);
  expect(renders.list).toBe(before.list);

  act(() => session.notes.updateNoteContent("b", { title: "B2" }));
  expect(view.container.textContent).toBe("AB2");
  expect(renders.list).toBe(before.list);
  expect(lists.at(-1)).toBe(lists[0]);

  act(() => session.notes.reorder(["b", "a"]));
  expect(view.container.textContent).toBe("B2A");
  expect(lists.at(-1)).toEqual(["b", "a"]);
  await act(async () => {
    await vi.advanceTimersByTimeAsync(600);
  });
});
