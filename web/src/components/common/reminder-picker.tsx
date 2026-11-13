"use client"

import { useLayoutEffect, useRef, useState, type ReactNode } from "react"
import { ArrowLeft, CalendarDays, Trash2 } from "lucide-react"
import { AnimatePresence, motion, useReducedMotion } from "motion/react"

import { Button } from "@/components/ui/button"
import { Calendar } from "@/components/ui/calendar"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { TRANSITION, transitionFor } from "@/lib/theme/motion"

import {
  formatWhen,
  REPEAT_LABELS,
  reminderPresets,
  type ReminderRepeat,
  type ReminderValue,
} from "./reminder-format"

export type { ReminderRepeat, ReminderValue } from "./reminder-format"

type View = "quick" | "custom"

const NO_REPEAT = "none"
const MAX_YEARS_AHEAD = 5
const pad = (n: number): string => String(n).padStart(2, "0")

function startOfDay(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate())
}

// Grows and shrinks with its content instead of jumping when the view swaps.
function MeasuredHeight({ children }: { children: ReactNode }) {
  const inner = useRef<HTMLDivElement>(null)
  const [height, setHeight] = useState<number | "auto">("auto")
  const reduced = useReducedMotion()

  useLayoutEffect(() => {
    const element = inner.current
    if (!element || typeof ResizeObserver === "undefined") {
      return
    }
    const observer = new ResizeObserver(() => setHeight(element.offsetHeight))
    observer.observe(element)
    return () => observer.disconnect()
  }, [])

  return (
    // The inset keeps focus rings at the edges from being clipped.
    <motion.div animate={{ height }} transition={transitionFor(TRANSITION.base, reduced)} className="-m-1 overflow-hidden">
      <div ref={inner} className="p-1">
        {children}
      </div>
    </motion.div>
  )
}

/**
 * Everything a time reminder can be, on one surface (`ReminderPicker`): quick
 * presets, a custom date and time, how it repeats, and removing it. A preset
 * applies at once; the custom view applies on "Save reminder". Callers place
 * it in a Popover or Dialog and close it from `onChange`. No place reminders
 * on the web.
 */
export function ReminderPicker({
  value,
  onChange,
  now: nowProp,
  use24h,
}: {
  value: ReminderValue | null
  onChange: (value: ReminderValue | null) => void
  /** The moment presets count from. Defaults to when the picker opened. */
  now?: Date
  use24h?: boolean
}) {
  const reduced = useReducedMotion()
  const [opened] = useState(() => nowProp ?? new Date())
  const now = nowProp ?? opened
  const [view, setView] = useState<View>("quick")
  const [repeat, setRepeat] = useState<ReminderRepeat | undefined>(value?.repeat)
  const [custom, setCustom] = useState<Date>(() =>
    value && value.at.getTime() > now.getTime() ? value.at : now,
  )

  const choose = (at: Date): void => onChange(repeat ? { at, repeat } : { at })
  const swap = transitionFor(TRANSITION.fast, reduced)
  const lastDay = new Date(now.getFullYear() + MAX_YEARS_AHEAD, now.getMonth(), now.getDate())

  const quick = (
    <div className="flex flex-col gap-3">
      <div className="text-sm font-medium text-on-surface">Quick add</div>
      <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
        {reminderPresets(now).map((preset) => (
          <button
            key={preset.id}
            type="button"
            onClick={() => choose(preset.at)}
            className="flex flex-col items-start gap-0.5 rounded-md border border-outline-variant bg-surface px-3 py-2.5 text-left transition-colors duration-150 ease-standard outline-none hover:bg-hover active:bg-pressed focus-visible:ring-[3px] focus-visible:ring-ring/50"
          >
            <span className="text-sm text-on-surface">{preset.label}</span>
            <span className="text-xs text-on-surface-variant">{formatWhen(preset.at, { now, use24h })}</span>
          </button>
        ))}
      </div>
      <Button variant="outline" onClick={() => setView("custom")}>
        <CalendarDays />
        Custom date &amp; time
      </Button>
    </div>
  )

  const customView = (
    <div className="flex flex-col gap-3">
      <Button variant="ghost" size="sm" className="self-start" onClick={() => setView("quick")}>
        <ArrowLeft />
        Quick reminder options
      </Button>
      <div className="flex items-center gap-3">
        <Label htmlFor="reminder-time" className="text-on-surface-variant">
          At
        </Label>
        <Input
          id="reminder-time"
          type="time"
          className="w-32"
          value={`${pad(custom.getHours())}:${pad(custom.getMinutes())}`}
          onChange={(event) => {
            const [hours, minutes] = event.target.value.split(":").map(Number)
            if (hours === undefined || minutes === undefined || Number.isNaN(hours) || Number.isNaN(minutes)) {
              return
            }
            setCustom(new Date(custom.getFullYear(), custom.getMonth(), custom.getDate(), hours, minutes))
          }}
        />
      </div>
      <Calendar
        mode="single"
        selected={custom}
        defaultMonth={custom}
        required
        disabled={{ before: startOfDay(now), after: lastDay }}
        onSelect={(date: Date | undefined) => {
          if (date) {
            setCustom(new Date(date.getFullYear(), date.getMonth(), date.getDate(), custom.getHours(), custom.getMinutes()))
          }
        }}
        className="self-center p-0"
      />
      <Button onClick={() => choose(custom)}>Save reminder</Button>
    </div>
  )

  return (
    <div className="flex flex-col gap-4">
      {value ? (
        <p className="text-xs text-on-surface-variant">Currently {formatWhen(value.at, { now, use24h })}</p>
      ) : null}
      <div className="flex flex-col gap-1.5">
        <Label className="text-xs text-on-surface-variant">Repeat</Label>
        <Select
          value={repeat ?? NO_REPEAT}
          onValueChange={(next) => setRepeat(next === NO_REPEAT ? undefined : (next as ReminderRepeat))}
        >
          <SelectTrigger className="w-full">
            <SelectValue />
          </SelectTrigger>
          <SelectContent position="popper">
            <SelectItem value={NO_REPEAT}>Does not repeat</SelectItem>
            {(Object.keys(REPEAT_LABELS) as ReminderRepeat[]).map((key) => (
              <SelectItem key={key} value={key}>
                {REPEAT_LABELS[key]}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
      <MeasuredHeight>
        <AnimatePresence mode="wait" initial={false}>
          <motion.div
            key={view}
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={swap}
          >
            {view === "quick" ? quick : customView}
          </motion.div>
        </AnimatePresence>
      </MeasuredHeight>
      {value ? (
        <Button variant="ghost" className="self-start text-error hover:text-error" onClick={() => onChange(null)}>
          <Trash2 />
          Remove reminder
        </Button>
      ) : null}
    </div>
  )
}
