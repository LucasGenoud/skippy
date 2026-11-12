"use client";

import { useEffect, useRef, useState } from "react";
import { ArrowLeft, Check, ChevronDown, MessageSquarePlus, MessagesSquare, Settings } from "lucide-react";
import { motion, useReducedMotion } from "motion/react";
import { IconButton } from "@/components/common/icon-button";
import { MenuLabel } from "@/components/common/menu-label";
import { Reveal } from "@/components/common/reveal";
import { showAppSnack } from "@/components/common/snack";
import { Button } from "@/components/ui/button";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { aiAllows, isWorkspaceOwnedBy } from "@/lib/models/workspace";
import { closeTo, navigate } from "@/lib/router";
import { useAiIn, useAuth, useNotesController, useSession, useSettings, useUi, useWorkspaces } from "@/lib/store/hooks";
import { useStoreSelector } from "@/lib/store/use-store";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";
import { chatAvailability, unavailableMessage, type ChatAvailability } from "./chat-availability";
import { ChatBubble } from "./chat-bubble";
import { ChatComposer } from "./chat-composer";
import { ChatConversation, conversationFor, type ConversationState } from "./chat-conversation";

// Ask questions about your notes (`screens/chat_screen.dart`). Each turn the
// server retrieves the relevant notes, hands them to the workspace owner's
// LLM and streams the answer; the notes it drew from show as chips that open
// them. A turn can also create or change a note, offered back with an Undo.
// The conversation lives in memory for the session.

const RISE_PX = 12;

const selectTurns = (s: ConversationState) => s.turns;
const selectScope = (s: ConversationState) => s.scopeId;

export function ChatScreen() {
  const session = useSession();
  const notes = useNotesController();
  const [conversation] = useState(() =>
    conversationFor(
      session,
      () =>
        new ChatConversation({
          api: session.api,
          reload: () => session.notes.load(),
          onUndoFailed: () => showAppSnack("Could not undo change", { kind: "danger" }),
        }),
    ),
  );
  const turns = useStoreSelector(conversation.store, selectTurns);
  const chosenScope = useStoreSelector(conversation.store, selectScope);
  const activeWorkspaceId = useUi((s) => s.activeWorkspaceId);
  const workspaces = useWorkspaces();
  const userId = useAuth((s) => s.user?.id ?? null);

  // Answer over the workspace being looked at unless another was picked here.
  const scopeId = chosenScope !== null && workspaces.some((w) => w.id === chosenScope) ? chosenScope : activeWorkspaceId;
  const scope = workspaces.find((w) => w.id === scopeId) ?? null;
  const ai = useAiIn(scopeId);
  const settingsLoaded = useSettings((s) => s.loaded);
  const semanticSearchCapable = useSettings((s) => s.semanticSearchCapable);
  const availability = chatAvailability({ settingsLoaded, semanticSearchCapable, ai });
  const role = scope && isWorkspaceOwnedBy(scope, userId) ? "owner" : "member";

  const [input, setInput] = useState("");
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const busy = turns.at(-1)?.status === "streaming";
  const blocked = availability !== "ready" && availability !== "unknown";
  const reduced = useReducedMotion();

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  const send = (): void => {
    // Keep the caret in the field whatever happens, so the next question can follow.
    inputRef.current?.focus();
    if (blocked) {
      return;
    }
    if (conversation.send(input, scopeId)) {
      setInput("");
    }
  };

  const startOver = (): void => {
    conversation.clear();
    inputRef.current?.focus();
  };

  return (
    <div className="flex h-dvh flex-col bg-canvas">
      <header className="flex h-14 shrink-0 items-center gap-1 border-b border-hairline bg-surface px-2 sm:px-3">
        <IconButton label="Back" icon={<ArrowLeft />} onClick={() => closeTo({ name: "home" })} />
        <div className="flex min-w-0 flex-1 items-center gap-1">
          <h1 className="truncate pl-1 text-base font-semibold text-on-surface">Chat with your notes</h1>
          {workspaces.length > 1 ? (
            <ScopePicker
              scopeId={scopeId}
              disabled={busy}
              onPick={(id) => conversation.setScope(id)}
              aiFor={(id) => aiAllows(notes.aiIn(id), "chat")}
            />
          ) : null}
        </div>
        <IconButton label="New conversation" icon={<MessageSquarePlus />} disabled={turns.length === 0} onClick={startOver} />
      </header>

      <div className="flex min-h-0 flex-1 flex-col-reverse overflow-y-auto">
        {/* column-reverse keeps the newest turn in view as answers grow. */}
        <div className="mx-auto w-full max-w-[720px] px-4 pt-4 pb-2">
          {turns.length === 0 ? (
            <motion.div
              key={blocked ? availability : "hint"}
              className="flex min-h-[50dvh] flex-col items-center justify-center text-center"
              initial={{ opacity: 0, y: RISE_PX }}
              animate={{ opacity: 1, y: 0 }}
              transition={transitionFor(TRANSITION.slow, reduced)}
            >
              <MessagesSquare aria-hidden className="size-12 text-on-surface-variant/40" strokeWidth={1.25} />
              {blocked ? (
                <Unavailable availability={availability} role={role} workspaceId={scopeId} />
              ) : (
                <p className="mt-4 max-w-sm text-sm text-on-surface-variant">
                  Ask about your notes; answers cite the notes they came from. You can also ask to create, edit, or organize them.
                </p>
              )}
            </motion.div>
          ) : (
            <div role="log" aria-live="polite" aria-label="Conversation">
              {turns.map((turn) => (
                <ChatBubble key={turn.id} turn={turn} onUndo={(id) => void conversation.undo(id)} />
              ))}
            </div>
          )}
        </div>
      </div>

      <div className="mx-auto w-full max-w-[720px] shrink-0 px-4 pt-1 pb-3">
        <Reveal>
          {blocked && turns.length > 0 ? (
            <p className="pb-2 text-xs text-on-surface-variant" role="status">
              {unavailableMessage(availability, role)}
            </p>
          ) : null}
        </Reveal>
        <ChatComposer
          value={input}
          onChange={setInput}
          onSend={send}
          onStop={() => conversation.stop()}
          busy={busy}
          disabled={blocked}
          inputRef={inputRef}
        />
      </div>
    </div>
  );
}

