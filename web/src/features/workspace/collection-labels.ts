import { Columns3, LayoutDashboard, Rows3, type LucideIcon } from "lucide-react";
import type { CollectionLayout, CollectionSort } from "@/lib/models";

// How collections are named in settings: layouts and default sorts.

export const LAYOUT_OPTIONS: readonly { value: CollectionLayout; label: string; icon: LucideIcon }[] = [
  { value: "masonry", label: "Masonry", icon: LayoutDashboard },
  { value: "list", label: "List", icon: Rows3 },
  { value: "board", label: "Board", icon: Columns3 },
];

export const SORT_OPTIONS: readonly { value: CollectionSort; label: string }[] = [
  { value: "custom", label: "Custom order" },
  { value: "edited", label: "Last edited" },
  { value: "newest", label: "Newest first" },
  { value: "oldest", label: "Oldest first" },
];

/** A stored layout's name; unknown layouts read as masonry, as they render. */
export function layoutLabel(layout: string): string {
  return LAYOUT_OPTIONS.find((o) => o.value === layout)?.label ?? "Masonry";
}

/** Spacing between new collections' positions, as the Flutter client writes them. */
export const COLLECTION_POSITION_STEP = 1024;
