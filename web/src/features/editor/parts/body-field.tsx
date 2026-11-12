"use client";

import { forwardRef, useEffect, useImperativeHandle, useMemo, useRef, useState, type KeyboardEvent } from "react";
import { cn } from "cn";

import { openLinkQuery, snapOutOfLinks, widenLinkDeletion } from "@/lib/state/note-links";
import { bodySegments, findMatches, type BodyStyle } from "../lib/body-segments";

// The note body (`HighlightedTextField`): a plain textarea whose text is
// transparent over a mirror that paints the same characters with links,
// markdown structure and find-in-note hits. The textarea stays the only thing
// the keyboard talks to, so IME, autocorrect and selection are the browser's.
// Its value is never written from inside its own input handler, except to
// widen a deletion that clipped a note link (the link goes as one unit).

const STYLE_CLASS: Record<BodyStyle, string> = {
  url: "text-primary underline decoration-primary/50",
  linkSyntax: "text-on-surface-variant/35",
  linkTitle: "text-primary underline decoration-dotted decoration-primary/60",
  marker: "text-primary/80 font-semibold",
  bold: "font-bold",
  italic: "italic",
  strike: "line-through",
  code: "rounded-xs bg-code-fill",
  heading: "font-bold",
  mdLinkLabel: "text-primary underline decoration-primary/50",
  mdLinkUrl: "text-on-surface-variant",
  match: "rounded-xs bg-primary-container/45",
  current: "rounded-xs bg-primary-container text-on-primary-container",
};

/** Styles that change a glyph's advance, allowed only on the monospace source. */
const WIDTH_STYLES: ReadonlySet<BodyStyle> = new Set(["marker", "bold", "italic", "heading"]);

export interface BodyFieldHandle {
  getText(): string;
  /** Replace the text without reporting it as typed (undo, sync, conversions). */
  setText(text: string, caret?: number | "end"): void;
  /** Replace a range as an edit the user made, and report it. */
  replaceRange(start: number, end: number, insert: string, selection?: { start: number; end: number }): void;
  selection(): { start: number; end: number };
  focus(caret?: "end"): void;
  element(): HTMLTextAreaElement | null;
}

export interface BodyFieldProps {
  initialText: string;
  markdown: boolean;
  readOnly: boolean;
  placeholder?: string;
  findQuery?: string;
  currentMatch?: number;
  onTextChange(text: string): void;
  /** What follows a `[[` being typed, or null. */
  onLinkQuery?(query: string | null): void;
  onFocusChange?(focused: boolean): void;
  /** Return true to take the key (the link picker's arrows and Enter). */
  onKeyDown?(event: KeyboardEvent<HTMLTextAreaElement>): boolean;
  /** A tap on a read-only body (a note in Trash). */
  onReadOnlyTap?(): void;
  ariaLabel?: string;
}

