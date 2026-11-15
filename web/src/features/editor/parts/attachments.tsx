"use client";

import { memo, useState } from "react";
import { Download, File as FileIcon, ImageOff, X, ZoomIn, ZoomOut } from "lucide-react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { Dialog as DialogPrimitive } from "radix-ui";
import { cn } from "cn";

import { IconButton } from "@/components/common/icon-button";
import { showAppSnack } from "@/components/common/snack";
import { isAudioAttachment, isImageAttachment, type Attachment } from "@/lib/models/note";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";
import { formatBytes } from "@/lib/util/mime";

// What a note carries besides its text (`attachment_tiles.dart`): images
// first, then other files, each followed by placeholders for the ones still
// uploading, so a tile appears where its attachment will land. Audio is played
// by the audio body instead.

/** A file on its way up: the bytes are already here, so an image previews at once. */
export interface PendingUpload {
  readonly key: string;
  readonly name: string;
  readonly mime: string;
  readonly size: number;
  /** An object URL of the picked image, or null for other files. */
  readonly previewUrl: string | null;
}

/** Saves [url] as [filename]: through a blob, since `download` is ignored cross-origin. */
export async function downloadUrl(url: string, filename: string): Promise<void> {
  try {
    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(String(response.status));
    }
    const href = URL.createObjectURL(await response.blob());
    const anchor = document.createElement("a");
    anchor.href = href;
    anchor.download = filename;
    anchor.click();
    setTimeout(() => URL.revokeObjectURL(href), 0);
  } catch {
    window.open(url, "_blank", "noopener");
  }
}

const tileMotion = {
  initial: { opacity: 0, height: 0 },
  animate: { opacity: 1, height: "auto" },
  exit: { opacity: 0, height: 0 },
} as const;

export function AttachmentTiles({
  attachments,
  uploading,
  urlOf,
  onRemove,
}: {
  attachments: readonly Attachment[];
  uploading: readonly PendingUpload[];
  urlOf(attachment: Attachment): string;
  /** Null makes the tiles read-only (a note in Trash). */
  onRemove: ((attachment: Attachment) => void) | null;
}) {
  const reduced = useReducedMotion();
  const transition = transitionFor(TRANSITION.base, reduced);
  const images = attachments.filter(isImageAttachment);
  const files = attachments.filter((a) => !isImageAttachment(a) && !isAudioAttachment(a));
  const pendingImages = uploading.filter((u) => u.mime.startsWith("image/"));
  const pendingFiles = uploading.filter((u) => !u.mime.startsWith("image/"));
  const wrap = (key: string, node: React.ReactNode) => (
    <motion.div key={key} {...tileMotion} transition={transition} className="overflow-hidden">
      {node}
    </motion.div>
  );
  return (
    <div className="flex flex-col">
      <AnimatePresence initial={false}>
        {images.map((a) =>
          wrap(a.id, <ImageTile attachment={a} url={urlOf(a)} onRemove={onRemove ? () => onRemove(a) : null} />),
        )}
        {pendingImages.map((u) => wrap(u.key, <UploadingTile upload={u} />))}
        {files.map((a) => wrap(a.id, <FileTile attachment={a} url={urlOf(a)} onRemove={onRemove ? () => onRemove(a) : null} />))}
        {pendingFiles.map((u) => wrap(u.key, <UploadingTile upload={u} />))}
      </AnimatePresence>
    </div>
  );
}

const ImageTile = memo(function ImageTile({ attachment, url, onRemove }: { attachment: Attachment; url: string; onRemove: (() => void) | null }) {
  const [viewing, setViewing] = useState(false);
  const [broken, setBroken] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const name = attachment.filename || "image";
  return (
    <div className="group relative mb-3 overflow-hidden rounded-md bg-surface-container-highest">
      <button type="button" className="block w-full outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50" aria-label={`View ${name}`} onClick={() => setViewing(true)}>
        {broken ? (
          <span className="flex h-20 items-center justify-center text-on-surface-variant">
            <ImageOff aria-hidden className="size-6" />
          </span>
        ) : (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={url}
            alt={name}
            loading="lazy"
            decoding="async"
            onLoad={() => setLoaded(true)}
            onError={() => setBroken(true)}
            className={cn("max-h-80 min-h-20 w-full object-cover transition-opacity duration-240 ease-standard", loaded ? "opacity-100" : "opacity-0")}
          />
        )}
      </button>
      <div className="absolute top-2 right-2 flex overflow-hidden rounded-md bg-black/55 text-white opacity-100 transition-opacity duration-150 ease-standard sm:opacity-0 sm:group-focus-within:opacity-100 sm:group-hover:opacity-100">
        <IconButton size="sm" label="Download image" icon={<Download />} className="text-white hover:bg-white/15 hover:text-white" onClick={() => void downloadUrl(url, name)} />
        {onRemove ? <IconButton size="sm" label="Remove image" icon={<X />} className="text-white hover:bg-white/15 hover:text-white" onClick={onRemove} /> : null}
      </div>
      <ImageViewer open={viewing} onOpenChange={setViewing} url={url} name={name} />
    </div>
  );
});

