"use client";

import { useState } from "react";
import { Palette, Plus } from "lucide-react";
import { Swatch, SwatchCheck } from "@/components/common/swatch";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useSettings, useSettingsController } from "@/lib/store";
import { ACCENT_BOARD, ACCENT_PRESETS, accentPreview } from "@/lib/theme/accent";
import { hexToRgb, isDarkColor } from "@/lib/theme/color";
import { normalizeHex } from "@/lib/theme/palette";
import { FormDialog } from "../kit/form-dialog";
import { useBrightness } from "@/lib/theme/use-brightness";
import { useDialog } from "../kit/use-dialog";

const checkColor = (hex: string): string => {
  const rgb = hexToRgb(hex);
  return rgb && isDarkColor(rgb) ? "#FFFFFF" : "#1B1A16";
};

const sameHex = (a: string, b: string): boolean => a.toUpperCase() === b.toUpperCase();

/** Preset seeds plus a custom slot; a non-preset accent sits in the custom slot, selected. */
export function AccentColorRow() {
  const accent = useSettings((s) => s.accentColor);
  const settings = useSettingsController();
  const custom = useDialog();
  const isPreset = ACCENT_PRESETS.some((p) => sameHex(p.hex, accent));

  return (
    <div className="flex items-start gap-4 px-3 py-2.5">
      <Palette aria-hidden className="mt-0.5 size-5 shrink-0 text-on-surface-variant" />
      <div className="flex min-w-0 flex-1 flex-col gap-3">
        <span className="text-sm text-on-surface">Accent color</span>
        <div role="radiogroup" aria-label="Accent color" className="flex flex-wrap gap-2.5">
          {ACCENT_PRESETS.map(({ hex, name }) => {
            const selected = sameHex(hex, accent);
            return (
              <Swatch key={hex} label={name} size="sm" ring="strong" fill={hex} selected={selected} onSelect={() => settings.setAccentColor(hex)}>
                {selected ? <SwatchCheck className="size-4" color={checkColor(hex)} /> : null}
              </Swatch>
            );
          })}
          <Swatch
            label="Custom…"
            size="sm"
            ring="strong"
            fill={isPreset ? "var(--surface-container-highest)" : accent}
            selected={!isPreset}
            onSelect={() => custom.show(true)}
          >
            {isPreset ? <Plus aria-hidden className="size-4 text-on-surface-variant" /> : <SwatchCheck className="size-4" color={checkColor(accent)} />}
          </Swatch>
        </div>
      </div>
      <CustomAccentDialog key={custom.key} initial={accent} open={custom.open} onOpenChange={custom.onOpenChange} />
    </div>
  );
}

/** Any accent by swatch or hex, with a preview of the toned accent it produces. */
function CustomAccentDialog({ initial, open, onOpenChange }: { initial: string; open: boolean; onOpenChange: (open: boolean) => void }) {
  const settings = useSettingsController();
  const brightness = useBrightness();
  const [color, setColor] = useState(normalizeHex(initial) ?? initial);
  const [hex, setHex] = useState(color);

  function select(next: string) {
    setColor(next);
    setHex(next);
  }

  function apply() {
    settings.setAccentColor(color);
    onOpenChange(false);
  }

  return (
    <FormDialog
      open={open}
      onOpenChange={onOpenChange}
      title="Custom accent"
      width="compact"
      onSubmit={apply}
      footer={
        <>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button onClick={apply}>Use color</Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        <div className="flex items-center gap-3">
          <span
            aria-hidden
            className="inline-flex size-10 shrink-0 items-center justify-center rounded-md transition-colors duration-150 ease-standard"
            style={{ background: accentPreview(color, brightness), color: brightness === "dark" ? "#000000" : "#FFFFFF" }}
          >
            <Plus className="size-5" />
          </span>
          <span className="text-xs text-on-surface-variant">Preview of the accent this seed produces.</span>
        </div>
        <div role="radiogroup" aria-label="Colors" className="flex flex-wrap gap-2">
          {ACCENT_BOARD.map((c) => (
            <Swatch key={c} label={c} size="sm" ring="strong" fill={c} selected={sameHex(c, color)} onSelect={() => select(c)}>
              {sameHex(c, color) ? <SwatchCheck className="size-4" color={checkColor(c)} /> : null}
            </Swatch>
          ))}
        </div>
        <Input
          aria-label="Hex"
          className="w-36 font-mono text-xs"
          value={hex}
          placeholder="#RRGGBB"
          onChange={(e) => {
            setHex(e.target.value);
            const parsed = normalizeHex(e.target.value);
            if (parsed) {
              setColor(parsed);
            }
          }}
        />
      </div>
    </FormDialog>
  );
}
