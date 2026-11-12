"use client";

import { memo, useState } from "react";
import { ImageOff } from "lucide-react";
import { cn } from "cn";

import type { Attachment } from "@/lib/models/note";

// A note's image attachment (`util/note_image.dart`, `util/attachment_image.dart`).
//
// File URLs are signed and rotate every hour, but attachment bytes never
// change. Keying the <img> on the URL would refetch every picture in the grid
// at each rollover, so the first URL an attachment was shown with stays its
// source until it stops working; only then is the fresh one used.
//
// The box grows to the picture's own aspect ratio (known once it loads, and
// remembered), capped at [maxHeight]; taller pictures crop from the bottom.

/** A neutral height while the aspect ratio is unknown. */
const ESTIMATED_HEIGHT = 160;

interface Known {
  url: string;
  aspect: number | null;
}

const known = new Map<string, Known>();

function sourceFor(attachment: Attachment, url: string): Known {
  const entry = known.get(attachment.id);
  if (entry) {
    return entry;
  }
  const fresh = { url, aspect: null };
  known.set(attachment.id, fresh);
  return fresh;
}

export const NoteImage = memo(function NoteImage({
  attachment,
  url,
  maxHeight,
  className,
}: {
  attachment: Attachment;
  /** The current signed URL. */
  url: string;
  maxHeight: number;
  className?: string;
}) {
  const entry = sourceFor(attachment, url);
  const [src, setSrc] = useState(entry.url);
  const [aspect, setAspect] = useState(entry.aspect);
  const [loaded, setLoaded] = useState(false);
  const [failed, setFailed] = useState(false);

  if (failed) {
    return (
      <div className={cn("flex h-20 items-center justify-center bg-surface-container-highest text-on-surface-variant", className)}>
        <ImageOff aria-hidden className="size-5" />
      </div>
    );
  }

  return (
    <div
      className={cn("w-full overflow-hidden bg-on-surface/6", className)}
      style={aspect ? { aspectRatio: aspect, maxHeight } : { height: Math.min(ESTIMATED_HEIGHT, maxHeight) }}
    >
      <img
        src={src}
        alt={attachment.filename}
        loading="lazy"
        decoding="async"
        draggable={false}
        className={cn("size-full object-cover object-top transition-opacity duration-240 ease-standard", loaded ? "opacity-100" : "opacity-0")}
        onLoad={(event) => {
          const image = event.currentTarget;
          if (image.naturalWidth > 0 && image.naturalHeight > 0) {
            const ratio = image.naturalWidth / image.naturalHeight;
            entry.aspect = ratio;
            setAspect(ratio);
          }
          setLoaded(true);
        }}
        onError={() => {
          // The remembered URL has expired: switch to the current one once.
          if (src !== url) {
            entry.url = url;
            setSrc(url);
            return;
          }
          setFailed(true);
        }}
      />
    </div>
  );
});
