"use client";

import { memo, useEffect, useState } from "react";
import { ExternalLink, Globe, Sparkles, Square } from "lucide-react";
import { cn } from "cn";

import { CrossFade } from "@/components/common/reveal";
import { previewHasRichContent, previewHost, type LinkPreview } from "@/lib/models/misc";
import { useLinkPreviews } from "@/lib/store";
import { safeLinkHref } from "@/lib/util/linkify";

import { Spinner } from "./link-summary-indicator";

/** Fixed height of one strip, so a card can reserve room for its previews. */
export const LINK_PREVIEW_HEIGHT = 60;

export interface LinkPreviewCardProps {
  /** The note the link is in (kept for the editor's summary action). */
  noteId: string;
  url: string;
  /**
   * "card": a full-bleed strip under a hairline, continuing the note surface.
   * "editor": a bordered strip; stack several inside a rounded group.
   */
  variant: "card" | "editor";
  /** Editor only: offers "Summarize page" beside the link. */
  onSummarize?(url: string): void;
  onStopSummarize?(url: string): void;
  summarizing?: boolean;
}

function hostOf(url: string): string {
  try {
    const host = new URL(url).host;
    return host.startsWith("www.") ? host.slice(4) : host;
  } catch {
    return url;
  }
}

/** The preview for [url]: what is cached at once, then the fetch's answer. */
function usePreview(url: string): LinkPreview | null {
  const cache = useLinkPreviews();
  const [fetched, setFetched] = useState<{ url: string; preview: LinkPreview | null } | null>(null);
  const cached = cache.peek(url);
  useEffect(() => {
    if (cache.peek(url) !== undefined) {
      return;
    }
    let live = true;
    void cache.preview(url).then((preview) => {
      if (live) {
        setFetched({ url, preview });
      }
    });
    return () => {
      live = false;
    };
  }, [cache, url]);
  if (cached !== undefined) {
    return cached;
  }
  return fetched?.url === url ? fetched.preview : null;
}

/**
 * A compact link preview: thumbnail, page title and site (`link_preview.dart`).
 * While metadata loads, or when the site exposes none, it shows just the host.
 */
export const LinkPreviewCard = memo(function LinkPreviewCard({ url, variant, onSummarize, onStopSummarize, summarizing = false }: LinkPreviewCardProps) {
  const preview = usePreview(url);
  const host = preview ? previewHost(preview) || hostOf(url) : hostOf(url);
  const rich = preview ? previewHasRichContent(preview) : false;
  const title = rich ? (preview?.title ?? host) : host;
  const subtitle = rich ? (preview?.siteName ?? host) : null;
  const href = safeLinkHref(url);
  const summary = variant === "editor" && onSummarize;

  const open = (): void => {
    if (href) {
      window.open(href, "_blank", "noopener,noreferrer");
    }
  };

  return (
    <div
      role="link"
      tabIndex={0}
      aria-label={`Open ${title}`}
      onClick={(event) => {
        event.stopPropagation();
        open();
      }}
      onKeyDown={(event) => {
        if (event.key === "Enter") {
          event.stopPropagation();
          open();
        }
      }}
      className={cn(
        "flex cursor-pointer items-center bg-on-surface/[0.045] transition-colors duration-150 ease-standard outline-none hover:bg-on-surface/[0.07] focus-visible:ring-[3px] focus-visible:ring-ring/50 focus-visible:ring-inset",
        variant === "card" ? "border-t border-on-surface/8" : "overflow-hidden rounded-md border border-outline-variant",
      )}
      style={{ height: LINK_PREVIEW_HEIGHT }}
    >
      <Thumb preview={preview} />
      <div className="min-w-0 flex-1 px-3">
        <CrossFade stateKey={rich ? "rich" : "host"}>
          <div className="flex min-w-0 flex-col justify-center">
            <span className="truncate text-sm leading-tight font-semibold">{title}</span>
            {subtitle ? <span className="mt-0.5 truncate text-2xs text-on-surface-variant">{subtitle}</span> : null}
          </div>
        </CrossFade>
      </div>
      {summary ? (
        <button
          type="button"
          aria-label={summarizing ? "Stop summarizing" : "Summarize page"}
          title={summarizing ? "Stop summarizing" : "Summarize page"}
          className="mr-1 inline-flex size-9 shrink-0 items-center justify-center rounded-md text-on-surface-variant transition-colors duration-150 ease-standard outline-none hover:bg-hover active:bg-pressed focus-visible:ring-[3px] focus-visible:ring-ring/50"
          onClick={(event) => {
            event.stopPropagation();
            if (summarizing) {
              onStopSummarize?.(url);
            } else {
              onSummarize(url);
            }
          }}
        >
          {summarizing ? (
            <span className="relative inline-flex size-5 items-center justify-center">
              <Spinner className="absolute inset-0 size-5" />
              <Square aria-hidden className="size-2.5 fill-current" />
            </span>
          ) : (
            <Sparkles aria-hidden className="size-[18px]" />
          )}
        </button>
      ) : (
        <ExternalLink aria-hidden className="mr-3 ml-1 size-[15px] shrink-0 text-on-surface-variant" />
      )}
    </div>
  );
});

/** The leading square: the page image, else the favicon on a tile, else a globe. */
function Thumb({ preview }: { preview: LinkPreview | null }) {
  const [imageFailed, setImageFailed] = useState(false);
  const [iconFailed, setIconFailed] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [iconLoaded, setIconLoaded] = useState(false);
  const image = !imageFailed ? preview?.image : null;
  const favicon = !iconFailed ? preview?.favicon : null;
  return (
    <div className="flex shrink-0 items-center justify-center bg-on-surface/6" style={{ width: LINK_PREVIEW_HEIGHT, height: LINK_PREVIEW_HEIGHT }}>
      {image ? (
        <img
          src={image}
          alt=""
          loading="lazy"
          draggable={false}
          onLoad={() => setLoaded(true)}
          onError={() => setImageFailed(true)}
          className={cn("size-full object-cover transition-opacity duration-240 ease-standard", loaded ? "opacity-100" : "opacity-0")}
        />
      ) : favicon ? (
        <img
          src={favicon}
          alt=""
          loading="lazy"
          draggable={false}
          onLoad={() => setIconLoaded(true)}
          onError={() => setIconFailed(true)}
          className={cn("size-[22px] object-contain transition-opacity duration-240 ease-standard", iconLoaded ? "opacity-100" : "opacity-0")}
        />
      ) : (
        <Globe aria-hidden className="size-[22px] text-on-surface-variant" />
      )}
    </div>
  );
}