export const BodyField = forwardRef<BodyFieldHandle, BodyFieldProps>(function BodyField(props, ref) {
  const { markdown, readOnly, findQuery = "", currentMatch = -1 } = props;
  const area = useRef<HTMLTextAreaElement>(null);
  const mirror = useRef<HTMLDivElement>(null);
  const [text, setTextState] = useState(props.initialText);
  const previous = useRef({ text: props.initialText, start: 0, end: 0 });
  const composing = useRef(false);
  const callbacks = useRef(props);
  useEffect(() => {
    callbacks.current = props;
  });

  const finding = findQuery.trim() !== "";
  const matches = useMemo(() => findMatches(text, findQuery), [text, findQuery]);
  const segments = useMemo(
    () => bodySegments(text, { markdown, matches, current: currentMatch }),
    [text, markdown, matches, currentMatch],
  );

  // Bring the match navigated to into view.
  useEffect(() => {
    if (!finding || currentMatch < 0) {
      return;
    }
    mirror.current?.querySelector("[data-current]")?.scrollIntoView({ block: "nearest", behavior: "smooth" });
  }, [finding, currentMatch, segments]);

  const reportLinkQuery = (): void => {
    const el = area.current;
    const onLinkQuery = callbacks.current.onLinkQuery;
    if (!el || !onLinkQuery) {
      return;
    }
    const collapsed = el.selectionStart === el.selectionEnd;
    const focused = document.activeElement === el;
    onLinkQuery(focused && collapsed ? openLinkQuery(el.value, el.selectionStart) : null);
  };

  const commit = (value: string): void => {
    previous.current = { text: value, start: area.current?.selectionStart ?? 0, end: area.current?.selectionEnd ?? 0 };
    setTextState(value);
    callbacks.current.onTextChange(value);
    reportLinkQuery();
  };

  useImperativeHandle(ref, () => ({
    getText: () => area.current?.value ?? previous.current.text,
    setText(value, caret) {
      const el = area.current;
      if (el) {
        el.value = value;
        if (caret !== undefined) {
          const at = caret === "end" ? value.length : Math.min(caret, value.length);
          el.setSelectionRange(at, at);
        }
      }
      previous.current = { text: value, start: el?.selectionStart ?? 0, end: el?.selectionEnd ?? 0 };
      setTextState(value);
    },
    replaceRange(start, end, insert, selection) {
      const el = area.current;
      if (!el) {
        return;
      }
      el.focus();
      el.setRangeText(insert, start, end, "end");
      if (selection) {
        el.setSelectionRange(selection.start, selection.end);
      }
      commit(el.value);
    },
    selection: () => ({ start: area.current?.selectionStart ?? 0, end: area.current?.selectionEnd ?? 0 }),
    focus(caret) {
      const el = area.current;
      if (!el) {
        return;
      }
      el.focus({ preventScroll: caret !== "end" });
      if (caret === "end") {
        el.setSelectionRange(el.value.length, el.value.length);
      }
    },
    element: () => area.current,
  }));

  const onInput = (): void => {
    const el = area.current;
    if (!el) {
      return;
    }
    let value = el.value;
    if (!composing.current) {
      const widened = widenLinkDeletion(previous.current.text, value);
      if (widened) {
        el.value = widened.text;
        el.setSelectionRange(widened.caret, widened.caret);
        value = widened.text;
      }
    }
    commit(value);
  };

  // A caret never rests inside a note link, so the link moves as one unit.
  const onSelect = (): void => {
    const el = area.current;
    if (!el) {
      return;
    }
    if (!composing.current && el.value.includes("[[")) {
      const base = snapOutOfLinks(el.value, el.selectionStart, previous.current.start);
      const extent = snapOutOfLinks(el.value, el.selectionEnd, previous.current.end);
      if (base !== el.selectionStart || extent !== el.selectionEnd) {
        el.setSelectionRange(Math.min(base, extent), Math.max(base, extent));
      }
    }
    previous.current = { ...previous.current, start: el.selectionStart, end: el.selectionEnd };
    reportLinkQuery();
  };

  const textClass = markdown ? "font-mono text-sm leading-6" : "text-base leading-6";
  const shared = cn("w-full whitespace-pre-wrap break-words px-0 py-2 [tab-size:4]", textClass);

  return (
    <div className="relative">
      <div ref={mirror} aria-hidden className={cn(shared, "pointer-events-none min-h-36 text-on-surface select-none")}>
        {segments.map((segment, i) => (
          <span
            key={i}
            data-current={segment.styles.includes("current") ? "" : undefined}
            className={cn(segment.styles.filter((s) => markdown || !WIDTH_STYLES.has(s)).map((s) => STYLE_CLASS[s]))}
          >
            {segment.text}
          </span>
        ))}
        {/* A trailing newline still gets its line. */}
        {text.endsWith("\n") || text === "" ? "​" : null}
      </div>
      <textarea
        ref={area}
        defaultValue={props.initialText}
        aria-label={props.ariaLabel ?? "Note"}
        placeholder={props.placeholder ?? "Note"}
        readOnly={readOnly || finding}
        spellCheck
        autoCapitalize="sentences"
        className={cn(
          shared,
          "absolute inset-0 h-full resize-none overflow-hidden bg-transparent text-transparent caret-on-surface outline-none placeholder:text-on-surface-variant/70 selection:bg-secondary-container/70 selection:text-transparent",
        )}
        onInput={onInput}
        onSelect={onSelect}
        onFocus={() => {
          callbacks.current.onFocusChange?.(true);
          reportLinkQuery();
        }}
        onBlur={() => {
          callbacks.current.onFocusChange?.(false);
          callbacks.current.onLinkQuery?.(null);
        }}
        onCompositionStart={() => {
          composing.current = true;
        }}
        onCompositionEnd={() => {
          composing.current = false;
        }}
        onPointerDown={() => {
          if (readOnly) {
            callbacks.current.onReadOnlyTap?.();
          }
        }}
        onKeyDown={(event) => {
          if (callbacks.current.onKeyDown?.(event)) {
            event.preventDefault();
          }
        }}
      />
    </div>
  );
});
