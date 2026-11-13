"use client";

import { memo, type ReactElement } from "react";
import { Check, FilePen, FilePlus2, LoaderCircle, StickyNote, Undo2 } from "lucide-react";
import { motion, useReducedMotion } from "motion/react";
import { cn } from "cn";
import { CrossFade, Reveal } from "@/components/common/reveal";
import { Button } from "@/components/ui/button";
import type { ChatSource } from "@/lib/models/misc";
import { navigate } from "@/lib/router";
import { plainNoteLinks } from "@/lib/state/note-links";
import { useNote } from "@/lib/store/hooks";
import { EASE, TRANSITION, transitionFor } from "@/lib/theme/motion";
import { NoteMarkdown } from "@/features/notes/note-markdown";
import type { Turn } from "./chat-conversation";

// One turn of the conversation (`_Bubble`): a question, or an answer with the
// notes it drew from above it and, when it wrote one, the note it changed
// below it with an Undo.

const RISE_PX = 10;
const CHIP_TITLE_MAX = 40;
/** One pulse of the typing dots, as in the Flutter client. A loop, not a transition. */
const TYPING_CYCLE_S = 0.9;
const DOTS = 3;

const openNote = (noteId: string): void => navigate({ name: "note", noteId });

export const ChatBubble = memo(function ChatBubble({ turn, onUndo }: { turn: Turn; onUndo(turnId: number): void }) {
  const reduced = useReducedMotion();
  const isUser = turn.role === "user";
  // Failed before any text: the error is the bubble. Otherwise the partial answer stays.
  const failedEmpty = turn.status === "error" && turn.text === "";

  return (
    <motion.div
      className={cn("flex flex-col py-1.5", isUser ? "items-end" : "items-start")}
      initial={{ opacity: 0, y: RISE_PX }}
      animate={{ opacity: 1, y: 0 }}
      transition={transitionFor(TRANSITION.base, reduced)}
    >
      <Reveal>
        {turn.sources.length > 0 ? (
          <div className="flex flex-wrap gap-1.5 pb-1.5" aria-label="Sources">
            {turn.sources.map((source) => (
              <NoteChip key={source.id} source={source} icon={<StickyNote />} />
            ))}
          </div>
        ) : null}
      </Reveal>

      <div
        className={cn(
          "max-w-[min(560px,100%)] rounded-md px-3.5 py-2.5 text-sm break-words",
          isUser
            ? "bg-primary-container whitespace-pre-wrap text-on-primary-container"
            : failedEmpty
              ? "bg-error-container text-on-error-container"
              : "bg-surface-container-highest text-on-surface",
        )}
      >
        {failedEmpty ? (
          <span role="alert">{turn.error}</span>
        ) : turn.text === "" && turn.status === "streaming" ? (
          <TypingDots />
        ) : isUser ? (
          turn.text
        ) : (
          <NoteMarkdown source={turn.text} variant="editor" />
        )}
        <Reveal>{turn.status === "error" && turn.text !== "" ? <p className="pt-1.5 text-xs text-error">Interrupted: {turn.error}</p> : null}</Reveal>
        <Reveal>{turn.status === "stopped" ? <p className="pt-1.5 text-xs text-on-surface-variant">Stopped</p> : null}</Reveal>
      </div>

      <Reveal>
        {turn.write ? (
          <div className="flex flex-wrap items-center gap-1.5 pt-2">
            <NoteChip
              source={turn.write.note}
              icon={turn.write.action === "create" ? <FilePlus2 /> : <FilePen />}
              prefix={turn.write.action === "create" ? "Created" : "Updated"}
            />
            {Object.keys(turn.write.undo).length > 0 ? (
              <Button variant="ghost" size="xs" disabled={turn.write.undoState !== "idle"} onClick={() => onUndo(turn.id)}>
                <CrossFade stateKey={turn.write.undoState}>
                  <span className="inline-flex items-center gap-1">
                    {turn.write.undoState === "undoing" ? (
                      <LoaderCircle className="animate-spin" />
                    ) : turn.write.undoState === "undone" ? (
                      <Check />
                    ) : (
                      <Undo2 />
                    )}
                    {turn.write.undoState === "undone" ? "Undone" : "Undo"}
                  </span>
                </CrossFade>
              </Button>
            ) : null}
          </div>
        ) : null}
      </Reveal>
    </motion.div>
  );
});

/** A cited or written note; subscribes to that one note for a fallback title. */
function NoteChip({ source, icon, prefix }: { source: ChatSource; icon: ReactElement; prefix?: string }) {
  const note = useNote(source.id);
  const title = chipTitle(source.title, note?.content ?? "");
  return (
    <Button variant="outline" size="xs" className="max-w-full" onClick={() => openNote(source.id)}>
      {icon}
      <span className="truncate">{prefix ? `${prefix}: ${title}` : title}</span>
    </Button>
  );
}

/** The source's title, else the first line of the note as this device holds it, else "Untitled". */
export function chipTitle(title: string, content: string): string {
  if (title.trim() !== "") {
    return title.trim();
  }
  const line = plainNoteLinks(content).trim().split("\n")[0] ?? "";
  if (line === "") {
    return "Untitled";
  }
  return line.length > CHIP_TITLE_MAX ? `${line.slice(0, CHIP_TITLE_MAX)}…` : line;
}

/** Three softly pulsing dots while the first words are on their way. */
function TypingDots() {
  const reduced = useReducedMotion();
  return (
    <span className="flex h-5 items-center gap-1" role="status" aria-label="Thinking">
      {Array.from({ length: DOTS }, (_, i) =>
        reduced ? (
          <span key={i} className="size-1.5 rounded-full bg-on-surface-variant/60" />
        ) : (
          <motion.span
            key={i}
            className="size-1.5 rounded-full bg-on-surface-variant"
            animate={{ opacity: [0.25, 1, 0.25] }}
            transition={{ duration: TYPING_CYCLE_S, ease: [...EASE.standard], repeat: Infinity, delay: (i * TYPING_CYCLE_S) / DOTS }}
          />
        ),
      )}
    </span>
  );
}
