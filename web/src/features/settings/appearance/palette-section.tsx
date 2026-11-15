"use client";

import { useState } from "react";
import { Moon, Pencil, Plus, Sun, Trash2 } from "lucide-react";
import { IconButton } from "@/components/common/icon-button";
import { Swatch, SwatchCheck } from "@/components/common/swatch";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useSettings, useSettingsController, type PaletteEntry } from "@/lib/store";
import { normalizeHex } from "@/lib/theme/palette";
import { Field, FormDialog, FormSectionLabel } from "../kit/form-dialog";
import { Hint } from "../kit/rows";
import { useDialog } from "../kit/use-dialog";

// A compact but broad board: Material 200s for light, 900s for dark.
const LIGHT_SWATCHES = ["#F28B82", "#FBBC04", "#FFF475", "#CCFF90", "#A7FFEB", "#AECBFA", "#E8EAED", "#FDCFE8", "#D7AEFB", "#E6C9A8", "#B2EBF2", "#FFCCBC"];
const DARK_SWATCHES = ["#5C2B29", "#614A19", "#635D19", "#345920", "#16504B", "#2D555E", "#3C3F43", "#5B2245", "#42275E", "#442F19", "#1F4E5F", "#6D3B2C"];
const NEW_LIGHT = "#F28B82";
const NEW_DARK = "#5C2B29";

/** The note colours: each with a light and a dark shade, editable and removable. */
export function PaletteSection() {
  const palette = useSettings((s) => s.palette);
  const settings = useSettingsController();
  const editor = useDialog<PaletteEntry | "new">();

  return (
    <>
      <Hint>Personalize the colors available for your notes. Each color has a light-theme and a dark-theme shade.</Hint>
      <ul className="flex flex-col gap-0.5">
        {palette.map((entry) => (
          <li key={entry.key} className="group flex min-h-12 items-center gap-3 rounded-md px-3 py-1.5 transition-colors duration-150 ease-standard hover:bg-hover">
            <button type="button" onClick={() => editor.show(entry)} className="flex min-w-0 flex-1 items-center gap-3 text-left outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50 rounded-md">
              <ShadeChip color={entry.light} shade="light" />
              <ShadeChip color={entry.dark} shade="dark" />
              <span className="truncate text-sm text-on-surface">{entry.name}</span>
            </button>
            <IconButton size="sm" label="Edit color" icon={<Pencil />} onClick={() => editor.show(entry)} />
            <IconButton size="sm" label="Remove color" icon={<Trash2 />} disabled={palette.length <= 1} onClick={() => settings.removePaletteColor(entry.key)} />
          </li>
        ))}
      </ul>
      <div className="flex items-center gap-2 px-1 pt-1">
        <Button variant="ghost" size="sm" onClick={() => editor.show("new")}>
          <Plus aria-hidden />
          Add color
        </Button>
        <span className="flex-1" />
        <Button variant="ghost" size="sm" onClick={() => settings.resetPalette()}>
          Reset to defaults
        </Button>
      </div>
      {editor.value ? (
        <PaletteEditDialog key={editor.key} entry={editor.value === "new" ? null : editor.value} open={editor.open} onOpenChange={editor.onOpenChange} />
      ) : null}
    </>
  );
}

function ShadeChip({ color, shade }: { color: string; shade: "light" | "dark" }) {
  const Icon = shade === "light" ? Sun : Moon;
  return (
    <span aria-hidden className="inline-flex size-7 shrink-0 items-center justify-center rounded-md border border-outline-variant" style={{ background: color }}>
      <Icon className="size-3.5 text-black/35" />
    </span>
  );
}

/** Create (null entry) or edit one palette colour. */
function PaletteEditDialog({ entry, open, onOpenChange }: { entry: PaletteEntry | null; open: boolean; onOpenChange: (open: boolean) => void }) {
  const settings = useSettingsController();
  const [name, setName] = useState(entry?.name ?? "");
  const [light, setLight] = useState(entry?.light ?? NEW_LIGHT);
  const [dark, setDark] = useState(entry?.dark ?? NEW_DARK);

  function save() {
    if (entry === null) {
      settings.addPaletteColor(name, light, dark);
    } else {
      settings.updatePaletteColor(entry.key, { name: name.trim() === "" ? entry.name : name, light, dark });
    }
    onOpenChange(false);
  }

  return (
    <FormDialog
      open={open}
      onOpenChange={onOpenChange}
      title={entry === null ? "Add color" : "Edit color"}
      onSubmit={save}
      footer={
        <>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button onClick={save}>Save</Button>
        </>
      }
    >
      <div className="flex flex-col gap-5">
        <Field label="Name" htmlFor="palette-name">
          <Input id="palette-name" autoFocus value={name} onChange={(e) => setName(e.target.value)} />
        </Field>
        <ShadeEditor label="Light theme shade" color={light} swatches={LIGHT_SWATCHES} onChange={setLight} />
        <ShadeEditor label="Dark theme shade" color={dark} swatches={DARK_SWATCHES} onChange={setDark} />
      </div>
    </FormDialog>
  );
}

function ShadeEditor({ label, color, swatches, onChange }: { label: string; color: string; swatches: readonly string[]; onChange: (hex: string) => void }) {
  const [hex, setHex] = useState(color);
  const same = (a: string): boolean => a.toUpperCase() === color.toUpperCase();
  return (
    <div className="flex flex-col gap-2">
      <FormSectionLabel>{label}</FormSectionLabel>
      <div className="flex items-center gap-3">
        <span aria-hidden className="size-9 shrink-0 rounded-md border border-outline-variant transition-colors duration-150 ease-standard" style={{ background: color }} />
        <Input
          aria-label={`${label} hex`}
          className="w-32 font-mono text-xs"
          value={hex}
          onChange={(e) => {
            setHex(e.target.value);
            const parsed = normalizeHex(e.target.value);
            if (parsed) {
              onChange(parsed);
            }
          }}
        />
      </div>
      <div role="radiogroup" aria-label={label} className="flex flex-wrap gap-2">
        {swatches.map((s) => (
          <Swatch
            key={s}
            label={s}
            size="sm"
            fill={s}
            selected={same(s)}
            onSelect={() => {
              setHex(s);
              onChange(s);
            }}
          >
            {same(s) ? <SwatchCheck className="size-4 text-black/60" /> : null}
          </Swatch>
        ))}
      </div>
    </div>
  );
}
