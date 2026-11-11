"use client"

import { DropletOff } from "lucide-react"

import type { Brightness } from "@/lib/theme/accent"
import { DEFAULT_NOTE_COLOR, DEFAULT_PALETTE, noteColor, type PaletteEntry } from "@/lib/theme/palette"
import { motifGlyph, NOTE_PATTERNS, type NotePatternId } from "@/lib/theme/patterns"

import { Glyph } from "./glyph"
import { NotePattern } from "./note-pattern"
import { SectionLabel } from "./section-label"
import { Swatch, SwatchCheck } from "./swatch"

/**
 * The note colours (the user's palette, "Default" first) as a wrapping row of
 * swatches in the current brightness. Selection updates live.
 */
export function ColorPicker({
  value,
  onChange,
  brightness,
  palette = DEFAULT_PALETTE,
}: {
  /** The selected palette key; "default" is the plain surface. */
  value: string
  onChange: (key: string) => void
  brightness: Brightness
  palette?: readonly PaletteEntry[]
}) {
  const entries = [{ key: DEFAULT_NOTE_COLOR, name: "Default" }, ...palette]
  return (
    <div role="radiogroup" aria-label="Note color" className="flex flex-wrap gap-3">
      {entries.map((entry) => {
        const selected = entry.key === value
        const fill = noteColor(entry.key, brightness, palette)
        return (
          <Swatch key={entry.key} label={entry.name} selected={selected} fill={fill} onSelect={() => onChange(entry.key)}>
            {selected ? (
              <SwatchCheck className="text-primary" />
            ) : fill === null ? (
              <DropletOff aria-hidden className="size-[18px] text-on-surface-variant" />
            ) : null}
          </Swatch>
        )
      })}
    </div>
  )
}

/**
 * The background patterns as swatches drawn on the note's own fill. A motif
 * shows its picture instead of a scatter, which reads at this size.
 */
export function PatternPicker({
  value,
  onChange,
  fill,
}: {
  value: NotePatternId
  onChange: (pattern: NotePatternId) => void
  /** The note's CSS fill behind each swatch; null is the surface. */
  fill?: string | null
}) {
  return (
    <div role="radiogroup" aria-label="Pattern" className="flex flex-wrap gap-3">
      {NOTE_PATTERNS.map(({ id, label }) => {
        const selected = id === value
        const glyph = motifGlyph(id)
        return (
          <Swatch key={id} label={label} selected={selected} fill={fill} onSelect={() => onChange(id)}>
            {glyph ? null : <NotePattern pattern={id} />}
            {selected ? (
              <SwatchCheck className="text-primary" />
            ) : glyph ? (
              <Glyph nodes={glyph} className="relative text-on-surface/45" />
            ) : null}
          </Swatch>
        )
      })}
    </div>
  )
}

/** Colour and pattern together, as the note's Background surface shows them. */
export function BackgroundPicker({
  color,
  onColorChange,
  pattern,
  onPatternChange,
  brightness,
  palette = DEFAULT_PALETTE,
}: {
  color: string
  onColorChange: (key: string) => void
  pattern: NotePatternId
  onPatternChange: (pattern: NotePatternId) => void
  brightness: Brightness
  palette?: readonly PaletteEntry[]
}) {
  return (
    <div className="flex flex-col gap-4">
      <ColorPicker value={color} onChange={onColorChange} brightness={brightness} palette={palette} />
      <div className="flex flex-col gap-2.5">
        <SectionLabel className="px-0">Pattern</SectionLabel>
        <PatternPicker value={pattern} onChange={onPatternChange} fill={noteColor(color, brightness, palette)} />
      </div>
    </div>
  )
}
