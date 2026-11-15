"use client";

import { createContext, useContext, useMemo, type ComponentProps, type ReactNode } from "react";
import Markdown, { defaultUrlTransform, type Components } from "react-markdown";
import remarkGfm from "remark-gfm";
import { cn } from "cn";

import { navigate } from "@/lib/router";
import { markdownNoteLinks, NOTE_LINK_SCHEME, noteIdFromHref } from "@/lib/state/note-links";
import { useOptionalSession } from "@/lib/store";
import { safeLinkHref } from "@/lib/util/linkify";

import { CodeBlock } from "./code-block";
import type { NoteMarkdownProps } from "./note-markdown";

// The react-markdown half of NoteMarkdown, split out so it loads on demand.

type Variant = "card" | "editor";

interface RenderContext {
  readonly variant: Variant;
  /** False signed out (the public share page): note links show as plain titles. */
  readonly canOpenNotes: boolean;
  readonly onToggleTask?: (lineIndex: number, done: boolean) => void;
}

const Context = createContext<RenderContext>({ variant: "card", canOpenNotes: false });
/** The 0-based source line of the task list item being rendered. */
const TaskLine = createContext<number | null>(null);

const REMARK_PLUGINS = [remarkGfm];

/** Note links keep their own scheme; everything else goes through the safe default. */
function urlTransform(url: string): string {
  return url.startsWith(`${NOTE_LINK_SCHEME}:`) ? url : defaultUrlTransform(url);
}

interface HastNode {
  type: string;
  value?: string;
  tagName?: string;
  properties?: Record<string, unknown>;
  children?: HastNode[];
  position?: { start: { line: number } };
}

function textOf(node: HastNode | undefined): string {
  if (!node) {
    return "";
  }
  if (node.type === "text") {
    return node.value ?? "";
  }
  return (node.children ?? []).map(textOf).join("");
}

const STYLES: Record<Variant, { root: string; h1: string; h2: string; h3: string }> = {
  card: { root: "text-sm leading-[1.45]", h1: "text-base font-semibold", h2: "text-[15px] font-semibold", h3: "text-sm font-semibold" },
  editor: { root: "text-base leading-relaxed", h1: "text-xl font-semibold", h2: "text-lg font-semibold", h3: "text-base font-semibold" },
};

// react-markdown hands every component its hast `node`, which must not reach the DOM,
// so the overrides below destructure it away unused.
/* eslint-disable @typescript-eslint/no-unused-vars */
const COMPONENTS: Components = {
  h1: ({ node: _node, ...props }) => <Heading level="h1" {...props} />,
  h2: ({ node: _node, ...props }) => <Heading level="h2" {...props} />,
  h3: ({ node: _node, ...props }) => <Heading level="h3" {...props} />,
  h4: ({ node: _node, ...props }) => <Heading level="h3" {...props} />,
  h5: ({ node: _node, ...props }) => <Heading level="h3" {...props} />,
  h6: ({ node: _node, ...props }) => <Heading level="h3" {...props} />,
  p: ({ node: _node, ...props }) => <p className="my-1.5 first:mt-0 last:mb-0" {...props} />,
  ul: ({ node: _node, className, ...props }) => (
    <ul className={cn("my-1.5 list-disc pl-5 first:mt-0 last:mb-0", className?.includes("contains-task-list") && "list-none pl-0.5")} {...props} />
  ),
  ol: ({ node: _node, ...props }) => <ol className="my-1.5 list-decimal pl-5 first:mt-0 last:mb-0" {...props} />,
  li: ({ node, className, ...props }) => {
    const task = className?.includes("task-list-item") ?? false;
    const line = (node as HastNode | undefined)?.position?.start.line;
    const item = <li className={cn("my-0.5", task && "flex items-start gap-2 [&>ul]:basis-full")} {...props} />;
    return task && line !== undefined ? <TaskLine.Provider value={line - 1}>{item}</TaskLine.Provider> : item;
  },
  input: ({ node: _node, type, checked }) => (type === "checkbox" ? <TaskBox checked={Boolean(checked)} /> : null),
  blockquote: ({ node: _node, ...props }) => <blockquote className="my-1.5 border-l-[3px] border-outline-variant pl-3 text-on-surface-variant" {...props} />,
  hr: () => <hr className="my-3 border-hairline" />,
  a: ({ node: _node, href, children }) => <MarkdownLink href={href ?? ""}>{children}</MarkdownLink>,
  code: ({ node: _node, ...props }) => <code className="rounded-xs bg-code-fill px-1 py-px font-mono text-[0.9em]" {...props} />,
  pre: ({ node }) => {
    const code = (node as HastNode | undefined)?.children?.find((c) => c.tagName === "code");
    const classes = code?.properties?.className;
    const language = (Array.isArray(classes) ? classes.map(String) : [])
      .find((c) => c.startsWith("language-"))
      ?.slice("language-".length);
    // A fence always ends in a newline the reader never typed.
    return <PreBlock source={textOf(code).replace(/\n$/, "")} language={language ?? ""} />;
  },
  table: ({ node: _node, ...props }) => (
    <div className="my-1.5 overflow-x-auto">
      <table className="w-full border-collapse text-[0.95em]" {...props} />
    </div>
  ),
  th: ({ node: _node, ...props }) => <th className="border border-outline-variant px-2 py-1 text-left font-semibold" {...props} />,
  td: ({ node: _node, ...props }) => <td className="border border-outline-variant px-2 py-1 align-top" {...props} />,
  img: ({ node: _node, src, alt }) =>
    typeof src === "string" && safeLinkHref(src) ? <img src={src} alt={alt ?? ""} loading="lazy" className="my-1 max-w-full rounded-md" /> : null,
  del: ({ node: _node, ...props }) => <del className="text-on-surface-variant" {...props} />,
};

