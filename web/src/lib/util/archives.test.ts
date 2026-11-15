import JSZip from "jszip";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { makeNote, makeWorkspace, type Label, type Note } from "@/lib/models";
import { FakeApi } from "@/tests/fake-api";
import { testStore } from "@/tests/helpers";
import { BackupFormatError, backupFilename, createBackupArchive, parseBackupArchive } from "./backup";
import { ImportFormatError, parseKeepArchive } from "./keep-import";
import { exportFilename, exportNotes, noteToPlainText } from "./note-export";

// Ported from `backup_test.dart`, `keep_import_test.dart` and `note_export_test.dart`.

const created = new Date(Date.UTC(2020, 0, 2, 3, 4, 5));
const updated = new Date(Date.UTC(2021, 5, 7, 8, 9, 10));

async function zip(files: Record<string, unknown>): Promise<Uint8Array> {
  const z = new JSZip();
  for (const [path, value] of Object.entries(files)) {
    z.file(path, value instanceof Uint8Array ? value : typeof value === "string" ? value : JSON.stringify(value));
  }
  return z.generateAsync({ type: "uint8array" });
}

describe("backup", () => {
  it("round-trips owned workspace data and attachment bytes", async () => {
    const workspace = makeWorkspace({ id: "w-travel", name: "Travel", collections: [{ id: "reading", workspaceId: "w-travel", name: "Reading", icon: null, color: null, layout: "list", sort: "custom", position: 0 }] });
    const note = makeNote({
      id: "note-old",
      workspaceId: "w-travel",
      collectionId: "reading",
      kind: "checklist",
      title: "Packing",
      items: [
        { id: "item-old", text: "Passport", done: true, depth: 0 },
        { id: "item-visa", text: "Visa", done: false, depth: 0 },
      ],
      itemReminders: { "item-visa": { itemId: "item-visa", at: new Date(Date.UTC(2027, 2, 4)), repeat: "monthly" } },
      color: "teal",
      pinned: true,
      trashed: true,
      position: 42,
      stageId: "stage-old",
      stagePosition: 84,
      reminderAt: new Date(Date.UTC(2027, 0, 1)),
      createdAt: created,
      updatedAt: updated,
      labelIds: ["label-old"],
      attachments: [{ id: "a", mime: "application/pdf", filename: "../ticket.pdf", size: 3, url: null, ocrText: "" }],
    });
    const label: Label = { id: "label-old", workspaceId: "w-travel", name: "Trips", color: "#112233", icon: "travel", position: 3 };
    const bytes = await createBackupArchive({
      workspaces: [workspace],
      notes: [note],
      labels: [label],
      stages: [{ id: "stage-old", workspaceId: "w-travel", collectionId: "reading", name: "Packing", color: null, position: 1 }],
      readAttachment: async () => new Uint8Array([1, 2, 3]),
      now: created,
    });
    const bundle = await parseBackupArchive(bytes);
    const travel = bundle.workspaces[0];
    expect(travel?.name).toBe("Travel");
    expect(travel?.collections[0]?.layout).toBe("list");
    const restored = travel?.notes[0];
    expect(restored).toMatchObject({ title: "Packing", trashed: true, stageId: "stage-old", labelIds: ["label-old"], color: "teal" });
    expect(restored?.itemReminders[0]?.repeat).toBe("monthly");
    expect(restored?.attachments[0]?.filename).toBe("../ticket.pdf");
    expect([...(restored?.attachments[0]?.bytes ?? [])]).toEqual([1, 2, 3]);
    expect(restored?.createdAt.getTime()).toBe(created.getTime());
    expect(backupFilename(new Date(2026, 6, 22))).toBe("skippy-backup-2026-07-22.zip");
  });

  it("migrates a version 2 board-only workspace into General", async () => {
    const bytes = await zip({
      "backup.json": { format: "skippy-backup", version: 2, workspaces: [{ id: "old", name: "Old", is_default: true, notes_enabled: false, board_enabled: true, notes: [], labels: [], stages: [] }] },
    });
    const bundle = await parseBackupArchive(bytes);
    expect(bundle.workspaces[0]?.collections[0]).toMatchObject({ name: "General", layout: "board" });
  });

  it("reads a version 1 backup as one default workspace", async () => {
    const bytes = await zip({
      "backup.json": {
        format: "skippy-backup",
        version: 1,
        labels: [{ id: "l", name: "L" }],
        notes: [{ id: "n", kind: "text", title: "Hi", content: "", items: [], color: "default", created_at: created.toISOString(), updated_at: updated.toISOString(), label_ids: ["l", "missing"], attachments: [] }],
      },
    });
    const bundle = await parseBackupArchive(bytes);
    expect(bundle.workspaces[0]).toMatchObject({ id: "legacy-default", isDefault: true });
    expect(bundle.workspaces[0]?.notes[0]?.labelIds).toEqual(["l"]);
  });

  it("rejects unreadable and inconsistent archives", async () => {
    await expect(parseBackupArchive(new Uint8Array([1, 2, 3]))).rejects.toBeInstanceOf(BackupFormatError);
    await expect(parseBackupArchive(await zip({ "backup.json": { format: "other", version: 3 } }))).rejects.toBeInstanceOf(BackupFormatError);
    await expect(
      parseBackupArchive(await zip({ "backup.json": { format: "skippy-backup", version: 3, workspaces: [{ id: "a", name: "A", notes: [], labels: [], stages: [] }] }, "stray.txt": "x" })),
    ).rejects.toThrow("unreferenced");
  });

  // JSZip schedules its work on timers, so these run on real ones.
  describe("restore", () => {
    it("replaces owned workspaces and leaves invited ones alone", async () => {
      const api = new FakeApi();
      api.workspaces.set("w-old", makeWorkspace({ id: "w-old", name: "Old project", owner: { id: "u-me", name: "Me" } }));
      api.workspaces.set("w-invited", makeWorkspace({ id: "w-invited", name: "Shared", owner: { id: "u-other", name: "Other" } }));
      api.seedNote({ id: "old-default", title: "Delete me" });
      api.seedNote({ id: "old-project", workspaceId: "w-old", title: "Delete me too" });
      api.seedNote({ id: "invited", workspaceId: "w-invited", title: "Keep me", owner: { id: "u-other", name: "Other" } });
      const { store } = testStore(api);
      await store.load();
      const bytes = await createBackupArchive({
        workspaces: [makeWorkspace({ id: "w-default", name: "Home", isDefault: true, collections: [{ id: "c", workspaceId: "w-default", name: "General", icon: null, color: null, layout: "masonry", sort: "custom", position: 0 }] })],
        notes: [makeNote({ id: "44444444-4444-4444-8444-444444444444", workspaceId: "w-default", collectionId: "c", title: "Restored", createdAt: created, updatedAt: updated })],
        labels: [],
        stages: [],
        readAttachment: async () => new Uint8Array(),
      });
      const result = await store.restoreBackup(await parseBackupArchive(bytes));
      expect(result.notes).toBe(1);
      const titles = [...api.notes.values()].map((n: Note) => n.title).sort();
      expect(titles).toEqual(["Keep me", "Restored"]);
      expect(api.workspaces.has("w-old")).toBe(false);
      expect(api.workspaces.get("w-default")?.name).toBe("Home");
      store.dispose();
    });
  });
});

