import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "@/lib/api/errors";
import { makeWorkspace, noteToJson, type ChecklistItem, type Note } from "@/lib/models";
import { MemoryKeyValueStore, type KeyValueStore } from "@/lib/state/local-cache";
import { isConflictIssue, syncIssueCopyText } from "@/lib/state/sync-issue";
import type { JsonObject } from "@/lib/util/json";
import { FakeApi, Gate } from "@/tests/fake-api";
import { flushMicrotasks, settle, TEST_OFFLINE_GRACE_MS, testStore } from "@/tests/helpers";
import type { NotesStore } from "./notes-store";
import { displayNotesOf, sectionsOf } from "./selectors";
import type { UiController } from "./ui-store";

// Ported from `app/test/notes_store_test.dart`: optimistic state, eventual
// server calls, retry/drop, queue persistence and replay, refetch
// reconciliation, and create-before-update ordering.

const item = (id: string, text: string, extra: Partial<ChecklistItem> = {}): ChecklistItem => ({ id, text, done: false, depth: 0, ...extra });

async function cachedDoc(cache: KeyValueStore): Promise<JsonObject> {
  return (await cache.read("u-me")) ?? {};
}

function grid(store: NotesStore, ui: UiController, query = ""): Note[] {
  ui.store.setState({ query });
  const sections = sectionsOf(store.state, ui.state, "u-me", false);
  return [...sections.pinned, ...sections.others];
}

let api: FakeApi;
let store: NotesStore;
let ui: UiController;

beforeEach(() => {
  vi.useFakeTimers();
  api = new FakeApi();
  ({ store, ui } = testStore(api));
});

afterEach(() => {
  store.dispose();
  vi.useRealTimers();
});

describe("optimistic mutations", () => {
  it("applies a pattern at once, syncs it, and keeps it in the cache", async () => {
    const cache = new MemoryKeyValueStore();
    api.seedNote({ id: "n1", title: "a" });
    const { store: s } = testStore(api, { cache });
    await s.load();

    s.setPattern("n1", "grid");
    expect(s.noteById("n1")?.pattern).toBe("grid");
    await settle();
    expect(api.notes.get("n1")?.pattern).toBe("grid");
    expect(api.log).toContain("patchNote:n1:pattern");
    s.dispose();

    const { store: reopened } = testStore(api, { cache });
    await reopened.load();
    expect(reopened.noteById("n1")?.pattern).toBe("grid");
    reopened.dispose();
  });

  it("pinning an archived note unarchives it; archiving unpins", async () => {
    api.seedNote({ id: "n1", archived: true });
    api.seedNote({ id: "n2", pinned: true });
    await store.load();
    store.togglePin("n1");
    store.setArchived("n2", true);
    expect(store.noteById("n1")).toMatchObject({ pinned: true, archived: false });
    expect(store.noteById("n2")).toMatchObject({ pinned: false, archived: true });
    await settle();
    expect(api.notes.get("n1")).toMatchObject({ pinned: true, archived: false });
  });

  it("reorder renumbers positions like the server will", async () => {
    api.seedNote({ id: "a", position: 1 });
    api.seedNote({ id: "b", position: 2 });
    api.seedNote({ id: "c", position: 3 });
    await store.load();
    store.reorder(["c", "a", "b"]);
    expect(store.state.order).toEqual(["c", "a", "b"]);
    expect(store.noteById("c")?.position).toBe(1024);
    await settle();
    expect(api.log).toContain("reorder:c|a|b");
  });

  it("serializes a reminder to UTC and clears it with explicit nulls", async () => {
    api.seedNote({ id: "n1", title: "x" });
    await store.load();
    const at = new Date(2030, 0, 2, 9, 30);
    store.setReminder("n1", at, "weekly");
    await settle();
    expect(api.notes.get("n1")?.reminderAt?.getTime()).toBe(at.getTime());
    expect(api.notes.get("n1")?.reminderRepeat).toBe("weekly");
    store.setReminder("n1", null, "weekly");
    await settle();
    expect(api.log).toContain("patchNote:n1:reminder_at,reminder_repeat");
    expect(api.notes.get("n1")?.reminderAt).toBeNull();
    expect(api.notes.get("n1")?.reminderRepeat).toBeNull();
  });

  it("keeps unchanged notes' identity across a refetch", async () => {
    api.seedNote({ id: "a", title: "A" });
    api.seedNote({ id: "b", title: "B" });
    await store.load();
    const a = store.noteById("a");
    const b = store.noteById("b");
    const notesRecord = store.state.notes;
    await store.refresh();
    expect(store.noteById("a")).toBe(a);
    expect(store.state.notes).toBe(notesRecord);

    api.notes.set("b", { ...(api.notes.get("b") as Note), title: "B2" });
    await store.refresh();
    expect(store.noteById("a")).toBe(a);
    expect(store.noteById("b")).not.toBe(b);
    expect(store.noteById("b")?.title).toBe("B2");
  });
});

