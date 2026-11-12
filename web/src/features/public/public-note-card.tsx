"use client";

import { Component, useState, type ReactNode } from "react";
import { Check, Paperclip } from "lucide-react";
import { cn } from "cn";
import { LabelChip } from "@/components/common/label-chip";
import { NotePattern } from "@/components/common/note-pattern";
import type { Api } from "@/lib/api/client";
import { isAudioAttachment, isImageAttachment, type Attachment, type Label, type Note } from "@/lib/models/note";
import { plainNoteLinks } from "@/lib/state/note-links";
import { noteBackground } from "@/lib/theme/palette";
import { formatBytes } from "@/lib/util/mime";
import { LinkedText } from "@/features/notes/linked-text";
import { NoteMarkdown } from "@/features/notes/note-markdown";
import { checklistPreview } from "./public-layout";
import { useBrightness } from "./use-brightness";

// One note, drawn read-only (`PublicNoteCard`). Deliberately not NoteCard:
// that reads the signed-in stores. This takes everything as props and offers
// nothing to press but the links in its text. Note links show as the title
// they were written with: the reader cannot open the notes they point at.

/** "full" on the single-note page; "preview" caps long notes in the grid and board. */
export type CardExtent = "full" | "preview";

export function PublicNoteCard({ note, api, labels, extent }: { note: Note; api: Api; labels: ReadonlyMap<string, Label>; extent: CardExtent }) {
  const brightness = useBrightness();
  // The stock palette: the publisher's own is a private setting the share does not carry.
  const background = noteBackground(note.color, brightness);
  const full = extent === "full";
  const images = note.attachments.filter(isImageAttachment);
  const audio = note.attachments.filter(isAudioAttachment);
  const files = note.attachments.filter((a) => !isImageAttachment(a) && !isAudioAttachment(a));
  const noteLabels = note.labelIds.map((id) => labels.get(id)).filter((l): l is Label => l !== undefined);
  const content = plainNoteLinks(note.content);

  return (
    <article className="relative overflow-hidden rounded-md border border-hairline shadow-card" style={{ background }}>
      <NotePattern pattern={note.pattern} />
      <div className="relative flex flex-col gap-1.5 px-3.5 py-3">
        {note.title.trim() !== "" ? (
          <h2 className={cn("text-base font-semibold break-words text-on-surface", !full && "line-clamp-3")}>{note.title}</h2>
        ) : null}
        {note.kind === "checklist" ? (
          <PublicChecklist note={note} extent={extent} />
        ) : note.kind === "markdown" ? (
          <MarkdownBoundary fallback={<p className="text-sm whitespace-pre-wrap">{content}</p>}>
            <NoteMarkdown source={content} variant={full ? "editor" : "card"} />
          </MarkdownBoundary>
        ) : content.trim() !== "" ? (
          <p className={cn("text-sm text-on-surface", !full && "line-clamp-[12]")}>
            <LinkedText text={content} variant="editor" />
          </p>
        ) : null}
        {audio.map((a) => (
          // Native controls: the app's player reads the signed-in store.
          <audio key={a.id} controls preload="metadata" src={api.attachmentUrl(a)} className="mt-1 h-9 w-full" aria-label={a.filename || "Audio"} />
        ))}
        {files.length > 0 ? (
          <ul className="mt-1 flex flex-col gap-1">
            {files.map((a) => (
              <FileRow key={a.id} attachment={a} url={api.attachmentUrl(a)} />
            ))}
          </ul>
        ) : null}
        {noteLabels.length > 0 ? (
          <div className="mt-2 flex flex-wrap gap-1.5">
            {noteLabels.map((label) => (
              <LabelChip key={label.id} name={label.name} color={label.color} icon={label.icon} />
            ))}
          </div>
        ) : null}
      </div>
      {/* Below the text, as on the signed-in card. */}
      {images.map((image) => (
        <PublicImage key={image.id} src={api.attachmentUrl(image)} alt={image.filename} />
      ))}
    </article>
  );
}

function PublicChecklist({ note, extent }: { note: Note; extent: CardExtent }) {
  const { shown, hidden } = checklistPreview(note.items, extent);
  return (
    <ul className="flex flex-col gap-1">
      {shown.map((item) => (
        <li key={item.id} className="flex items-start gap-2 text-sm">
          <span
            aria-hidden
            className={cn(
              "mt-0.5 flex size-4 shrink-0 items-center justify-center rounded-check border",
              item.done ? "border-transparent bg-primary-container text-on-primary-container" : "border-outline",
            )}
          >
            {item.done ? <Check className="size-3" strokeWidth={3} /> : null}
          </span>
          <span className={cn("min-w-0 break-words", item.done ? "text-on-surface-variant line-through" : "text-on-surface")}>
            <span className="sr-only">{item.done ? "Done: " : "To do: "}</span>
            {item.text}
          </span>
        </li>
      ))}
      {hidden > 0 ? <li className="pt-1 text-2xs font-medium text-on-surface-variant">+{hidden} more</li> : null}
    </ul>
  );
}

function PublicImage({ src, alt }: { src: string; alt: string }) {
  const [state, setState] = useState<"loading" | "loaded" | "failed">("loading");
  if (state === "failed") {
    return null;
  }
  return (
    // Signed attachment URLs on another origin; next/image adds nothing in a static export.
    // eslint-disable-next-line @next/next/no-img-element
    <img
      src={src}
      alt={alt}
      loading="lazy"
      decoding="async"
      className={cn("relative block w-full object-cover transition-opacity duration-240 ease-standard", state === "loaded" ? "opacity-100" : "opacity-0")}
      onLoad={() => setState("loaded")}
      onError={() => setState("failed")}
    />
  );
}

function FileRow({ attachment, url }: { attachment: Attachment; url: string }) {
  return (
    <li>
      <a
        href={url}
        download={attachment.filename || true}
        target="_blank"
        rel="noopener noreferrer"
        className="flex items-center gap-2 rounded-md px-1 py-1 text-sm text-on-surface hover:bg-hover"
      >
        <Paperclip aria-hidden className="size-4 shrink-0 text-on-surface-variant" />
        <span className="min-w-0 flex-1 truncate">{attachment.filename || "File"}</span>
        <span className="shrink-0 text-xs text-on-surface-variant">{formatBytes(attachment.size)}</span>
      </a>
    </li>
  );
}

/** Falls back to the plain source if the markdown renderer fails, rather than blanking the page. */
class MarkdownBoundary extends Component<{ fallback: ReactNode; children: ReactNode }, { failed: boolean }> {
  state = { failed: false };

  static getDerivedStateFromError(): { failed: boolean } {
    return { failed: true };
  }

  render(): ReactNode {
    return this.state.failed ? this.props.fallback : this.props.children;
  }
}
