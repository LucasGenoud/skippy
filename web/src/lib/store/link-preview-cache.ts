import type { Api } from "@/lib/api/client";
import type { LinkPreview } from "@/lib/models/misc";

// Session-scoped memoizer for link-preview unfurls: every distinct URL is
// fetched at most once, and every card showing it shares one promise. Ported
// from `state/link_preview_cache.dart`. Resolved values are also kept so a
// component can read them synchronously on its next render.
export class LinkPreviewCache {
  private readonly inFlight = new Map<string, Promise<LinkPreview | null>>();
  private readonly resolved = new Map<string, LinkPreview | null>();

  constructor(private readonly api: Api) {}

  /** The preview for [url], fetching (and caching) on first request. */
  preview(url: string): Promise<LinkPreview | null> {
    let pending = this.inFlight.get(url);
    if (!pending) {
      pending = this.api.unfurl(url).then(
        (preview) => {
          this.resolved.set(url, preview);
          return preview;
        },
        () => {
          this.resolved.set(url, null);
          return null;
        },
      );
      this.inFlight.set(url, pending);
    }
    return pending;
  }

  /** The preview if it has already resolved; undefined while unknown. */
  peek(url: string): LinkPreview | null | undefined {
    return this.resolved.has(url) ? (this.resolved.get(url) ?? null) : undefined;
  }
}
