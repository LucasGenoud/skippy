import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { createRef } from "react";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { ChatStream } from "@/lib/api/client";
import type { ChatEvent } from "@/lib/models/misc";
import { DEFAULT_AI_SWITCHES, NO_WORKSPACE_AI } from "@/lib/models/workspace";
import { FakeApi } from "@/tests/fake-api";
import { chatAvailability, unavailableMessage } from "./chat-availability";
import { chipTitle } from "./chat-bubble";
import { ChatComposer, composerKey } from "./chat-composer";
import { ChatConversation } from "./chat-conversation";

beforeAll(() => {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: (query: string) => ({ matches: false, media: query, addEventListener() {}, removeEventListener() {} }),
  });
});

afterEach(cleanup);

/** Let the conversation's stream loop and delta flush run. */
const settle = () => vi.waitFor(() => undefined).then(() => new Promise((r) => setTimeout(r, 60)));

function conversationWith(api: FakeApi) {
  const reload = vi.fn(() => Promise.resolve());
  const onUndoFailed = vi.fn();
  return { conversation: new ChatConversation({ api, reload, onUndoFailed }), reload, onUndoFailed };
}

/** A stream that yields what the test pushes, until the test ends it. */
function manualStream(): { stream: ChatStream; push(e: ChatEvent): void; cancelled: () => boolean } {
  const queue: ChatEvent[] = [];
  let wake: (() => void) | null = null;
  let cancelled = false;
  return {
    stream: {
      cancel: () => {
        cancelled = true;
        wake?.();
      },
      async *[Symbol.asyncIterator]() {
        while (!cancelled) {
          const next = queue.shift();
          if (next) {
            yield next;
            if (next.type === "done" || next.type === "error") {
              return;
            }
            continue;
          }
          await new Promise<void>((r) => (wake = r));
        }
      },
    },
    push: (e) => {
      queue.push(e);
      wake?.();
    },
    cancelled: () => cancelled,
  };
}

describe("ChatConversation", () => {
  it("streams an answer and sends completed turns back as history", async () => {
    const api = new FakeApi();
    const { conversation } = conversationWith(api);
    expect(conversation.send("  hi  ", "w1")).toBe(true);
    expect(api.lastChatWorkspaceId).toBe("w1");
    expect(conversation.busy).toBe(true);
    await settle();
    expect(conversation.state.turns.map((t) => [t.role, t.text, t.status])).toEqual([
      ["user", "hi", "done"],
      ["assistant", "Hello there.", "done"],
    ]);

    conversation.send("again", null);
    expect(api.lastChatHistory).toEqual([
      { role: "user", content: "hi" },
      { role: "assistant", content: "Hello there." },
    ]);
  });

  it("ignores empty messages and sends nothing while a reply streams", () => {
    const api = new FakeApi();
    const manual = manualStream();
    vi.spyOn(api, "chat").mockReturnValue(manual.stream);
    const { conversation } = conversationWith(api);
    expect(conversation.send("   ", null)).toBe(false);
    expect(conversation.send("one", null)).toBe(true);
    expect(conversation.send("two", null)).toBe(false);
  });

  it("keeps a failed half-answer on screen but out of the history", async () => {
    const api = new FakeApi();
    api.chatScript = [{ type: "delta", text: "Partial" }, { type: "error", message: "model timeout" }];
    const { conversation } = conversationWith(api);
    conversation.send("q", null);
    await settle();
    expect(conversation.state.turns[1]).toMatchObject({ text: "Partial", status: "error", error: "model timeout" });

    api.chatScript = [{ type: "done" }];
    conversation.send("q2", null);
    expect(api.lastChatHistory).toEqual([{ role: "user", content: "q" }]);
  });

  it("stops a reply, keeping what arrived", async () => {
    const api = new FakeApi();
    const manual = manualStream();
    vi.spyOn(api, "chat").mockReturnValue(manual.stream);
    const { conversation } = conversationWith(api);
    conversation.send("q", null);
    manual.push({ type: "delta", text: "So far" });
    await settle();
    conversation.stop();
    expect(manual.cancelled()).toBe(true);
    expect(conversation.busy).toBe(false);
    expect(conversation.state.turns[1]).toMatchObject({ text: "So far", status: "stopped" });
  });

  it("reloads the notes after a write and undoes it", async () => {
    const api = new FakeApi();
    api.seedNote({ id: "n1", title: "Groceries" });
    api.chatScript = [
      { type: "created", action: "append", note: { id: "n1", title: "Groceries" }, undo: { items: [] } },
      { type: "delta", text: "Added." },
      { type: "done" },
    ];
    const { conversation, reload } = conversationWith(api);
    conversation.send("add milk", null);
    await settle();
    expect(reload).toHaveBeenCalledTimes(1);
    const turn = conversation.state.turns[1]!;
    expect(turn.write).toMatchObject({ action: "append", undoState: "idle" });

    await conversation.undo(turn.id);
    expect(api.log.some((op) => op.startsWith("patchNote:n1:items"))).toBe(true);
    expect(conversation.state.turns[1]?.write?.undoState).toBe("undone");
  });

  it("says so when an undo is refused, and allows another try", async () => {
    const api = new FakeApi();
    api.chatScript = [{ type: "created", action: "create", note: { id: "gone", title: "" }, undo: { trashed: true } }, { type: "done" }];
    const { conversation, onUndoFailed } = conversationWith(api);
    conversation.send("make a note", null);
    await settle();
    await conversation.undo(conversation.state.turns[1]!.id);
    expect(onUndoFailed).toHaveBeenCalled();
    expect(conversation.state.turns[1]?.write?.undoState).toBe("idle");
  });

  it("starts over, cancelling a reply in flight", () => {
    const api = new FakeApi();
    const manual = manualStream();
    vi.spyOn(api, "chat").mockReturnValue(manual.stream);
    const { conversation } = conversationWith(api);
    conversation.send("q", null);
    conversation.clear();
    expect(manual.cancelled()).toBe(true);
    expect(conversation.state.turns).toEqual([]);
  });
});