describe("Keep import", () => {
  const usec2024 = Date.UTC(2024, 0, 1) * 1000;
  const usec2025 = Date.UTC(2025, 0, 1) * 1000;

  it("reads text notes, checklists, labels and flags", async () => {
    const archive = await parseKeepArchive(
      await zip({
        "Takeout/Keep/Shopping.json": {
          title: "Shopping",
          color: "TEAL",
          isPinned: true,
          isArchived: false,
          isTrashed: false,
          listContent: [
            { text: "Milk", isChecked: true },
            { text: "Eggs", isChecked: false },
          ],
          labels: [{ name: "Home" }],
          createdTimestampUsec: usec2024,
          userEditedTimestampUsec: usec2025,
        },
        "Takeout/Keep/Idea.json": {
          title: "",
          color: "PURPLE",
          isArchived: true,
          isTrashed: false,
          textContent: "Build a boat",
          annotations: [{ source: "WEBLINK", url: "https://boats.example" }],
          userEditedTimestampUsec: usec2024,
        },
        "Takeout/Keep/Shopping.html": "<html></html>",
      }),
    );
    const shopping = archive.notes.find((n) => n.title === "Shopping");
    const idea = archive.notes.find((n) => n.title === "");
    expect(shopping).toMatchObject({ kind: "checklist", color: "teal", pinned: true, labels: ["Home"] });
    expect(shopping?.items.map((i) => [i.text, i.done])).toEqual([
      ["Milk", true],
      ["Eggs", false],
    ]);
    expect(shopping?.createdAt.getTime()).toBe(Date.UTC(2024, 0, 1));
    expect(idea).toMatchObject({ kind: "text", content: "Build a boat\n\nhttps://boats.example", color: "blue", archived: true });
  });

  it("attaches files, tolerating the extension Keep gets wrong", async () => {
    const archive = await parseKeepArchive(
      await zip({
        "Takeout/Keep/Photo.json": {
          title: "Photo",
          textContent: "",
          isTrashed: false,
          attachments: [
            { filePath: "abc.jpeg", mimetype: "image/jpeg" },
            { filePath: "gone.png", mimetype: "image/png" },
          ],
        },
        "Takeout/Keep/abc.jpg": new Uint8Array([1, 2, 3]),
      }),
    );
    const attachment = archive.notes[0]?.attachments[0];
    expect(attachment?.filename).toBe("abc.jpg");
    expect([...(attachment?.bytes ?? [])]).toEqual([1, 2, 3]);
    expect(archive.missingFiles).toBe(1);
  });

  it("rejects an archive with no Keep notes", async () => {
    await expect(parseKeepArchive(await zip({ "Takeout/Drive/a.json": "{}" }))).rejects.toBeInstanceOf(ImportFormatError);
    await expect(parseKeepArchive(new Uint8Array([1, 2, 3]))).rejects.toBeInstanceOf(ImportFormatError);
  });

  describe("importKeep", () => {
    beforeEach(() => vi.useFakeTimers());
    afterEach(() => vi.useRealTimers());

    it("adds notes beside existing ones, sharing labels by name, newest in front", async () => {
      const api = new FakeApi();
      api.labels.set("home", { id: "home", workspaceId: "w-default", name: "Home", color: null, icon: null, position: 1 });
      const { store } = testStore(api);
      await store.load();
      const base = { kind: "text" as const, content: "body", items: [], color: "default", pinned: false, archived: false, attachments: [] };
      const result = await store.importKeep(
        {
          notes: [
            { ...base, title: "Old", trashed: false, labels: ["home"], createdAt: new Date(Date.UTC(2023, 0)), updatedAt: new Date(Date.UTC(2023, 0)) },
            { ...base, title: "New", trashed: false, labels: ["Errands"], createdAt: new Date(Date.UTC(2024, 0)), updatedAt: new Date(Date.UTC(2024, 0)) },
            { ...base, title: "Binned", trashed: true, labels: [], createdAt: new Date(Date.UTC(2024, 0)), updatedAt: new Date(Date.UTC(2024, 0)) },
          ],
          missingFiles: 0,
        },
        { workspaceId: "w-default", collectionId: "w-default-general" },
      );
      expect(result).toEqual({ notes: 2, attachments: 0, labels: 1 });
      const imported = [...api.notes.values()].sort((a, b) => a.position - b.position);
      expect(imported.map((n) => n.title)).toEqual(["New", "Old"]);
      expect(imported[1]?.labelIds).toEqual(["home"]);
      store.dispose();
    });
  });
});

