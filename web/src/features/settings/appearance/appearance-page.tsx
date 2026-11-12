"use client";

import { CalendarDays, Clock, SunMoon } from "lucide-react";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { DATE_FORMATS, formatClock, formatDate, useSettings, useSettingsController, type AppDateFormat, type ThemeMode } from "@/lib/store";
import { SettingsRow, SettingsSection } from "../kit/rows";
import { Segmented } from "../kit/segmented";
import { AccentColorRow } from "./accent-color";
import { FontSelect } from "./font-select";
import { GridLayoutSection } from "./grid-layout";
import { PaletteSection } from "./palette-section";

const THEME_OPTIONS: readonly { value: ThemeMode; label: string }[] = [
  { value: "system", label: "Auto" },
  { value: "light", label: "Light" },
  { value: "dark", label: "Dark" },
];

const CLOCK_OPTIONS = [
  { value: "12", label: "12h" },
  { value: "24", label: "24h" },
] as const;

export function AppearancePage() {
  const settings = useSettingsController();
  const themeMode = useSettings((s) => s.themeMode);
  const dateFormat = useSettings((s) => s.dateFormat);
  const use24h = useSettings((s) => s.use24hTime);
  const now = new Date();

  return (
    <>
      <SettingsSection title="Theme">
        <SettingsRow
          icon={SunMoon}
          title="Theme"
          trailing={<Segmented label="Theme" value={themeMode} onChange={(v) => settings.setThemeMode(v)} options={THEME_OPTIONS} />}
        />
        <AccentColorRow />
        <FontSelect />
      </SettingsSection>
      <SettingsSection title="Notes grid">
        <GridLayoutSection />
      </SettingsSection>
      <SettingsSection title="Note colors">
        <PaletteSection />
      </SettingsSection>
      <SettingsSection title="Date & time">
        <div className="flex items-center gap-4 px-3 py-2.5">
          <CalendarDays aria-hidden className="size-5 shrink-0 text-on-surface-variant" />
          <span className="flex min-w-0 flex-1 flex-col">
            <label htmlFor="settings-date-format" className="text-sm text-on-surface">
              Date format
            </label>
            <span className="text-xs text-on-surface-variant">Today: {formatDate(now, dateFormat)}</span>
          </span>
          <Select value={dateFormat} onValueChange={(v) => settings.setDateFormat(v as AppDateFormat)}>
            <SelectTrigger id="settings-date-format" className="w-44 sm:w-56">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {DATE_FORMATS.map((f) => (
                <SelectItem key={f.id} value={f.id}>
                  {f.label} ({f.example})
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <SettingsRow
          icon={Clock}
          title="Time format"
          subtitle={`Now: ${formatClock(now, use24h)}`}
          trailing={<Segmented label="Time format" value={use24h ? "24" : "12"} onChange={(v) => settings.setUse24hTime(v === "24")} options={CLOCK_OPTIONS} />}
        />
      </SettingsSection>
    </>
  );
}