describe("drafts", () => {
  it("keeps an editing card still while content autosaves", async () => {
    api.seedNote({ id: "n1", title: "Before" });
    await store.load();
    store.beginEditing("n1");
    store.updateNoteContent("n1", { title: "After", pace: "typing" });
    await settle();
    expect(store.noteById("n1")?.title).toBe("After");
    expect(store.displayNoteById("n1")?.title).toBe("Before");
    expect(api.notes.get("n1")?.title).toBe("After");
    expect(displayNotesOf(store.state).map((n) => n.title)).toEqual(["Before"]);
    store.endEditing("n1");
    expect(displayNotesOf(store.state).map((n) => n.title)).toEqual(["After"]);

    const draft = store.createDraft();
    store.beginEditing(draft.id, "new");
    store.updateNoteContent(draft.id, { title: "New" });
    expect(grid(store, ui)).toHaveLength(1);
    store.finalizeNote(draft.id);
    store.endEditing(draft.id);
    expect(grid(store, ui)).toHaveLength(2);
  });

  it("creates a draft on the server only once it has content", async () => {
    await store.load();
    const draft = store.createDraft();
    expect(api.log.filter((l) => l.startsWith("createNote"))).toEqual([]);
    store.updateNoteContent(draft.id, { title: "Hello", content: "" });
    await settle();
    expect(api.notes.get(draft.id)?.title).toBe("Hello");
    store.updateNoteContent(draft.id, { title: "Hello", content: "World" });
    await settle();
    expect(api.notes.get(draft.id)?.content).toBe("World");
    expect(api.log.filter((l) => l.startsWith("createNote"))).toHaveLength(1);
  });

  it("discards an empty draft on finalize without any server call", async () => {
    await store.load();
    const draft = store.createDraft();
    expect(store.finalizeNote(draft.id)).toBe(true);
    expect(store.noteById(draft.id)).toBeNull();
    await settle();
    expect(api.log.filter((l) => l.startsWith("createNote") || l.startsWith("deleteNote"))).toEqual([]);
  });

  it("can retain an empty draft", async () => {
    await store.load();
    const draft = store.createDraft();
    expect(store.finalizeNote(draft.id, "keepEmpty")).toBe(false);
    await settle();
    expect(api.notes.has(draft.id)).toBe(true);
  });

  it("keeps a wordless draft with a reminder", async () => {
    await store.load();
    const at = new Date(Date.now() + 2 * 3600_000);
    const draft = store.createDraft();
    store.setReminder(draft.id, at);
    await settle();
    expect(api.notes.get(draft.id)?.reminderAt?.getTime()).toBe(at.getTime());
    expect(store.finalizeNote(draft.id)).toBe(false);
    expect(store.noteById(draft.id)).not.toBeNull();
  });

  it("does not discard an emptied note in a shared workspace", async () => {
    api.workspaces.set("shared", makeWorkspace({ id: "shared", name: "Team", owner: { id: "u-me", name: "me" }, members: [{ id: "u2", name: "Ada" }] }));
    api.seedNote({ id: "n1", title: "shared", workspaceId: "shared" });
    await store.load();
    store.updateNoteContent("n1", { title: "", content: "" });
    await settle();
    expect(store.finalizeNote("n1")).toBe(false);
    expect(api.log.filter((l) => l.startsWith("deleteNote"))).toEqual([]);
  });

  it("debounces rapid edits into one patch", async () => {
    api.seedNote({ id: "n1", title: "x" });
    await store.load();
    for (const t of ["a", "ab", "abc", "abcd"]) {
      store.updateNoteContent("n1", { title: t, content: "" });
    }
    await settle();
    expect(api.notes.get("n1")?.title).toBe("abcd");
    expect(api.log.filter((l) => l.startsWith("patchNote:n1"))).toHaveLength(1);
  });

  it("files a draft composed inside a label view through its create", async () => {
    api.labels.set("work", { id: "work", workspaceId: "w-default", name: "Work", color: null, icon: null, position: 1024 });
    await store.load();
    const draft = store.createDraft({ labelIds: ["work"] });
    store.updateNoteContent(draft.id, { title: "Filed" });
    await settle();
    expect(api.notes.get(draft.id)?.labelIds).toEqual(["work"]);
    expect(api.log.filter((l) => l.startsWith("patchNote"))).toEqual([]);
  });
});