describe("composer keys", () => {
  it("sends on Enter, keeps Shift+Enter for a new line, stops on Escape while busy", () => {
    expect(composerKey({ key: "Enter", shiftKey: false, isComposing: false }, false)).toBe("send");
    expect(composerKey({ key: "Enter", shiftKey: true, isComposing: false }, false)).toBe("none");
    expect(composerKey({ key: "Enter", shiftKey: false, isComposing: true }, false)).toBe("none");
    expect(composerKey({ key: "Escape", shiftKey: false, isComposing: false }, true)).toBe("stop");
    expect(composerKey({ key: "Escape", shiftKey: false, isComposing: false }, false)).toBe("none");
  });

  it("wires the keys to the field and swaps send for stop while busy", () => {
    const onSend = vi.fn();
    const onStop = vi.fn();
    const props = { value: "hello", onChange: () => undefined, onSend, onStop, disabled: false, inputRef: createRef<HTMLTextAreaElement>() };
    const view = render(<ChatComposer {...props} busy={false} />);
    const field = screen.getByLabelText("Message");
    fireEvent.keyDown(field, { key: "Enter", shiftKey: true });
    expect(onSend).not.toHaveBeenCalled();
    fireEvent.keyDown(field, { key: "Enter" });
    expect(onSend).toHaveBeenCalledTimes(1);

    view.rerender(<ChatComposer {...props} busy />);
    expect((screen.getByLabelText("Message") as HTMLTextAreaElement).disabled).toBe(false);
    fireEvent.click(screen.getByRole("button", { name: "Stop" }));
    fireEvent.keyDown(field, { key: "Escape" });
    expect(onStop).toHaveBeenCalledTimes(2);
  });
});

describe("availability", () => {
  const ready = { ...NO_WORKSPACE_AI, providerReady: true };

  it("needs settings, server search, the chat switch and a provider, in that order", () => {
    expect(chatAvailability({ settingsLoaded: false, semanticSearchCapable: false, ai: NO_WORKSPACE_AI })).toBe("unknown");
    expect(chatAvailability({ settingsLoaded: true, semanticSearchCapable: false, ai: ready })).toBe("noSearch");
    const off = { ...ready, switches: { ...DEFAULT_AI_SWITCHES, enabled: false } };
    expect(chatAvailability({ settingsLoaded: true, semanticSearchCapable: true, ai: off })).toBe("switchedOff");
    expect(chatAvailability({ settingsLoaded: true, semanticSearchCapable: true, ai: NO_WORKSPACE_AI })).toBe("noProvider");
    expect(chatAvailability({ settingsLoaded: true, semanticSearchCapable: true, ai: ready })).toBe("ready");
  });

  it("tells an owner what to fix and a member who can", () => {
    expect(unavailableMessage("noProvider", "owner")).toContain("Connect an AI provider");
    expect(unavailableMessage("noProvider", "member")).toContain("owner");
    expect(unavailableMessage("ready", "owner")).toBeNull();
  });
});

describe("chip titles", () => {
  it("falls back to the note's first line, then Untitled", () => {
    expect(chipTitle(" Trip ", "body")).toBe("Trip");
    expect(chipTitle("", "\nFirst line\nsecond")).toBe("First line");
    expect(chipTitle("", "x".repeat(50))).toBe(`${"x".repeat(40)}…`);
    expect(chipTitle("", "")).toBe("Untitled");
  });
});
