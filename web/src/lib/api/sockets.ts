import { isTerminalChatEvent, parseChatEvent, type ChatEvent } from "@/lib/models/misc";
import type { ChatStream, Unsubscribe } from "./client";

// The two WebSockets: the live-sync nudge (`/api/ws`) and one chat turn
// (`/api/chat`). Ported from `changeEvents` and `chat` in `api_client.dart`.

/** Opens a socket; tests substitute one they can drive. */
export type WebSocketFactory = (url: string) => WebSocket;

export const defaultWebSocketFactory: WebSocketFactory = (url) => new WebSocket(url);

/** Wait before the first reconnect. */
const LIVE_SYNC_RETRY_MS = 5_000;
/** Ceiling: an unreachable server is retried once a minute. */
const MAX_LIVE_SYNC_RETRY_MS = 60_000;
const MAX_BACKOFF_SHIFT = 16;

/** Wait before the [attempt]-th consecutive reconnect: 5s, 10s, 20s, 40s, 60s. */
export function liveSyncBackoff(attempt: number): number {
  const shift = Math.min(Math.max(attempt, 0), MAX_BACKOFF_SHIFT);
  return Math.min(LIVE_SYNC_RETRY_MS * 2 ** shift, MAX_LIVE_SYNC_RETRY_MS);
}

function closeQuietly(socket: WebSocket | null): void {
  try {
    socket?.close();
  } catch {
    // Teardown of a socket that never connected can throw; nothing cares.
  }
}

/**
 * A reconnecting change-event socket. The first frame sent is `{token}`; every
 * frame received calls [listener]. One reconnect timer at a time: a failed
 * connection signals more than once, and each must not schedule its own retry.
 */
export function connectChangeEvents(options: {
  url: () => string;
  token: () => string | null;
  listener: () => void;
  factory: WebSocketFactory;
}): Unsubscribe {
  let closed = false;
  let attempt = 0;
  let socket: WebSocket | null = null;
  let reconnect: ReturnType<typeof setTimeout> | null = null;

  const scheduleReconnect = (): void => {
    if (closed || reconnect !== null) {
      return;
    }
    const delay = liveSyncBackoff(attempt);
    attempt++;
    reconnect = setTimeout(() => {
      reconnect = null;
      connect();
    }, delay);
  };

  const connect = (): void => {
    const sessionToken = options.token();
    if (closed || sessionToken === null) {
      return;
    }
    let retried = false;
    let current: WebSocket | null = null;
    // The first failure signal for this attempt wins; the rest are noise.
    const retry = (): void => {
      if (retried) {
        return;
      }
      retried = true;
      closeQuietly(current);
      scheduleReconnect();
    };
    try {
      current = options.factory(options.url());
    } catch {
      retry();
      return;
    }
    socket = current;
    current.onopen = () => {
      if (closed || retried) {
        return;
      }
      attempt = 0;
      try {
        current?.send(JSON.stringify({ token: sessionToken }));
      } catch {
        retry();
      }
    };
    current.onmessage = () => {
      if (!closed) {
        options.listener();
      }
    };
    current.onerror = () => retry();
    current.onclose = () => retry();
  };

  connect();
  return () => {
    closed = true;
    if (reconnect !== null) {
      clearTimeout(reconnect);
      reconnect = null;
    }
    const s = socket;
    socket = null;
    if (s) {
      s.onclose = null;
      s.onerror = null;
      s.onmessage = null;
      closeQuietly(s);
    }
  };
}

/** A push-to-pull queue behind an async iterator. */
class EventQueue<T> {
  private readonly items: T[] = [];
  private waiting: ((result: IteratorResult<T>) => void) | null = null;
  private ended = false;

  push(item: T): void {
    if (this.ended) {
      return;
    }
    const waiter = this.waiting;
    if (waiter) {
      this.waiting = null;
      waiter({ value: item, done: false });
      return;
    }
    this.items.push(item);
  }

  end(): void {
    this.ended = true;
    const waiter = this.waiting;
    if (waiter && this.items.length === 0) {
      this.waiting = null;
      waiter({ value: undefined, done: true });
    }
  }

  next(): Promise<IteratorResult<T>> {
    const item = this.items.shift();
    if (item !== undefined) {
      return Promise.resolve({ value: item, done: false });
    }
    if (this.ended) {
      return Promise.resolve({ value: undefined, done: true });
    }
    return new Promise((resolve) => {
      this.waiting = resolve;
    });
  }
}

/** One chat turn: send the request after the handshake, emit frames until terminal. */
export function openChatStream(options: {
  url: string;
  token: string | null;
  request: (token: string) => Record<string, unknown>;
  factory: WebSocketFactory;
}): ChatStream {
  const queue = new EventQueue<ChatEvent>();
  let socket: WebSocket | null = null;
  let terminal = false;
  let started = false;

  const emit = (event: ChatEvent): void => {
    if (terminal) {
      return;
    }
    queue.push(event);
    if (isTerminalChatEvent(event)) {
      terminal = true;
      closeQuietly(socket);
      queue.end();
    }
  };

  const start = (): void => {
    if (started) {
      return;
    }
    started = true;
    const sessionToken = options.token;
    if (sessionToken === null) {
      emit({ type: "error", message: "sign in to use chat" });
      return;
    }
    try {
      socket = options.factory(options.url);
    } catch {
      emit({ type: "error", message: "could not reach the server" });
      return;
    }
    let opened = false;
    socket.onopen = () => {
      opened = true;
      if (terminal) {
        return;
      }
      try {
        socket?.send(JSON.stringify(options.request(sessionToken)));
      } catch {
        emit({ type: "error", message: "could not reach the server" });
      }
    };
    socket.onmessage = (frame: MessageEvent) => {
      try {
        const event = parseChatEvent(JSON.parse(String(frame.data)));
        if (event) {
          emit(event);
        }
      } catch {
        // Ignore malformed frames; the terminal frame settles the turn.
      }
    };
    const lost = (): void => {
      if (!terminal) {
        emit({ type: "error", message: opened ? "connection lost" : "could not reach the server" });
      }
    };
    socket.onerror = lost;
    socket.onclose = lost;
  };

  const cancel = (): void => {
    terminal = true;
    closeQuietly(socket);
    queue.end();
  };

  return {
    cancel,
    [Symbol.asyncIterator](): AsyncIterator<ChatEvent> {
      start();
      return {
        next: () => queue.next(),
        return: () => {
          cancel();
          return Promise.resolve({ value: undefined, done: true });
        },
      };
    },
  };
}