describe("item reminders", () => {
  async function loadList(): Promise<void> {
    api.seedNote({ id: "n1", kind: "checklist", title: "Groceries", items: [item("milk", "Milk"), item("bread", "Bread")] });
    await store.load();
  }

  it("are optimistic and sync as their own operation", async () => {
    await loadList();
    const when = new Date(2030, 0, 2, 9, 30);
    store.setItemReminder("n1", "milk", when, "weekly");
    expect(store.noteById("n1")?.itemReminders.milk).toEqual({ itemId: "milk", at: when, repeat: "weekly" });
    // Not an edit: no updatedAt bump, no content patch.
    expect(store.noteById("n1")?.updatedAt.getTime()).toBe(api.notes.get("n1")?.updatedAt.getTime());
    await settle();
    expect(api.notes.get("n1")?.itemReminders.milk?.at.getTime()).toBe(when.getTime());
    expect(api.log).toContain("setItemReminder:n1:milk");
    expect(api.log.filter((l) => l.startsWith("patchNote"))).toEqual([]);

    store.setItemReminder("n1", "bread", new Date(2030, 1, 1));
    store.setItemReminder("n1", "milk", null);
    await settle();
    expect(Object.keys(api.notes.get("n1")?.itemReminders ?? {})).toEqual(["bread"]);
  });

  it("cannot be set on a checked or missing row", async () => {
    await loadList();
    store.setChecklistItemDone("n1", "milk", true);
    store.setItemReminder("n1", "milk", new Date(2030, 0, 1));
    store.setItemReminder("n1", "ghost", new Date(2030, 0, 1));
    await settle();
    expect(store.noteById("n1")?.itemReminders).toEqual({});
    expect(api.log.filter((l) => l.startsWith("setItemReminder"))).toEqual([]);
  });

  it("come back with their row when a check is undone (the edit is queued first)", async () => {
    await loadList();
    const when = new Date(2030, 0, 1, 9);
    store.setItemReminder("n1", "milk", when);
    await settle();
    store.setChecklistItemDone("n1", "milk", true);
    await settle();
    expect(api.notes.get("n1")?.itemReminders).toEqual({});
    store.setChecklistItemDone("n1", "milk", false);
    store.setItemReminder("n1", "milk", when);
    await settle();
    expect(store.state.syncIssues).toEqual([]);
    expect(api.notes.get("n1")?.itemReminders.milk?.at.getTime()).toBe(when.getTime());
  });

  it("are cancelled locally the moment their item is", async () => {
    await loadList();
    store.setItemReminder("n1", "milk", new Date(2030, 0, 1));
    store.setItemReminder("n1", "bread", new Date(2030, 0, 1));
    await settle();
    store.setChecklistItemDone("n1", "milk", true);
    expect(Object.keys(store.noteById("n1")?.itemReminders ?? {})).toEqual(["bread"]);
    await settle();
    expect(Object.keys(api.notes.get("n1")?.itemReminders ?? {})).toEqual(["bread"]);
  });

  it("make a wordless draft durable, riding along in its create", async () => {
    await store.load();
    const draft = store.createDraft({ kind: "checklist" });
    store.updateNoteContent(draft.id, { items: [item("milk", "")] });
    await settle();
    expect(api.notes.has(draft.id)).toBe(false);
    store.setItemReminder(draft.id, "milk", new Date(2030, 4, 1));
    await settle();
    expect(api.notes.get(draft.id)?.itemReminders.milk).toBeDefined();
    expect(api.log.filter((l) => l.startsWith("createNote"))).toHaveLength(1);
    expect(api.log.filter((l) => l.startsWith("setItemReminder"))).toEqual([]);
  });

  it("put their note in the Reminders view, ordered by the soonest", async () => {
    api.seedNote({ id: "later", title: "later", reminderAt: new Date(2030, 5, 1) });
    api.seedNote({
      id: "item-only",
      kind: "checklist",
      items: [item("milk", "Milk")],
      itemReminders: { milk: { itemId: "milk", at: new Date(2030, 0, 1), repeat: null } },
    });
    api.seedNote({ id: "plain", title: "plain" });
    await store.load();
    ui.store.setState({ destination: "reminders" });
    expect(grid(store, ui).map((n) => n.id)).toEqual(["item-only", "later"]);
    ui.store.setState({ destination: "notes" });
    expect(grid(store, ui, "has:reminder").map((n) => n.id).sort()).toEqual(["item-only", "later"]);
  });
});