describe("export", () => {
  const notes = [
    makeNote({ id: "a", title: "Groceries", kind: "checklist", items: [{ id: "1", text: "Milk", done: true, depth: 0 }, { id: "2", text: "Oat", done: false, depth: 1 }], labelIds: ["l"], createdAt: created, updatedAt: updated }),
    makeNote({ id: "b", title: "Idea", content: "see [[11111111-1111-4111-8111-111111111111|Groceries]]", createdAt: created, updatedAt: updated }),
  ];
  const labels: Label[] = [{ id: "l", workspaceId: "", name: "Home", color: null, icon: null, position: 0 }];

  it("names the file by date and format", () => {
    expect(exportFilename("markdown", new Date(2026, 6, 13))).toBe("skippy-2026-07-13.md");
  });

  it("renders JSON, Markdown and plain text", () => {
    const json = JSON.parse(exportNotes(notes, "json", { labels, now: created })) as { notes: { labels: string[]; items: unknown[] }[] };
    expect(json.notes[0]?.labels).toEqual(["Home"]);
    expect(json.notes[0]?.items).toEqual([
      { text: "Milk", done: true },
      { text: "Oat", done: false },
    ]);
    const md = exportNotes(notes, "markdown", { labels, now: created });
    expect(md).toContain("## Groceries\n\n- [x] Milk\n  - [ ] Oat\n");
    expect(md).toContain("`Home`");
    expect(md).toContain("see Groceries");
    expect(noteToPlainText(notes[0] as Note)).toBe("Groceries\n\n[x] Milk\n  [ ] Oat\n\n");
    expect(exportNotes([], "text")).toBe("\n");
  });
});
