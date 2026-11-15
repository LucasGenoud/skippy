"use client";

import { memo, useMemo, type ReactNode } from "react";

import { navigate } from "@/lib/router";
import { findNoteLinks } from "@/lib/state/note-links";
import { useOptionalSession } from "@/lib/store";
import { linkedSegments, safeLinkHref } from "@/lib/util/linkify";

export interface LinkedTextProps {
  text: string;
  /** Free words to tint (the search's text, without operators). */
  highlight?: string;
  /**
   * "card": links are drawn but inert, so a tap anywhere opens the note.
   * "editor": URLs open in a new tab and note links open their note.
   */
  variant: "card" | "editor";
}

/** Read-only text with URLs as links and `[[id|Title]]` as the note's live title (`linked_text.dart`). */
export const LinkedText = memo(function LinkedText({ text, highlight = "", variant }: LinkedTextProps) {
  const session = useOptionalSession();
  // Titles are read when the text renders; a renamed target shows on the next render.
  const parts = useMemo(
    // Signed out (the public share page) a note link cannot be followed: it shows as its title.
    () => linkedParts(text, highlight, variant, session ? (id) => session.notes.linkTitleFor(id) : null, session !== null),
    [text, highlight, variant, session],
  );
  return <span className="whitespace-pre-wrap break-words">{parts}</span>;
});

const LINK_CLASS = "text-primary underline decoration-primary underline-offset-2";
const NOTE_LINK_CLASS = "font-semibold text-primary";
const MATCH_CLASS = "rounded-xs bg-primary/30 text-inherit";

function linkedParts(
  text: string,
  highlight: string,
  variant: "card" | "editor",
  titleFor: ((id: string) => string | null) | null,
  canOpenNotes: boolean,
): ReactNode[] {
  const out: ReactNode[] = [];
  let cursor = 0;
  let key = 0;
  const plain = (part: string): void => {
    for (const segment of linkedSegments(part, highlight)) {
      out.push(segmentNode(segment, variant, key++));
    }
  };
  for (const link of findNoteLinks(text)) {
    if (link.start > cursor) {
      plain(text.slice(cursor, link.start));
    }
    const title = titleFor?.(link.noteId) ?? link.title;
    out.push(
      variant === "editor" && canOpenNotes ? (
        <a
          key={key++}
          href={`/n/${link.noteId}`}
          className={`${NOTE_LINK_CLASS} hover:underline`}
          onClick={(event) => {
            event.preventDefault();
            event.stopPropagation();
            navigate({ name: "note", noteId: link.noteId });
          }}
        >
          {title}
        </a>
      ) : (
        <span key={key++} className={NOTE_LINK_CLASS}>
          {title}
        </span>
      ),
    );
    cursor = link.end;
  }
  if (cursor < text.length) {
    plain(text.slice(cursor));
  }
  return out;
}

function segmentNode(
  segment: ReturnType<typeof linkedSegments>[number],
  variant: "card" | "editor",
  key: number,
): ReactNode {
  if (segment.kind === "text") {
    return segment.match ? (
      <mark key={key} className={MATCH_CLASS}>
        {segment.text}
      </mark>
    ) : (
      segment.text
    );
  }
  const href = safeLinkHref(segment.url);
  if (variant === "card" || href === null) {
    return (
      <span key={key} className={LINK_CLASS}>
        {segment.text}
      </span>
    );
  }
  return (
    <a key={key} href={href} target="_blank" rel="noopener noreferrer" className={LINK_CLASS} onClick={(event) => event.stopPropagation()}>
      {segment.text}
    </a>
  );
}