function ImageViewer({ open, onOpenChange, url, name }: { open: boolean; onOpenChange(open: boolean): void; url: string; name: string }) {
  const [zoomed, setZoomed] = useState(false);
  const reduced = useReducedMotion();
  return (
    <DialogPrimitive.Root open={open} onOpenChange={(next) => { onOpenChange(next); setZoomed(false); }}>
      <DialogPrimitive.Portal>
        <DialogPrimitive.Overlay className="fixed inset-0 z-50 bg-black data-[state=open]:animate-in data-[state=open]:fade-in-0 data-[state=open]:duration-240 data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=closed]:duration-150" />
        <DialogPrimitive.Content className="fixed inset-0 z-50 flex flex-col outline-none data-[state=open]:animate-in data-[state=open]:fade-in-0 data-[state=open]:duration-240 data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=closed]:duration-150">
          <DialogPrimitive.Title className="sr-only">{name}</DialogPrimitive.Title>
          <div className="flex justify-end gap-1 p-2">
            <IconButton label={zoomed ? "Fit to screen" : "Zoom in"} icon={zoomed ? <ZoomOut /> : <ZoomIn />} className="text-white hover:bg-white/15 hover:text-white" onClick={() => setZoomed((z) => !z)} />
            <IconButton label="Download image" icon={<Download />} className="text-white hover:bg-white/15 hover:text-white" onClick={() => void downloadUrl(url, name)} />
            <DialogPrimitive.Close asChild>
              <IconButton label="Close image" icon={<X />} className="text-white hover:bg-white/15 hover:text-white" />
            </DialogPrimitive.Close>
          </div>
          <div className={cn("min-h-0 flex-1 px-3 pb-3", zoomed ? "overflow-auto" : "flex items-center justify-center overflow-hidden")}>
            <motion.img
              src={url}
              alt={name}
              onClick={() => setZoomed((z) => !z)}
              layout
              transition={transitionFor(TRANSITION.base, reduced)}
              className={cn(zoomed ? "max-w-none cursor-zoom-out" : "max-h-full max-w-full cursor-zoom-in object-contain")}
            />
          </div>
        </DialogPrimitive.Content>
      </DialogPrimitive.Portal>
    </DialogPrimitive.Root>
  );
}

function UploadingTile({ upload }: { upload: PendingUpload }) {
  const preview = upload.previewUrl;
  if (upload.mime.startsWith("image/")) {
    return (
      <div className="relative mb-3 flex max-h-80 min-h-20 items-center justify-center overflow-hidden rounded-md bg-surface-container-highest">
        {preview ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={preview} alt="" className="max-h-80 w-full object-cover opacity-50" />
        ) : null}
        <span aria-label="Uploading" className="absolute size-7 animate-spin rounded-full border-[2.5px] border-white/40 border-t-primary" />
      </div>
    );
  }
  return (
    <div className="mb-2 flex items-center gap-2.5 rounded-md bg-on-surface/6 px-3 py-2">
      <FileIcon aria-hidden className="size-5 text-on-surface-variant/60" />
      <span className="min-w-0 flex-1">
        <span className="block truncate text-sm text-on-surface-variant">{upload.name || "file"}</span>
        <span className="block text-2xs text-on-surface-variant">Uploading… {formatBytes(upload.size)}</span>
      </span>
      <span aria-label="Uploading" className="size-4 animate-spin rounded-full border-2 border-on-surface-variant/30 border-t-primary" />
    </div>
  );
}

const FileTile = memo(function FileTile({ attachment, url, onRemove }: { attachment: Attachment; url: string; onRemove: (() => void) | null }) {
  const name = attachment.filename || "file";
  return (
    <div className="mb-2 flex items-center gap-1 rounded-md bg-on-surface/6 transition-colors duration-150 ease-standard hover:bg-on-surface/9">
      <button
        type="button"
        onClick={() => {
          void downloadUrl(url, name).catch(() => showAppSnack("Couldn't download the file"));
        }}
        className="flex min-w-0 flex-1 items-center gap-2.5 rounded-md px-3 py-2 text-left outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50"
      >
        <FileIcon aria-hidden className="size-5 shrink-0 text-on-surface-variant" />
        <span className="min-w-0 flex-1">
          <span className="block truncate text-sm text-on-surface">{name}</span>
          <span className="block text-2xs text-on-surface-variant">{formatBytes(attachment.size)}</span>
        </span>
        <Download aria-hidden className="size-4 shrink-0 text-on-surface-variant" />
      </button>
      {onRemove ? <IconButton size="sm" label="Remove file" icon={<X />} className="mr-1" onClick={onRemove} /> : null}
    </div>
  );
}
);
