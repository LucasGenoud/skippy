import type { DroppedFile } from "@/lib/models";
import { MAX_UPLOAD_BYTES, mimeFromName, pastedFileName } from "@/lib/util/mime";

// Browser file plumbing for the window drop target and the paste listener
// (`web_files.dart`, `file_drop_web.dart`, `paste_events_web.dart`).
// Snapshot handles synchronously inside the event handler: a drop's or
// paste's DataTransfer is neutered once the handler returns.

/** Whether a drag carries files from the OS (not text or an in-page drag). */
export function dragHasFiles(data: DataTransfer | null): boolean {
  if (!data) {
    return false;
  }
  return Array.from(data.types).includes("Files");
}

/** The files a drop carried. */
export function droppedHandles(data: DataTransfer | null): File[] {
  return data ? Array.from(data.files) : [];
}

/**
 * Files on the clipboard. `files` covers current browsers; the `items` sweep
 * is the fallback for engines that only expose a pasted image there.
 */
export function clipboardHandles(data: DataTransfer | null): File[] {
  if (!data) {
    return [];
  }
  const files = Array.from(data.files);
  if (files.length > 0) {
    return files;
  }
  const out: File[] = [];
  for (const item of Array.from(data.items)) {
    if (item.kind !== "file") {
      continue;
    }
    const file = item.getAsFile();
    if (file) {
      out.push(file);
    }
  }
  return out;
}

export type FileSource = "drop" | "paste";

/**
 * Upload-ready files from browser handles, over-size ones left out. A pasted
 * screenshot (every browser names it `image.png`) gets a stamped name so a run
 * of them stays distinguishable on the note.
 */
export function toDroppedFiles(handles: readonly File[], source: FileSource, at: Date = new Date()): DroppedFile[] {
  return handles
    .filter((f) => f.size <= MAX_UPLOAD_BYTES)
    .map((f) => {
      const mime = f.type || mimeFromName(f.name);
      const name = source === "paste" ? pastedFileName(mime, f.name, at) : f.name;
      return { name, mime, bytes: f };
    });
}

/**
 * Nets out dragenter/dragleave, which fire for every element boundary
 * crossed, so the overlay only clears when the drag leaves the page.
 */
export class DragDepth {
  private depth = 0;

  enter(): boolean {
    this.depth++;
    return true;
  }

  /** True while the drag is still over the page. */
  leave(): boolean {
    if (this.depth > 0) {
      this.depth--;
    }
    return this.depth > 0;
  }

  reset(): void {
    this.depth = 0;
  }
}