describe("checklists", () => {
  it("setChecklistItemDone is idempotent and cascades to subtasks", async () => {
    api.seedNote({ id: "n1", kind: "checklist", items: [item("t", "Task"), item("s", "Sub", { depth: 1 }), item("o", "Other")] });
    await store.load();
    store.setChecklistItemDone("n1", "t", true);
    expect(store.noteById("n1")?.items.map((i) => i.done)).toEqual([true, true, false]);
    await settle();
    const patches = api.log.filter((l) => l.startsWith("patchNote")).length;
    store.setChecklistItemDone("n1", "t", true);
    await settle();
    expect(api.log.filter((l) => l.startsWith("patchNote")).length).toBe(patches);
  });

  it("feeds suggestions from checks, prefix first, never from other notes", async () => {
    api.history = { n1: ["Milk", "Almond milk", "Eggs", "Mint"], other: ["Milk paint"] };
    api.seedNote({ id: "n1", kind: "checklist", items: [item("i1", "Bread")] });
    await store.load();
    expect(store.suggestionsFor("n1", "mi")).toEqual(["Milk", "Mint", "Almond milk"]);
    expect(store.suggestionsFor("n1", "mi", ["milk"])).toEqual(["Mint", "Almond milk"]);
    expect(store.suggestionsFor("brand-new", "")).toEqual([]);
    store.toggleChecklistItem("n1", "i1");
    expect(store.suggestionsFor("n1", "br")).toEqual(["Bread"]);
  });

  it("normalizes depths on write", async () => {
    api.seedNote({ id: "n1", kind: "checklist", items: [item("a", "A")] });
    await store.load();
    store.updateNoteContent("n1", { items: [item("a", "A", { depth: 2 }), item("b", "B", { depth: 2 })] });
    expect(store.noteById("n1")?.items.map((i) => i.depth)).toEqual([0, 1]);
  });
});