function Unavailable({ availability, role, workspaceId }: { availability: ChatAvailability; role: "owner" | "member"; workspaceId: string | null }) {
  const message = unavailableMessage(availability, role);
  const fix =
    role !== "owner"
      ? null
      : availability === "noProvider"
        ? { label: "Set up AI", go: () => navigate({ name: "settings", page: "ai" }) }
        : availability === "switchedOff" && workspaceId
          ? { label: "Workspace settings", go: () => navigate({ name: "workspaceSettings", workspaceId }) }
          : null;
  return (
    <>
      <p className="mt-4 max-w-sm text-sm text-on-surface-variant" role="status">
        {message}
      </p>
      {fix ? (
        <Button variant="outline" className="mt-4" onClick={fix.go}>
          <Settings />
          {fix.label}
        </Button>
      ) : null}
    </>
  );
}

/** Which workspace the chat answers over and files its writes in. */
function ScopePicker({ scopeId, disabled, onPick, aiFor }: { scopeId: string | null; disabled: boolean; onPick(id: string): void; aiFor(id: string): boolean }) {
  const workspaces = useWorkspaces();
  const current = workspaces.find((w) => w.id === scopeId);
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button variant="ghost" size="sm" disabled={disabled} className="min-w-0 font-normal text-on-surface-variant">
          <span className="truncate">in {current?.name ?? "this workspace"}</span>
          <ChevronDown aria-hidden className="size-3.5" />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start" className="w-64">
        <DropdownMenuLabel>Answer from</DropdownMenuLabel>
        {workspaces.map((w) => (
          <DropdownMenuItem key={w.id} onSelect={() => onPick(w.id)}>
            <Check aria-hidden className={w.id === scopeId ? "text-primary" : "invisible"} />
            <MenuLabel label={w.name} hint={aiFor(w.id) ? undefined : "Chat is off"} />
          </DropdownMenuItem>
        ))}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
