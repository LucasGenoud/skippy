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

// Aspect ratios outlive the page, so a reload lays a picture out at its real
// height at once instead of growing the card when the bytes arrive.
const ASPECT_STORE_KEY = "skippy.imageAspects";
const ASPECT_STORE_CAP = 400;
let storedAspects: Map<string, number> | null = null;

function aspects(): Map<string, number> {
  if (storedAspects) {
    return storedAspects;
  }
  if (typeof window === "undefined") {
    return new Map();
  }
  storedAspects = new Map();
  try {
    const raw = window.localStorage.getItem(ASPECT_STORE_KEY);
    const parsed: unknown = raw ? JSON.parse(raw) : null;
    if (parsed && typeof parsed === "object") {
      for (const [id, value] of Object.entries(parsed)) {
        if (typeof value === "number" && value > 0) {
          storedAspects.set(id, value);
        }
      }
    }
  } catch {
    // No storage (private window, blocked site data): heights are learnt again.
  }
  return storedAspects;
}

function rememberAspect(id: string, aspect: number): void {
  const map = aspects();
  if (map.get(id) === aspect) {
    return;
  }
  map.delete(id);
  map.set(id, aspect);
  while (map.size > ASPECT_STORE_CAP) {
    const oldest = map.keys().next().value;
    if (oldest === undefined) {
      break;
    }
    map.delete(oldest);
  }
  try {
    window.localStorage.setItem(ASPECT_STORE_KEY, JSON.stringify(Object.fromEntries(map)));
  } catch {
    // Best effort.
  }
}

function sourceFor(attachment: Attachment, url: string): Known {
  const entry = known.get(attachment.id);
  if (entry) {
    return entry;
  }
  const fresh = { url, aspect: aspects().get(attachment.id) ?? null };
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
            rememberAspect(attachment.id, ratio);
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
