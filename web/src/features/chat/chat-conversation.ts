import { createStore, type StoreApi } from "zustand/vanilla";
import type { Api, ChatStream } from "@/lib/api/client";
import type { ChatMessage, ChatSource } from "@/lib/models/misc";
import type { JsonObject } from "@/lib/util/json";

// One notes-chat conversation (`_ChatScreenState` in `screens/chat_screen.dart`),
// kept outside the screen so it survives opening a cited note and coming back.
// It lives in memory only, one per signed-in session, and is gone on sign-out.

export type TurnStatus = "streaming" | "done" | "error" | "stopped";

/** A note the turn created or changed, with the patch that would take it back. */
export interface TurnWrite {
  /** "create" | "append" | "update" */
  readonly action: string;
  readonly note: ChatSource;
  readonly undo: Readonly<Record<string, unknown>>;
  readonly undoState: "idle" | "undoing" | "undone";
}

export interface Turn {
  readonly id: number;
  readonly role: "user" | "assistant";
  readonly text: string;
  readonly sources: readonly ChatSource[];
  readonly status: TurnStatus;
  readonly error: string | null;
  readonly write: TurnWrite | null;
}

export interface ConversationState {
  readonly turns: readonly Turn[];
  /** The workspace the next turn answers over and files writes in; null = the open one. */
  readonly scopeId: string | null;
}

export interface ConversationDeps {
  readonly api: Pick<Api, "chat" | "patchNote">;
  /** Pull the notes again after the chat wrote one, so the grid and chips catch up. */
  reload(): Promise<void>;
  /** An undo was refused. */
  onUndoFailed(): void;
}

/** Deltas are painted at most this often, so a fast stream re-renders the markdown a few times a second rather than per token. */
const FLUSH_MS = 40;

const CONNECTION_LOST = "connection lost";

export class ChatConversation {
  readonly store: StoreApi<ConversationState>;
  private stream: ChatStream | null = null;
  private nextId = 1;
  private pendingText = "";
  private flushTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(private readonly deps: ConversationDeps) {
    this.store = createStore<ConversationState>(() => ({ turns: [], scopeId: null }));
  }

  get state(): ConversationState {
    return this.store.getState();
  }

  /** A reply is still arriving. */
  get busy(): boolean {
    return this.state.turns.at(-1)?.status === "streaming";
  }

  setScope(workspaceId: string | null): void {
    this.store.setState({ scopeId: workspaceId });
  }

  /**
   * Send [message] over [workspaceId]. False when there is nothing to send or
   * a reply is still streaming.
   */
  send(message: string, workspaceId: string | null): boolean {
    const text = message.trim();
    if (text === "" || this.busy) {
      return false;
    }
    // Every completed turn before this one; a failed or stopped half-answer
    // stays out so it does not poison the next turn.
    const history: ChatMessage[] = this.state.turns
      .filter((t) => t.status === "done" && t.text !== "")
      .map((t) => ({ role: t.role, content: t.text }));
    const user = this.turn("user", text, "done");
    const reply = this.turn("assistant", "", "streaming");
    this.store.setState({ turns: [...this.state.turns, user, reply] });

    const stream = this.deps.api.chat(text, history, { workspaceId });
    this.stream = stream;
    void this.consume(stream, reply.id);
    return true;
  }

  /** Stop the reply in flight, keeping what arrived. */
  stop(): void {
    const stream = this.stream;
    if (!stream || !this.busy) {
      return;
    }
    this.stream = null;
    stream.cancel();
    const last = this.state.turns.at(-1);
    if (last) {
      this.flush();
      this.update(last.id, { status: "stopped" });
    }
  }

  /** Start over: drop the conversation and cancel any reply in flight. */
  clear(): void {
    const stream = this.stream;
    this.stream = null;
    stream?.cancel();
    this.dropPending();
    this.store.setState({ turns: [] });
  }

  /** Put the note a turn wrote back the way it was. */
  async undo(turnId: number): Promise<void> {
    const write = this.state.turns.find((t) => t.id === turnId)?.write;
    if (!write || Object.keys(write.undo).length === 0 || write.undoState !== "idle") {
      return;
    }
    this.setUndo(turnId, "undoing");
    try {
      await this.deps.api.patchNote(write.note.id, write.undo as JsonObject);
      await this.deps.reload();
      this.setUndo(turnId, "undone");
    } catch {
      this.setUndo(turnId, "idle");
      this.deps.onUndoFailed();
    }
  }

  dispose(): void {
    this.clear();
  }

  // -- streaming ----------------------------------------------------------------

  private async consume(stream: ChatStream, id: number): Promise<void> {
    const current = (): boolean => this.stream === stream;
    try {
      for await (const event of stream) {
        if (!current()) {
          return;
        }
        switch (event.type) {
          case "sources":
            this.update(id, { sources: event.notes });
            break;
          case "created":
            this.update(id, { write: { action: event.action, note: event.note, undo: event.undo, undoState: "idle" } });
            void this.deps.reload().catch(() => undefined);
            break;
          case "delta":
            this.pendingText += event.text;
            this.scheduleFlush(id);
            break;
          case "done":
            this.finish(id, "done", null);
            return;
          case "error":
            this.finish(id, "error", event.message);
            return;
        }
      }
      // A stream that ends without its terminal frame must not leave the turn spinning.
      if (current()) {
        this.finish(id, "error", CONNECTION_LOST);
      }
    } catch {
      if (current()) {
        this.finish(id, "error", CONNECTION_LOST);
      }
    }
  }

  private finish(id: number, status: TurnStatus, error: string | null): void {
    this.stream = null;
    this.flush(id);
    this.update(id, { status, error });
  }

  private scheduleFlush(id: number): void {
    if (this.flushTimer !== null) {
      return;
    }
    this.flushTimer = setTimeout(() => this.flush(id), FLUSH_MS);
  }

  private flush(id?: number): void {
    if (this.flushTimer !== null) {
      clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }
    const target = id ?? this.state.turns.at(-1)?.id;
    if (this.pendingText === "" || target === undefined) {
      return;
    }
    const text = this.pendingText;
    this.pendingText = "";
    const turn = this.state.turns.find((t) => t.id === target);
    if (turn) {
      this.update(target, { text: turn.text + text });
    }
  }

  private dropPending(): void {
    if (this.flushTimer !== null) {
      clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }
    this.pendingText = "";
  }

  // -- state --------------------------------------------------------------------

  private turn(role: Turn["role"], text: string, status: TurnStatus): Turn {
    return { id: this.nextId++, role, text, sources: [], status, error: null, write: null };
  }

  private update(id: number, patch: Partial<Turn>): void {
    this.store.setState({ turns: this.state.turns.map((t) => (t.id === id ? { ...t, ...patch } : t)) });
  }

  private setUndo(id: number, undoState: TurnWrite["undoState"]): void {
    const turn = this.state.turns.find((t) => t.id === id);
    if (turn?.write) {
      this.update(id, { write: { ...turn.write, undoState } });
    }
  }
}

// One conversation per signed-in session, created on first use.
const conversations = new WeakMap<object, ChatConversation>();

export function conversationFor(session: object, create: () => ChatConversation): ChatConversation {
  let conversation = conversations.get(session);
  if (!conversation) {
    conversation = create();
    conversations.set(session, conversation);
  }
  return conversation;
}