describe("offline queue", () => {
  it("keeps local state on failure, goes offline after the grace, and replays in order", async () => {
    api.seedNote({ id: "n1", title: "a" });
    await store.load();
    api.failWith = new TypeError("Failed to fetch");
    store.setColor("n1", "teal");
    store.togglePin("n1");
    await settle();
    expect(store.state.offline).toBe(true);
    expect(store.noteById("n1")).toMatchObject({ color: "teal", pinned: true });
    expect(api.notes.get("n1")?.color).toBe("default");

    api.failWith = null;
    await store.retryNow();
    await settle();
    expect(store.state.offline).toBe(false);
    expect(api.notes.get("n1")).toMatchObject({ color: "teal", pinned: true });
  });

  it("drops 4xx responses as sync issues instead of wedging the queue", async () => {
    api.seedNote({ id: "n1", title: "a" });
    await store.load();
    api.notes.delete("n1");
    store.setColor("n1", "teal");
    store.createLabel("after");
    await settle();
    expect(store.state.offline).toBe(false);
    expect([...api.labels.values()].map((l) => l.name)).toContain("after");
    expect(store.state.syncIssues).toHaveLength(1);
    expect(store.state.syncStatus).toBe("failed");
  });

  for (const status of [401, 408, 425, 429]) {
    it(`retains a write refused with ${status} for a later retry`, async () => {
      const cache = new MemoryKeyValueStore();
      api.seedNote({ id: "n1", title: "a" });
      const { store: s } = testStore(api, { cache });
      await s.load();
      api.failWith = new ApiError(status, "retry later");
      s.setColor("n1", "teal");
      await vi.advanceTimersByTimeAsync(50);
      expect((await cachedDoc(cache)).queue).not.toEqual([]);
      expect(api.notes.get("n1")?.color).toBe("default");
      expect(s.state.offline).toBe(status === 408);

      api.failWith = null;
      await s.retryNow();
      await settle();
      expect(api.notes.get("n1")?.color).toBe("teal");
      expect((await cachedDoc(cache)).queue).toEqual([]);
      s.dispose();
    });
  }

  it("makes no server call for deleting a never-synced draft", async () => {
    await store.load();
    const draft = store.createDraft();
    store.deleteForever(draft.id);
    await settle();
    expect(api.log.filter((l) => l.includes(draft.id))).toEqual([]);
  });

  it("orders a create before the update that follows it", async () => {
    await store.load();
    const draft = store.createDraft();
    store.updateNoteContent(draft.id, { title: "First" });
    store.setColor(draft.id, "teal");
    store.togglePin(draft.id);
    await settle();
    const relevant = api.log.filter((l) => l.includes(draft.id));
    expect(relevant[0]).toBe(`createNote:${draft.id}`);
    expect(relevant.slice(1)).toEqual([`patchNote:${draft.id}:color`, `patchNote:${draft.id}:pinned`]);
    expect(api.notes.get(draft.id)).toMatchObject({ title: "First", color: "teal", pinned: true });
  });

  it("does not let a reconnect refetch overwrite a debounced checklist edit", async () => {
    api.seedNote({ id: "n1", kind: "checklist", items: [item("i1", "Milk")] });
    await store.load();
    api.failWith = new TypeError("Failed to fetch");
    await store.checkConnectionNow();
    await vi.advanceTimersByTimeAsync(TEST_OFFLINE_GRACE_MS * 3);
    expect(store.state.offline).toBe(true);

    api.failWith = null;
    store.updateNoteContent("n1", { items: [item("i1", "Milk and eggs")] });
    const gate = new Gate();
    api.fetchHistoryGate = gate;
    const reconnect = store.checkConnectionNow();
    await settle();
    expect(api.notes.get("n1")?.items[0]?.text).toBe("Milk and eggs");
    gate.open();
    api.fetchHistoryGate = null;
    await reconnect;
    await settle();
    expect(store.noteById("n1")?.items[0]?.text).toBe("Milk and eggs");
  });

  it("refresh cannot replace edits completed during its snapshot", async () => {
    api.seedNote({ id: "n1" });
    await store.load();
    const gate = new Gate();
    api.fetchHistoryGate = gate;
    const refresh = store.refresh();
    await flushMicrotasks();
    store.togglePin("n1");
    await settle();
    gate.open();
    api.fetchHistoryGate = null;
    await refresh;
    expect(store.noteById("n1")?.pinned).toBe(true);
  });

  it("an older overlapping load cannot replace a newer snapshot", async () => {
    api.seedNote({ id: "n1", title: "old" });
    const gate = new Gate();
    api.fetchLabelsGate = gate;
    const oldLoad = store.load();
    await flushMicrotasks();
    api.notes.set("n1", { ...(api.notes.get("n1") as Note), title: "new" });
    await store.load();
    expect(store.noteById("n1")?.title).toBe("new");
    gate.open();
    await oldLoad;
    expect(store.noteById("n1")?.title).toBe("new");
  });

  it("starts independent reads together", async () => {
    const gate = new Gate();
    api.fetchLabelsGate = gate;
    const loading = store.load();
    await flushMicrotasks();
    expect(api.log).toContain("fetchHistory");
    gate.open();
    await loading;
  });

  it("refuses an older offline edit over newer server content, as a conflict", async () => {
    api.seedNote({ id: "n1", title: "Original" });
    await store.load();
    const original = api.notes.get("n1") as Note;
    api.notes.set("n1", { ...original, title: "Other device", updatedAt: new Date(original.updatedAt.getTime() + 1000) });
    store.updateNoteContent("n1", { title: "My offline edit" });
    await settle();
    expect(api.notes.get("n1")?.title).toBe("Other device");
    const issue = store.state.syncIssues[0];
    expect(issue && isConflictIssue(issue)).toBe(true);
    expect(issue && syncIssueCopyText(issue)).toContain("My offline edit");
    store.updateNoteContent("n1", { title: "My later edit" });
    await settle();
    expect(store.state.syncIssues).toHaveLength(1);
    expect(syncIssueCopyText(store.state.syncIssues[0] as never)).toContain("My later edit");
  });

  it("retries a refused change once its cause is fixed", async () => {
    api.seedNote({ id: "n1", title: "Example" });
    await store.load();
    const seeded = api.notes.get("n1") as Note;
    api.notes.delete("n1");
    store.setColor("n1", "teal");
    await settle();
    expect(store.state.syncIssues).toHaveLength(1);
    api.notes.set("n1", seeded);
    store.retrySyncIssue(store.state.syncIssues[0] as never);
    await settle();
    expect(api.notes.get("n1")?.color).toBe("teal");
    expect(store.state.syncIssues).toEqual([]);
  });
});

