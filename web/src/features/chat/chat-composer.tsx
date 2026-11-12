"use client";

import { useLayoutEffect, useRef, type KeyboardEvent, type RefObject } from "react";
import { ArrowUp, Square } from "lucide-react";
import { CrossFade } from "@/components/common/reveal";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";

// The message field and its send / stop button. Enter sends, Shift+Enter adds
// a line, Escape stops a streaming reply. The field is never disabled while a
// reply streams, so the follow-up can be typed meanwhile; only sending waits.

/** Four lines of 20px plus the field's padding. */
const MAX_HEIGHT_PX = 4 * 20 + 18;

export type ComposerKey = "send" | "stop" | "none";

/** What a key press in the composer does. Pure, for the tests. */
export function composerKey(event: { key: string; shiftKey: boolean; isComposing: boolean }, busy: boolean): ComposerKey {
  if (event.isComposing) {
    return "none";
  }
  if (event.key === "Enter" && !event.shiftKey) {
    return "send";
  }
  if (event.key === "Escape" && busy) {
    return "stop";
  }
  return "none";
}

export function ChatComposer({
  value,
  onChange,
  onSend,
  onStop,
  busy,
  disabled,
  inputRef,
}: {
  value: string;
  onChange(value: string): void;
  onSend(): void;
  onStop(): void;
  busy: boolean;
  /** Chat cannot run here at all. */
  disabled: boolean;
  inputRef: RefObject<HTMLTextAreaElement | null>;
}) {
  const fallbackSizing = useRef(false);

  // Browsers without `field-sizing: content` grow the field by hand.
  useLayoutEffect(() => {
    fallbackSizing.current = typeof CSS !== "undefined" && typeof CSS.supports === "function" && !CSS.supports("field-sizing", "content");
  }, []);
  useLayoutEffect(() => {
    const field = inputRef.current;
    if (!field || !fallbackSizing.current) {
      return;
    }
    field.style.height = "auto";
    field.style.height = `${Math.min(field.scrollHeight, MAX_HEIGHT_PX)}px`;
  }, [value, inputRef]);

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>): void => {
    const action = composerKey({ key: event.key, shiftKey: event.shiftKey, isComposing: event.nativeEvent.isComposing }, busy);
    if (action === "none") {
      return;
    }
    event.preventDefault();
    if (action === "send") {
      onSend();
    } else {
      onStop();
    }
  };

  const canSend = !disabled && !busy && value.trim() !== "";
  return (
    <div className="flex items-end gap-2">
      <Textarea
        ref={inputRef}
        rows={1}
        value={value}
        disabled={disabled}
        aria-label="Message"
        placeholder="Ask about your notes…"
        autoCapitalize="sentences"
        className="max-h-[98px] min-h-10 resize-none overflow-y-auto bg-surface-container-low py-2.5 leading-5"
        onChange={(e) => onChange(e.target.value)}
        onKeyDown={onKeyDown}
      />
      <Tooltip>
        <TooltipTrigger asChild>
          <Button
            type="button"
            size="icon-lg"
            variant={busy ? "outline" : "default"}
            aria-label={busy ? "Stop" : "Send"}
            disabled={busy ? false : !canSend}
            className={busy ? undefined : "text-on-primary-container"}
            onClick={busy ? onStop : onSend}
          >
            <CrossFade stateKey={busy}>{busy ? <Square className="size-4 fill-current" /> : <ArrowUp className="size-5" />}</CrossFade>
          </Button>
        </TooltipTrigger>
        <TooltipContent side="top">{busy ? "Stop (Esc)" : "Send (Enter)"}</TooltipContent>
      </Tooltip>
    </div>
  );
}
