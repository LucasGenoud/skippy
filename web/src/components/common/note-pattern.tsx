import { cn } from "cn"

import { patternStyle, type NotePatternId } from "@/lib/theme/patterns"

/**
 * Draws a note's background pattern behind its content, in --pattern-ink.
 * Place it first inside a `relative` card or editor; content after it paints
 * on top. One element with a memoized mask; "none" renders nothing.
 */
export function NotePattern({ pattern, className }: { pattern: NotePatternId; className?: string }) {
  const style = patternStyle(pattern)
  if (!style) {
    return null
  }
  return <div aria-hidden className={cn("pointer-events-none absolute inset-0 rounded-[inherit]", className)} style={style} />
}
