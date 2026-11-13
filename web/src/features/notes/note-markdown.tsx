"use client";

import { lazy, memo, Suspense } from "react";
import { cn } from "cn";

export interface NoteMarkdownProps {
  source: string;
  /**
   * "card": a compact, inert preview (links drawn, nothing to press).
   * "editor": links open, code blocks scroll and copy, tasks toggle when
   * [onToggleTask] is given.
   */
  variant: "card" | "editor";
  /** A `- [ ]` task was toggled; [lineIndex] is its 0-based line in [source]. */
  onToggleTask?(lineIndex: number, done: boolean): void;
}

// The parser and its plugins load on first use, so a grid without markdown
// notes never downloads them.
const MarkdownRenderer = lazy(() => import("./markdown-renderer"));

/** A note's markdown, rendered (`note_markdown.dart`). */
export const NoteMarkdown = memo(function NoteMarkdown(props: NoteMarkdownProps) {
  return (
    <Suspense fallback={<PlainFallback source={props.source} variant={props.variant} />}>
      <MarkdownRenderer {...props} />
    </Suspense>
  );
});

/** What shows for the moment the renderer is loading: the source, quietly. */
function PlainFallback({ source, variant }: { source: string; variant: "card" | "editor" }) {
  return <div className={cn("whitespace-pre-wrap break-words", variant === "card" ? "text-sm" : "text-base")}>{source}</div>;
}
