import type { ReactNode } from "react"

import { CrossFade } from "./reveal"

/**
 * The title block a destination opens with: Reminders, Archive, Trash.
 *
 *   Title                                  [trailing]
 *   subtitle
 *
 * Inset a touch from the cards' edge, like a section label. Pass no title
 * where the top bar already names the view. The subtitle cross-fades.
 */
export function PageHeader({
  title,
  subtitle,
  trailing,
}: {
  title?: string
  subtitle?: string
  trailing?: ReactNode
}) {
  return (
    <header className="flex items-center gap-3 pt-4 pb-1 pl-2">
      <div className="min-w-0 flex-1">
        {title ? <h1 className="truncate text-2xl leading-8 font-semibold tracking-tight text-on-surface">{title}</h1> : null}
        {subtitle ? (
          <CrossFade stateKey={subtitle} className="mt-0.5 text-xs text-on-surface-variant">
            {subtitle}
          </CrossFade>
        ) : null}
      </div>
      {trailing}
    </header>
  )
}