describe("offline persistence", () => {
  it("writes edits to the local cache", async () => {
    const cache = new MemoryKeyValueStore();
    api.seedNote({ id: "n1", title: "a" });
    const { store: s } = testStore(api, { cache });
    await s.load();
    s.setColor("n1", "teal");
    await settle();
    const doc = await cachedDoc(cache);
    expect((doc.notes as JsonObject[])[0]?.color).toBe("teal");
    expect(doc.queue).toEqual([]);
    s.dispose();
  });

  it("opens from the cache when the server is unreachable, announcing the outage after the grace", async () => {
    const cache = new MemoryKeyValueStore();
    await cache.write("u-me", { notes: [noteToJson(api.seedNote({ id: "n1", title: "cached" }))], labels: [], history: {}, queue: [] });
    api.notes.clear();
    api.failWith = new TypeError("Failed to fetch");
    const { store: s } = testStore(api, { cache });
    await s.load();
    expect(s.noteById("n1")?.title).toBe("cached");
    expect(s.state.offline).toBe(false);
    expect(s.state.syncStatus).toBe("connecting");
    await vi.advanceTimersByTimeAsync(TEST_OFFLINE_GRACE_MS * 3);
    expect(s.state.offline).toBe(true);
    s.dispose();
  });

  it("syncs a note created offline on the next launch", async () => {
    const cache = new MemoryKeyValueStore();
    api.failWith = new TypeError("Failed to fetch");
    const { store: s1, ui: ui1 } = testStore(api, { cache });
    await s1.load();
    ui1.store.setState({ activeWorkspaceId: "w-default" });
    const draft = s1.createDraft();
    s1.updateNoteContent(draft.id, { title: "written offline" });
    await settle();
    expect(s1.state.offline).toBe(true);
    expect(api.notes.size).toBe(0);
    s1.dispose();

    api.failWith = null;
    const { store: s2 } = testStore(api, { cache });
    await s2.load();
    await settle();
    expect(api.notes.get(draft.id)?.title).toBe("written offline");
    s2.dispose();
  });

  it("replays persisted pending writes on the next launch", async () => {
    const cache = new MemoryKeyValueStore();
    const seeded = api.seedNote({ id: "n1", title: "a" });
    await cache.write("u-me", {
      notes: [noteToJson({ ...seeded, color: "teal" })],
      labels: [],
      history: {},
      queue: [{ kind: "patch", id: "n1", data: { color: "teal" } }],
    });
    const { store: s } = testStore(api, { cache });
    await s.load();
    await settle();
    expect(api.notes.get("n1")?.color).toBe("teal");
    expect((await cachedDoc(cache)).queue).toEqual([]);
    s.dispose();
  });

  it("keeps a rejected write visible and durable without wedging sync", async () => {
    const cache = new MemoryKeyValueStore();
    await cache.write("u-me", { notes: [], labels: [], history: {}, queue: [{ kind: "patch", id: "ghost", data: { color: "teal" } }] });
    const { store: s } = testStore(api, { cache });
    await s.load();
    await settle();
    expect(s.state.offline).toBe(false);
    expect(s.state.syncStatus).toBe("failed");
    const doc = await cachedDoc(cache);
    expect(doc.queue).toEqual([]);
    expect(doc.sync_issues).toHaveLength(1);
    s.dispose();

    const { store: reopened } = testStore(api, { cache });
    await reopened.load();
    expect(reopened.state.syncIssues).toHaveLength(1);
    reopened.dismissSyncIssue(reopened.state.syncIssues[0] as never);
    await settle();
    expect(reopened.state.syncStatus).toBe("synced");
    reopened.dispose();
  });

  it("captures a content edit still mid-debounce in the cache", async () => {
    const cache = new MemoryKeyValueStore();
    api.seedNote({ id: "n1", title: "a" });
    const { store: s } = testStore(api, { cache });
    await s.load();
    s.updateNoteContent("n1", { content: "typed, then reloaded" });
    s.setColor("n1", "teal");
    await vi.advanceTimersByTimeAsync(50);
    const queue = (await cachedDoc(cache)).queue as JsonObject[];
    const patch = queue.find((op) => op.kind === "patch" && op.id === "n1" && "content" in ((op.data as JsonObject) ?? {}));
    expect((patch?.data as JsonObject | undefined)?.content).toBe("typed, then reloaded");
    s.dispose();
  });

  it("flushForBackground pushes a mid-debounce edit at once", async () => {
    api.seedNote({ id: "n1", title: "a" });
    await store.load();
    store.updateNoteContent("n1", { content: "typed, then backgrounded" });
    store.flushForBackground();
    await vi.advanceTimersByTimeAsync(50);
    expect(api.notes.get("n1")?.content).toBe("typed, then backgrounded");
  });

  it("refuses an ambiguous legacy cache on a fresh login, claims it on a restored one", async () => {
    const cache = new MemoryKeyValueStore();
    await cache.write("u-me", { notes: [noteToJson(api.seedNote({ id: "legacy", title: "legacy" }))], queue: [{ kind: "patch", id: "legacy", data: { color: "teal" } }] });
    api.notes.clear();
    const { store: fresh } = testStore(api, { cache, cacheNamespace: "http://server.test" });
    await fresh.load();
    await settle();
    expect(fresh.noteById("legacy")).toBeNull();
    expect(api.log).not.toContain("patchNote:legacy:color");
    fresh.dispose();

    const otherCache = new MemoryKeyValueStore();
    await otherCache.write("u-me", { notes: [noteToJson({ ...api.seedNote({ id: "mine", title: "mine" }) })], queue: [] });
    const { store: restored } = testStore(api, { cache: otherCache, cacheNamespace: "http://server.test", migrateLegacyCache: true });
    await restored.load();
    expect(await otherCache.read("u-me")).toBeNull();
    expect(await otherCache.read("http%3A%2F%2Fserver.test::u-me")).not.toBeNull();
    restored.dispose();
  });

  it("persists navigation beside the snapshot and reopens there", async () => {
    const cache = new MemoryKeyValueStore();
    const { store: s, ui: u } = testStore(api, { cache });
    await s.load();
    const work = s.createWorkspace("Work");
    await settle();
    expect(u.state.activeWorkspaceId).toBe(work.id);
    s.dispose();

    const { store: s2, ui: u2 } = testStore(api, { cache });
    await s2.load();
    expect(u2.state.activeWorkspaceId).toBe(work.id);
    s2.dispose();
  });
});

