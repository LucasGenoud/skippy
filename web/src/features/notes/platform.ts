"use client";

import { useSyncExternalStore } from "react";

// Browser facts the cards and the grid branch on, each read through one
// shared listener rather than one per card.

const TOUCH_QUERY = "(hover: none) and (pointer: coarse)";

function touchMedia(): MediaQueryList | null {
  if (typeof window === "undefined" || typeof window.matchMedia !== "function") {
    return null;
  }
  return window.matchMedia(TOUCH_QUERY);
}

function subscribeTouch(onChange: () => void): () => void {
  const media = touchMedia();
  media?.addEventListener("change", onChange);
  return () => media?.removeEventListener("change", onChange);
}

const touchSnapshot = (): boolean => touchMedia()?.matches ?? false;
const serverSnapshot = (): boolean => false;

/**
 * Whether the primary pointer is a finger (`isTouchPrimaryPlatform`): no
 * hover row of actions, swipe to archive, long press to select.
 */
export function useTouchPrimary(): boolean {
  return useSyncExternalStore(subscribeTouch, touchSnapshot, serverSnapshot);
}

// -- one ResizeObserver for every observed element ----------------------------------

type SizeListener = (size: { width: number; height: number }) => void;

let observer: ResizeObserver | null = null;
const listeners = new WeakMap<Element, SizeListener>();

function sharedObserver(): ResizeObserver | null {
  if (observer || typeof ResizeObserver === "undefined") {
    return observer;
  }
  observer = new ResizeObserver((entries) => {
    for (const entry of entries) {
      const box = entry.borderBoxSize?.[0];
      const width = box ? box.inlineSize : entry.contentRect.width;
      const height = box ? box.blockSize : entry.contentRect.height;
      listeners.get(entry.target)?.({ width, height });
    }
  });
  return observer;
}

/** Calls [listener] with [element]'s border-box size now and on every change. */
export function observeSize(element: Element, listener: SizeListener): () => void {
  const shared = sharedObserver();
  listeners.set(element, listener);
  shared?.observe(element);
  return () => {
    listeners.delete(element);
    shared?.unobserve(element);
  };
}

/** Saves a text or blob as a download. */
export function downloadFile(name: string, content: string | Blob, mime: string): void {
  const blob = typeof content === "string" ? new Blob([content], { type: mime }) : content;
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  document.body.append(link);
  link.click();
  link.remove();
  // Revoked on the next task: some browsers start the download asynchronously.
  setTimeout(() => URL.revokeObjectURL(url), 0);
}

/** Opens the system file dialog; resolves with the picked files (empty on cancel). */
export function pickFiles(options: { accept?: string; multiple?: boolean } = {}): Promise<File[]> {
  return new Promise((resolve) => {
    const input = document.createElement("input");
    input.type = "file";
    if (options.accept) {
      input.accept = options.accept;
    }
    input.multiple = options.multiple ?? false;
    let settled = false;
    const finish = (files: File[]): void => {
      if (!settled) {
        settled = true;
        resolve(files);
      }
    };
    input.addEventListener("change", () => finish(Array.from(input.files ?? [])));
    input.addEventListener("cancel", () => finish([]));
    input.click();
  });
}

export { useBrightness } from "@/lib/theme/use-brightness";
