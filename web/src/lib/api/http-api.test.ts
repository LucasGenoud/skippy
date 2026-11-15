import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { makeNote, type ChatEvent } from "@/lib/models";
import { AbortedError, ApiError, NetworkError, errorMessage } from "./errors";
import { HttpApi } from "./http-api";
import { liveSyncBackoff } from "./sockets";

// The transport: auth headers, the 401 rule, error wording, timeouts, wire
// bodies, and the two sockets. Mirrors `failure_message_test.dart`,
// `live_sync_reconnect_test.dart` and `chat_test.dart` where they apply.

interface Call {
  url: string;
  init: RequestInit;
}

function respond(status: number, body: unknown = ""): Response {
  return new Response(typeof body === "string" ? body : JSON.stringify(body), { status });
}

function apiWith(handler: (call: Call) => Response | Promise<Response>): { api: HttpApi; calls: Call[] } {
  const calls: Call[] = [];
  const api = new HttpApi({
    baseUrl: "http://server.test",
    fetch: async (input, init) => {
      const call = { url: String(input), init: init ?? {} };
      calls.push(call);
      return handler(call);
    },
  });
  return { api, calls };
}

const headers = (call: Call | undefined): Record<string, string> => (call?.init.headers ?? {}) as Record<string, string>;

describe("ApiError wording", () => {
  it("shows the server's own message, else a status summary", () => {
    expect(new ApiError(400, '{"error":"title too long"}').serverMessage).toBe("title too long");
    expect(new ApiError(404, "").serverMessage).toContain("Check the server URL");
    expect(new ApiError(502, "<html>Bad gateway</html>").serverMessage).toContain("(502)");
    expect(new ApiError(500, '{"other":1}').serverMessage).toBe("The server ran into an error (500).");
    expect(new ApiError(418, "short and plain").serverMessage).toBe("short and plain");
    expect(errorMessage(new NetworkError(new TypeError("Failed to fetch"), "https://notes.example:8443"))).toContain("notes.example:8443");
  });
});

describe("requests", () => {
  it("sends the bearer token and decodes JSON", async () => {
    const { api, calls } = apiWith(() => respond(200, [{ id: "n1", title: "Hi", updated_at: "2026-01-01T00:00:00.123456Z" }]));
    api.token = "tok";
    const notes = await api.fetchNotes();
    expect(calls[0]?.url).toBe("http://server.test/api/notes");
    expect(headers(calls[0]).authorization).toBe("Bearer tok");
    expect(notes[0]?.title).toBe("Hi");
  });

  it("ends the session on a 401 only for the token and server in use", async () => {
    const { api } = apiWith(() => respond(401, ""));
    const onUnauthorized = vi.fn();
    api.onUnauthorized = onUnauthorized;
    api.token = "tok";
    await expect(api.fetchNotes()).rejects.toBeInstanceOf(ApiError);
    expect(onUnauthorized).toHaveBeenCalledTimes(1);
    await expect(api.logout()).rejects.toBeInstanceOf(ApiError);
    await expect(api.fetchCapabilities()).rejects.toBeInstanceOf(ApiError);
    expect(onUnauthorized).toHaveBeenCalledTimes(1);
  });

  it("sends the public share request without credentials", async () => {
    const { api, calls } = apiWith(() => respond(200, { target: "board", title: "B", notes: [] }));
    api.token = "tok";
    const share = await api.fetchPublicShare("abc");
    expect(headers(calls[0]).authorization).toBeUndefined();
    expect(share.target).toBe("board");
  });

  it("wraps a failed fetch in a plain-language NetworkError", async () => {
    const { api } = apiWith(() => {
      throw new TypeError("Failed to fetch");
    });
    await expect(api.fetchNotes()).rejects.toThrow("The browser couldn't reach server.test");
  });

  it("writes the create body with filing, timestamps only on request", async () => {
    const { api, calls } = apiWith(() => respond(200, { id: "n1" }));
    const note = makeNote({ id: "n1", workspaceId: "w", labelIds: ["l"], stageId: "s", stagePosition: 5, itemReminders: { i: { itemId: "i", at: new Date(Date.UTC(2030, 0, 1)), repeat: null } } });
    await api.createNote(note);
    const body = JSON.parse(String(calls[0]?.init.body)) as Record<string, unknown>;
    expect(body).toMatchObject({ id: "n1", workspace_id: "w", label_ids: ["l"], stage_id: "s", stage_position: 5 });
    expect(body.item_reminders).toEqual([{ item_id: "i", reminder_at: "2030-01-01T00:00:00.000Z", reminder_repeat: null }]);
    expect(body.created_at).toBeUndefined();
    await api.createNote(note, { preserveTimestamps: true });
    expect(JSON.parse(String(calls[1]?.init.body))).toHaveProperty("created_at");
  });

  it("clears an item reminder with explicit nulls", async () => {
    const { api, calls } = apiWith(() => respond(200, ""));
    await api.setItemReminder("n1", "a b", null, "weekly");
    expect(calls[0]?.url).toBe("http://server.test/api/notes/n1/item-reminders/a%20b");
    expect(JSON.parse(String(calls[0]?.init.body))).toEqual({ reminder_at: null, reminder_repeat: null });
  });

  it("omits empty label fields as empty strings and an absent position", async () => {
    const { api, calls } = apiWith(() => respond(200, ""));
    await api.createLabel("l1", "Work", { workspaceId: "w" });
    expect(JSON.parse(String(calls[0]?.init.body))).toEqual({ id: "l1", workspace_id: "w", name: "Work", color: "", icon: "" });
  });

  it("maps a refused unfurl to no preview", async () => {
    const { api } = apiWith(() => respond(400, '{"error":"blocked"}'));
    expect(await api.unfurl("http://10.0.0.1")).toBeNull();
  });

  describe("timeouts", () => {
    beforeEach(() => vi.useFakeTimers());
    afterEach(() => vi.useRealTimers());

    it("fails a hung request after 15 seconds, the probe after 3", async () => {
      const { api } = apiWith(
        (call) =>
          new Promise<Response>((_, reject) => {
            call.init.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
          }),
      );
      const probe = api.checkConnection().catch((e: unknown) => e);
      await vi.advanceTimersByTimeAsync(3_000);
      expect(await probe).toBeInstanceOf(NetworkError);
      const hung = api.fetchNotes().catch((e: unknown) => e);
      await vi.advanceTimersByTimeAsync(15_000);
      const error = await hung;
      expect(error).toBeInstanceOf(NetworkError);
      expect((error as Error).message).toContain("did not respond in time");
    });

    it("reports a caller abort as AbortedError", async () => {
      const { api } = apiWith(
        (call) =>
          new Promise<Response>((_, reject) => {
            call.init.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
          }),
      );
      const controller = new AbortController();
      const pending = api.summarizeUrl("https://x", { noteId: "n", signal: controller.signal }).catch((e: unknown) => e);
      controller.abort();
      expect(await pending).toBeInstanceOf(AbortedError);
    });
  });
});

