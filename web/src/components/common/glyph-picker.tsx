"use client"

import { useState } from "react"
import { DropletOff, type LucideIcon } from "lucide-react"
import { cn } from "cn"

import { Input } from "@/components/ui/input"
import { ACCENT_PRESETS } from "@/lib/theme/accent"
import { hexToRgb, isDarkColor } from "@/lib/theme/color"
import { DEFAULT_LABEL_ICON, LABEL_ICONS, labelColor } from "@/lib/theme/label-style"
import { normalizeHex } from "@/lib/theme/palette"

import { SectionLabel } from "./section-label"
import { Swatch, SwatchCheck } from "./swatch"

/**
 * A label's (or smart view's, or collection's) colour row: a "default" slot
 * and the accent presets. The check takes white or ink to suit the fill.
 */
export function GlyphColorRow({ value, onChange }: { value: string | null; onChange: (hex: string | null) => void }) {
  const current = labelColor(value)
  return (
    <div role="radiogroup" aria-label="Color" className="flex flex-wrap gap-2.5">
      <Swatch label="Default" size="sm" ring="strong" selected={current === null} fill="var(--surface-container-highest)" onSelect={() => onChange(null)}>
        {current === null ? <SwatchCheck className="size-4 text-on-surface-variant" /> : <DropletOff aria-hidden className="size-4 text-on-surface-variant" />}
      </Swatch>
      {ACCENT_PRESETS.map(({ hex, name }) => {
        const rgb = hexToRgb(hex)
        const selected = current === hex
        return (
          <Swatch key={hex} label={name} size="sm" ring="strong" selected={selected} fill={hex} onSelect={() => onChange(hex)}>
            {selected ? <SwatchCheck className="size-4" color={rgb && isDarkColor(rgb) ? "#FFFFFF" : "#1B1A16"} /> : null}
          </Swatch>
        )
      })}
    </div>
  )
}

/** The curated icon grid, with a leading slot that clears the custom icon. */
export function IconGrid({
  value,
  onChange,
  tint,
  defaultIcon: DefaultIcon = DEFAULT_LABEL_ICON,
}: {
  value: string | null
  onChange: (key: string | null) => void
  /** "#RRGGBB" the selected cell takes; null uses the muted text colour. */
  tint?: string | null
  defaultIcon?: LucideIcon
}) {
  const color = labelColor(tint) ?? "var(--on-surface-variant)"
  const cells: { key: string | null; Icon: LucideIcon; name: string }[] = [
    { key: null, Icon: DefaultIcon, name: "Default icon" },
    ...Object.entries(LABEL_ICONS).map(([key, Icon]) => ({ key, Icon, name: key })),
  ]
  return (
    <div role="radiogroup" aria-label="Icon" className="flex flex-wrap gap-2">
      {cells.map(({ key, Icon, name }) => {
        const selected = value === key
        return (
          <button
            key={key ?? "default"}
            type="button"
            role="radio"
            aria-checked={selected}
            aria-label={name}
            onClick={() => onChange(key)}
            className={cn(
              "inline-flex size-10 items-center justify-center rounded-md text-on-surface transition-[background-color,box-shadow,color] duration-150 ease-standard outline-none hover:bg-hover focus-visible:ring-[3px] focus-visible:ring-ring/50",
            )}
            style={
              selected
                ? { color, boxShadow: `inset 0 0 0 2px ${color}`, backgroundColor: `color-mix(in srgb, ${color} 18%, transparent)` }
                : { boxShadow: "inset 0 0 0 1px var(--outline-variant)" }
            }
          >
            <Icon aria-hidden className="size-5" />
          </button>
        )
      })}
    </div>
  )
}

/**
 * Colour, an optional custom hex, and icon: the glyph vocabulary labels,
 * smart views and collections share, so the three never drift apart.
 */
export function GlyphPicker({
  color,
  onColorChange,
  icon,
  onIconChange,
  defaultIcon,
  customHex = "shown",
}: {
  color: string | null
  onColorChange: (hex: string | null) => void
  icon: string | null
  onIconChange: (key: string | null) => void
  defaultIcon?: LucideIcon
  customHex?: "shown" | "hidden"
}) {
  const [draft, setDraft] = useState(color ?? "")
  const [lastColor, setLastColor] = useState(color)
  if (color !== lastColor) {
    setLastColor(color)
    setDraft(color ?? "")
  }

  return (
    <div className="flex flex-col gap-5">
      <div className="flex flex-col gap-2.5">
        <SectionLabel className="px-0">Color</SectionLabel>
        <GlyphColorRow value={color} onChange={onColorChange} />
        {customHex === "shown" ? (
          <Input
            aria-label="Custom hex"
            placeholder="#RRGGBB"
            value={draft}
            className="w-36 font-mono text-xs"
            onChange={(event) => {
              const text = event.target.value
              setDraft(text)
              const parsed = normalizeHex(text)
              if (parsed) {
                onColorChange(parsed)
              } else if (!text.trim()) {
                onColorChange(null)
              }
            }}
          />
        ) : null}
      </div>
      <div className="flex flex-col gap-2.5">
        <SectionLabel className="px-0">Icon</SectionLabel>
        <IconGrid value={icon} onChange={onIconChange} tint={color} defaultIcon={defaultIcon} />
      </div>
    </div>
  )
}
