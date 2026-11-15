import { describe, expect, it } from "vitest";
import {
  checklistItemToJson,
  isNoteEmpty,
  makeNote,
  noteCanAutoDiscard,
  noteKindFromWire,
  notePatternFromWire,
  noteServerStamp,
  noteToJson,
  parseChatEvent,
  parseChecklistItem,
  parseNote,
  parseSavedView,
  parseWorkspace,
  aiAllows,
} from "./index";

// Ported from `app/test/models_test.dart` plus the wire rules the stores rely on.

describe("Note wire format", () => {
  it("parses the full server shape", () => {
    const note = parseNote({
      id: "n1",
      workspace_id: "w",
      collection_id: "c",
      kind: "checklist",
      title: "T",
      items: [{ id: "i1", text: "Milk", done: true, depth: 7 }],
      color: "teal",
      pattern: "dots",
      pinned: true,
      position: 3,
      grid_span: 9,
      stage_id: "s",
      reminder_at: "2030-01-01T09:00:00Z",
      reminder_repeat: "weekly",
      item_reminders: [{ item_id: "i1", reminder_at: "2030-01-02T00:00:00Z", reminder_repeat: "daily" }, { item_id: "", reminder_at: "x" }],
      transcript_status: "pending",
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-02T00:00:00.123456Z",
      label_ids: ["a", "a", "b"],
      owner: { id: "u", username: "legacy" },
      collaborators: [{ id: "u2", name: "Ada" }],
      attachments: [{ id: "f", mime: "image/png", url: "/api/files/f?sig=1", ocr_text: "words" }],
    });
    expect(note).toMatchObject({ kind: "checklist", gridSpan: 3, stagePosition: 3, reminderRepeat: "weekly", transcriptStatus: "pending", labelIds: ["a", "b"] });
    expect(note.items[0]?.depth).toBe(2);
    expect(Object.keys(note.itemReminders)).toEqual(["i1"]);
    expect(note.owner?.name).toBe("legacy");
    expect(note.attachments[0]?.ocrText).toBe("words");
    // The exact stamp survives for conflict checks.
    expect(noteServerStamp(note)).toBe("2026-01-02T00:00:00.123456Z");
  });

  it("falls back like Dart for missing and unknown fields", () => {
    const note = parseNote({ id: "n" });
    expect(note).toMatchObject({ kind: "text", color: "default", pattern: "none", gridSpan: 1, stageId: null, reminderAt: null, transcriptStatus: "none" });
    expect(noteKindFromWire("drawing")).toBe("text");
    expect(notePatternFromWire("hexagons")).toBe("none");
  });

  it("omits depth at the top level and round-trips through the cache form", () => {
    expect(checklistItemToJson({ id: "a", text: "x", done: false, depth: 0 })).toEqual({ id: "a", text: "x", done: false });
    expect(checklistItemToJson({ id: "a", text: "x", done: false, depth: 1 })).toEqual({ id: "a", text: "x", done: false, depth: 1 });
    expect(parseChecklistItem({ id: "a", text: "x" }).depth).toBe(0);
    const note = makeNote({ id: "n", pattern: "dots", reminderAt: new Date(Date.UTC(2030, 0, 1)), stagePosition: 7 });
    const back = parseNote(noteToJson(note));
    expect(back).toMatchObject({ pattern: "dots", stagePosition: 7 });
    expect(back.reminderAt?.getTime()).toBe(note.reminderAt?.getTime());
  });

  it("distinguishes content from reminders and sharing for auto-discard", () => {
    expect(noteCanAutoDiscard(makeNote({ id: "n" }))).toBe(true);
    expect(noteCanAutoDiscard(makeNote({ id: "n", reminderAt: new Date() }))).toBe(false);
    expect(noteCanAutoDiscard(makeNote({ id: "n", collaborators: [{ id: "u", name: "u" }] }))).toBe(false);
    expect(isNoteEmpty(makeNote({ id: "n", items: [{ id: "i", text: " ", done: false, depth: 0 }] }))).toBe(true);
  });
});

describe("workspace wire format", () => {
  it("defaults a pre-collections workspace to one General collection and AI switches on", () => {
    const w = parseWorkspace({ id: "w", name: "W", notes_enabled: false, ai: { provider_ready: true, chat: false, rewrite_tasks: [{ id: "t", name: "Tidy" }, { id: 1 }] } });
    expect(w.collections).toEqual([expect.objectContaining({ id: "w-general", name: "General", layout: "board" })]);
    expect(w.ai.switches).toMatchObject({ enabled: true, chat: false, labeling: true, assistantAccess: true });
    expect(w.ai.rewriteTasks).toEqual([{ id: "t", name: "Tidy", prompt: "" }]);
    expect(aiAllows(w.ai, "chat")).toBe(false);
    expect(aiAllows(w.ai, "writing")).toBe(true);
  });

  it("drops smart views without an id, name or query", () => {
    expect(parseSavedView({ id: "v", name: " ", query: "x" })).toBeNull();
    expect(parseSavedView({ id: "v", name: "N", query: "is:pinned", icon: " " })).toMatchObject({ icon: null });
  });
});

it("ignores unknown chat frames", () => {
  expect(parseChatEvent({ type: "future" })).toBeNull();
  expect(parseChatEvent({ type: "created", note: { id: "n", title: "T" } })).toMatchObject({ action: "create" });
  expect(parseChatEvent({ type: "error" })).toEqual({ type: "error", message: "unknown error" });
});