/** A WebSocket a test drives by hand. */
class FakeSocket {
  static instances: FakeSocket[] = [];
  onopen: (() => void) | null = null;
  onmessage: ((e: { data: string }) => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  readonly sent: string[] = [];
  closed = false;
  constructor(readonly url: string) {
    FakeSocket.instances.push(this);
  }
  send(data: string): void {
    this.sent.push(data);
  }
  close(): void {
    this.closed = true;
  }
}

function socketApi(): HttpApi {
  FakeSocket.instances = [];
  const api = new HttpApi({ baseUrl: "https://server.test", webSocketFactory: (url) => new FakeSocket(url) as unknown as WebSocket });
  api.token = "tok";
  return api;
}

describe("live sync socket", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("backs off 5s, 10s, 20s, 40s, then once a minute", () => {
    expect([0, 1, 2, 3, 4, 10].map(liveSyncBackoff)).toEqual([5000, 10000, 20000, 40000, 60000, 60000]);
  });

  it("authenticates on open, nudges on frames, and reconnects once per failure", async () => {
    const api = socketApi();
    const listener = vi.fn();
    const stop = api.changeEvents(listener);
    const first = FakeSocket.instances[0];
    expect(first?.url).toBe("wss://server.test/api/ws");
    first?.onopen?.();
    expect(first?.sent).toEqual(['{"token":"tok"}']);
    first?.onmessage?.({ data: "{}" });
    expect(listener).toHaveBeenCalledTimes(1);

    // A failure signals twice; only one reconnect may follow.
    first?.onerror?.();
    first?.onclose?.();
    await vi.advanceTimersByTimeAsync(5_000);
    expect(FakeSocket.instances).toHaveLength(2);
    FakeSocket.instances[1]?.onclose?.();
    await vi.advanceTimersByTimeAsync(9_999);
    expect(FakeSocket.instances).toHaveLength(2);
    await vi.advanceTimersByTimeAsync(1);
    expect(FakeSocket.instances).toHaveLength(3);

    stop();
    FakeSocket.instances[2]?.onclose?.();
    await vi.advanceTimersByTimeAsync(120_000);
    expect(FakeSocket.instances).toHaveLength(3);
    expect(FakeSocket.instances[2]?.closed).toBe(true);
  });
});

describe("chat socket", () => {
  async function collect(stream: AsyncIterable<ChatEvent>): Promise<ChatEvent[]> {
    const out: ChatEvent[] = [];
    for await (const event of stream) {
      out.push(event);
    }
    return out;
  }

  it("sends the request after the handshake and ends on a terminal frame, skipping unknown ones", async () => {
    const api = socketApi();
    const stream = api.chat("hi", [{ role: "user", content: "before" }], { workspaceId: "w" });
    const events = collect(stream);
    const socket = FakeSocket.instances[0];
    expect(socket?.url).toBe("wss://server.test/api/chat");
    socket?.onopen?.();
    expect(JSON.parse(socket?.sent[0] ?? "{}")).toEqual({ token: "tok", message: "hi", history: [{ role: "user", content: "before" }], workspace_id: "w" });
    socket?.onmessage?.({ data: JSON.stringify({ type: "sources", notes: [{ id: "n1", title: "A" }] }) });
    socket?.onmessage?.({ data: JSON.stringify({ type: "future-frame" }) });
    socket?.onmessage?.({ data: "not json" });
    socket?.onmessage?.({ data: JSON.stringify({ type: "delta", text: "Hel" }) });
    socket?.onmessage?.({ data: JSON.stringify({ type: "done" }) });
    expect((await events).map((e) => e.type)).toEqual(["sources", "delta", "done"]);
    expect(socket?.closed).toBe(true);
  });

  it("reports a lost connection and an unreachable server", async () => {
    const api = socketApi();
    const lost = collect(api.chat("hi", []));
    FakeSocket.instances[0]?.onopen?.();
    FakeSocket.instances[0]?.onclose?.();
    expect(await lost).toEqual([{ type: "error", message: "connection lost" }]);
    const unreachable = collect(api.chat("hi", []));
    FakeSocket.instances[1]?.onerror?.();
    expect(await unreachable).toEqual([{ type: "error", message: "could not reach the server" }]);
    api.token = null;
    expect(await collect(api.chat("hi", []))).toEqual([{ type: "error", message: "sign in to use chat" }]);
  });
});