describe("version history and sharing", () => {
  it("noteVersions flushes pending edits before reading history", async () => {
    api.seedNote({ id: "n1", title: "a" });
    await store.load();
    store.updateNoteContent("n1", { title: "typed" });
    const versions = store.noteVersions("n1");
    await settle();
    await versions;
    const patchAt = api.log.findIndex((l) => l.startsWith("patchNote:n1"));
    expect(patchAt).toBeGreaterThanOrEqual(0);
    expect(api.log.indexOf("fetchVersions:n1")).toBeGreaterThan(patchAt);
  });

  it("restore rolls content back and replaces the local copy", async () => {
    api.seedNote({ id: "n1", title: "now" });
    api.versions.set("n1", [{ id: "v1", noteId: "n1", kind: "text", title: "then", content: "", items: [], editedBy: null, createdAt: new Date() }]);
    await store.load();
    await store.restoreNoteVersion("n1", "v1");
    expect(store.noteById("n1")?.title).toBe("then");
  });

  it("addCollaborator surfaces a server rejection", async () => {
    api.seedNote({ id: "n1", title: "a" });
    await store.load();
    await expect(store.addCollaborator("n1", "nobody@example.test")).rejects.toBeInstanceOf(ApiError);
    await store.addCollaborator("n1", "friend@example.test");
    expect(store.noteById("n1")?.collaborators.map((c) => c.id)).toEqual(["u-friend@example.test"]);
  });
});

