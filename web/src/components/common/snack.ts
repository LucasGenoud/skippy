// Brief, non-blocking notifications (`util/snack.dart`), drawn by the
// <Toaster /> from components/ui/sonner.tsx, which the app mounts once.
//
// Reserve these for failures that need attention, destructive changes (with
// Undo), and significant background work. Routine optimistic actions are
// already visible in the interface and raise nothing. Only one shows at a
// time: a new one replaces the current one.

import { createElement } from "react"
import type { LucideIcon } from "lucide-react"
import { toast } from "sonner"

/** Drives the tint of the leading icon chip. */
export type SnackKind = "normal" | "success" | "warning" | "danger"

export interface SnackOptions {
  /** A trailing button, e.g. "Retry". Keeps the snack up a little longer. */
  action?: { label: string; onClick: () => void }
  /** Shorthand for an "Undo" action. */
  undo?: () => void
  icon?: LucideIcon
  kind?: SnackKind
}

const DURATION_MS = 3000
const ACTION_DURATION_MS = 5000

const CHIP: Record<SnackKind, string> = {
  normal: "bg-secondary-container text-on-secondary-container",
  success: "bg-(--snack-success-bg) text-(--snack-success-fg)",
  warning: "bg-(--snack-warning-bg) text-(--snack-warning-fg)",
  danger: "bg-error-container text-on-error-container",
}

/** Shows `message` as the one toast on screen. Returns its id. */
export function showAppSnack(message: string, options: SnackOptions = {}): string | number {
  const { undo, icon, kind = "normal" } = options
  const action = options.action ?? (undo ? { label: "Undo", onClick: undo } : undefined)

  toast.dismiss()
  return toast(message, {
    duration: action ? ACTION_DURATION_MS : DURATION_MS,
    closeButton: true,
    icon: icon ? createElement(icon, { "aria-hidden": true }) : undefined,
    classNames: icon ? { icon: CHIP[kind] } : undefined,
    action: action
      ? {
          label: action.label,
          onClick: () => action.onClick(),
        }
      : undefined,
  })
}