/* eslint-enable @typescript-eslint/no-unused-vars */

function Heading({ level, ...props }: { level: "h1" | "h2" | "h3" } & ComponentProps<"h1">) {
  const { variant } = useContext(Context);
  const Tag = level;
  return <Tag className={cn("mt-3 mb-1 first:mt-0", STYLES[variant][level])} {...props} />;
}

function PreBlock({ source, language }: { source: string; language: string }) {
  const { variant } = useContext(Context);
  return <CodeBlock source={source} language={language} variant={variant} />;
}

function TaskBox({ checked }: { checked: boolean }) {
  const { variant, onToggleTask } = useContext(Context);
  const line = useContext(TaskLine);
  const interactive = variant === "editor" && onToggleTask !== undefined && line !== null;
  return (
    <button
      type="button"
      role="checkbox"
      aria-checked={checked}
      aria-label={checked ? "Mark task not done" : "Mark task done"}
      disabled={!interactive}
      tabIndex={interactive ? 0 : -1}
      onClick={(event) => {
        event.stopPropagation();
        if (interactive) {
          onToggleTask(line, !checked);
        }
      }}
      className={cn(
        "mt-[0.2em] inline-flex size-4 shrink-0 items-center justify-center rounded-check border transition-colors duration-150 ease-standard outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50 disabled:cursor-default",
        checked ? "border-primary-container bg-primary-container text-on-primary-container" : "border-outline bg-transparent",
      )}
    >
      {checked ? (
        <svg viewBox="0 0 16 16" aria-hidden className="size-3">
          <path d="M3.5 8.5l3 3 6-7" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      ) : null}
    </button>
  );
}

function MarkdownLink({ href, children }: { href: string; children: ReactNode }) {
  const { variant, canOpenNotes } = useContext(Context);
  const noteId = noteIdFromHref(href);
  if (noteId !== null) {
    if (variant === "card" || !canOpenNotes) {
      return <span className="font-semibold text-primary">{children}</span>;
    }
    return (
      <a
        href={`/n/${noteId}`}
        className="font-semibold text-primary hover:underline"
        onClick={(event) => {
          event.preventDefault();
          event.stopPropagation();
          navigate({ name: "note", noteId });
        }}
      >
        {children}
      </a>
    );
  }
  const safe = safeLinkHref(href);
  if (variant === "card" || safe === null) {
    return <span className="text-primary underline underline-offset-2">{children}</span>;
  }
  return (
    <a href={safe} target="_blank" rel="noopener noreferrer" className="text-primary underline underline-offset-2" onClick={(e) => e.stopPropagation()}>
      {children}
    </a>
  );
}

export default function MarkdownRenderer({ source, variant, onToggleTask }: NoteMarkdownProps) {
  const session = useOptionalSession();
  // Links show the linked note's live title; line count is unchanged, so task lines still match.
  const text = useMemo(() => markdownNoteLinks(source, session ? (id) => session.notes.linkTitleFor(id) : undefined), [source, session]);
  const canOpenNotes = session !== null;
  const context = useMemo<RenderContext>(() => ({ variant, onToggleTask, canOpenNotes }), [variant, onToggleTask, canOpenNotes]);
  return (
    <Context.Provider value={context}>
      <div className={cn("break-words", STYLES[variant].root)}>
        <Markdown remarkPlugins={REMARK_PLUGINS} components={COMPONENTS} urlTransform={urlTransform}>
          {text}
        </Markdown>
      </div>
    </Context.Provider>
  );
}
