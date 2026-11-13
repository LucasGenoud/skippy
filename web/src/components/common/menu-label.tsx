import { cn } from "cn"

import { menuDescription } from "@/components/ui/surface-styles"

/**
 * A menu entry's text: what it is, and a few grey words on what it does, on
 * one line. The hint gives way first when the menu is narrow.
 *
 *   Duplicate  Make a copy
 *   Delete     Move to trash
 *
 * Put it inside a DropdownMenuItem / ContextMenuItem after the icon.
 */
export function MenuLabel({
  label,
  hint,
  tone = "default",
}: {
  label: string
  hint?: string
  /** "destructive" tints the label, for an entry like Delete. */
  tone?: "default" | "destructive"
}) {
  return (
    <span className="flex min-w-0 flex-1 items-baseline gap-2">
      <span className={cn("min-w-0 flex-[3_1_auto] truncate", tone === "destructive" && "text-error")}>{label}</span>
      {hint ? <span className={menuDescription}>{hint}</span> : null}
    </span>
  )
}
