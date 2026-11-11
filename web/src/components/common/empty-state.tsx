"use client"

import { Plus, type LucideIcon } from "lucide-react"
import { motion, useReducedMotion } from "motion/react"

import { Button } from "@/components/ui/button"
import { TRANSITION, transitionFor } from "@/lib/theme/motion"

import { AppLogo } from "./app-logo"

const RISE_PX = 16
const MARK_SIZE = 72

/**
 * What an empty view shows: a large quiet icon (or the logo), one line, and an
 * optional action. It settles in with a fade and a short rise, replayed when
 * the content changes (Trash to Archive).
 */
export function EmptyState({
  icon: Icon,
  message,
  actionLabel,
  onAction,
  actionIcon: ActionIcon = Plus,
  mark = "icon",
}: {
  icon: LucideIcon
  message: string
  actionLabel?: string
  onAction?: () => void
  actionIcon?: LucideIcon
  /** "logo" shows the brand mark instead of the icon. */
  mark?: "icon" | "logo"
}) {
  const reduced = useReducedMotion()
  return (
    <div className="flex h-full min-h-60 items-center justify-center p-6">
      <motion.div
        key={message}
        className="flex max-w-sm flex-col items-center text-center"
        initial={{ opacity: 0, y: RISE_PX }}
        animate={{ opacity: 1, y: 0 }}
        transition={transitionFor(TRANSITION.slow, reduced)}
      >
        {mark === "logo" ? (
          <AppLogo size={MARK_SIZE} />
        ) : (
          <Icon aria-hidden className="size-[72px] text-on-surface-variant/35" strokeWidth={1.25} />
        )}
        <p className="mt-4 text-base leading-6 font-medium text-on-surface-variant">{message}</p>
        {actionLabel && onAction ? (
          <Button className="mt-3" onClick={onAction}>
            <ActionIcon />
            {actionLabel}
          </Button>
        ) : null}
      </motion.div>
    </div>
  )
}
