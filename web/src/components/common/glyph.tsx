import { memo } from "react"

import type { GlyphNode } from "@/lib/theme/motif-glyphs"
import { glyphMarkup } from "@/lib/theme/patterns"

/** A motif glyph (lucide drawing data) as an inline icon in currentColor. */
export const Glyph = memo(function Glyph({
  nodes,
  size = 20,
  className,
}: {
  nodes: readonly GlyphNode[]
  size?: number
  className?: string
}) {
  return (
    <svg
      aria-hidden
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={2}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      // Static, trusted drawing data from motif-glyphs.ts.
      dangerouslySetInnerHTML={{ __html: glyphMarkup(nodes) }}
    />
  )
})