describe("stages", () => {
  async function loadBoard(): Promise<void> {
    api.stages.set("todo", { id: "todo", workspaceId: "w-default", collectionId: "w-default-general", name: "To do", color: null, position: 1024 });
    api.stages.set("done", { id: "done", workspaceId: "w-default", collectionId: "w-default-general", name: "Done", color: null, position: 2048 });
    api.labels.set("l1", { id: "l1", workspaceId: "w-default", name: "Work", color: null, icon: null, position: 1024 });
    api.seedNote({ id: "n1", title: "card", labelIds: ["l1"] });
    await store.load();
  }

  it("moves a card as one patch carrying stage_id and stage_position, labels untouched", async () => {
    await loadBoard();
    store.setNoteStage("n1", "todo");
    expect(store.noteById("n1")?.stageId).toBe("todo");
    await settle();
    expect(api.log).toContain("patchNote:n1:stage_id,stage_position");
    expect(api.notes.get("n1")).toMatchObject({ stageId: "todo", labelIds: ["l1"] });
  });

  it("queues nothing for a drop where the card already sits", async () => {
    await loadBoard();
    store.setNoteStage("n1", "todo", 512);
    await settle();
    const count = api.log.length;
    store.setNoteStage("n1", "todo", 512);
    store.setNoteStage("n1", "todo");
    await settle();
    expect(api.log.length).toBe(count);
  });

  it("deleting a stage keeps its notes, unassigned", async () => {
    await loadBoard();
    store.setNoteStage("n1", "todo");
    await settle();
    store.deleteStage("todo");
    expect(store.noteById("n1")?.stageId).toBeNull();
    await settle();
    expect(api.notes.get("n1")?.stageId).toBeNull();
  });

  it("appends created stages and reorders with one patch", async () => {
    await loadBoard();
    ui.store.setState({ activeWorkspaceId: "w-default" });
    const later = store.createStage("Later");
    expect(store.stages.map((s) => s.id)).toEqual(["todo", "done", later.id]);
    store.moveStage(later.id, 0);
    expect(store.stages.map((s) => s.id)).toEqual([later.id, "todo", "done"]);
    await settle();
    expect(api.log.filter((l) => l.startsWith(`updateStage:${later.id}`))).toHaveLength(1);
  });
});

describe("workspaces", () => {
  it("creates and switches to a workspace, and reopens each workspace's destination", async () => {
    await store.load();
    expect(ui.state.activeWorkspaceId).toBe("w-default");
    store.rememberWorkspaceView("archive");
    ui.store.setState({ destination: "archive" });
    const work = store.createWorkspace("Work");
    expect(ui.state.activeWorkspaceId).toBe(work.id);
    expect(ui.state.destination).toBe("notes");
    store.setActiveWorkspace("w-default");
    expect(ui.state.destination).toBe("archive");
    await settle();
    expect(api.workspaces.has(work.id)).toBe(true);
  });

  it("falls back to the default workspace when the open one disappears", async () => {
    api.workspaces.set("gone", makeWorkspace({ id: "gone", name: "Gone", owner: { id: "u-me", name: "me" } }));
    await store.load();
    store.setActiveWorkspace("gone");
    api.workspaces.delete("gone");
    await store.refresh();
    expect(ui.state.activeWorkspaceId).toBe("w-default");
  });

  it("keeps directly shared notes when leaving a workspace", async () => {
    api.workspaces.set("theirs", makeWorkspace({ id: "theirs", name: "Theirs", owner: { id: "u-other", name: "O" }, members: [{ id: "u-me", name: "me" }] }));
    api.seedNote({ id: "kept", workspaceId: "theirs", collaborators: [{ id: "u-me", name: "me" }], owner: { id: "u-other", name: "O" } });
    api.seedNote({ id: "gone", workspaceId: "theirs", owner: { id: "u-other", name: "O" } });
    await store.load();
    store.leaveWorkspace("theirs");
    expect(store.noteById("kept")).not.toBeNull();
    expect(store.noteById("gone")).toBeNull();
    await settle();
    expect(api.log).toContain("removeWorkspaceMember:theirs:u-me");
  });

  it("aiIn reports no AI for a workspace this user is not in", async () => {
    await store.load();
    expect(store.aiIn("elsewhere").providerReady).toBe(false);
  });
});

describe("live sync and starter notes", () => {
  it("reloads on a change event after the debounce", async () => {
    await store.load();
    store.startSync();
    api.seedNote({ id: "remote", title: "from elsewhere" });
    api.pushChangeEvent();
    await settle(400);
    expect(store.noteById("remote")?.title).toBe("from elsewhere");
  });

  it("gives a just-created account its three starter notes", async () => {
    const { store: s } = testStore(api, { accountOrigin: "justCreated" });
    await s.load();
    await settle();
    expect(s.state.order).toHaveLength(3);
    expect(s.noteById(s.state.order[0] as string)?.title).toBe("Welcome to Skippy");
    expect(api.notes.size).toBe(3);
    s.dispose();
  });
});
