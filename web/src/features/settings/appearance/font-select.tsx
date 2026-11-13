"use client";

import { Type } from "lucide-react";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { APP_FONTS, useSettings, useSettingsController, type AppFont } from "@/lib/store";
import { fontStack, appFont } from "@/lib/theme/fonts";

const PREVIEW_WEIGHT = 400;

/** Starts loading every face so each option previews in its own. */
function preloadFaces(): void {
  for (const font of APP_FONTS) {
    if (font.family) {
      void document.fonts.load(`${PREVIEW_WEIGHT} 1em "${font.family}"`).catch(() => undefined);
    }
  }
}

/** The typeface the whole app is set in; each option is drawn in its own face. */
export function FontSelect() {
  const font = useSettings((s) => s.font);
  const settings = useSettingsController();
  return (
    <div className="flex items-center gap-4 px-3 py-2.5">
      <Type aria-hidden className="size-5 shrink-0 text-on-surface-variant" />
      <label htmlFor="settings-font" className="flex-1 text-sm text-on-surface">
        Font
      </label>
      <Select value={font} onValueChange={(v) => settings.setFont(v as AppFont)} onOpenChange={(open) => open && preloadFaces()}>
        <SelectTrigger id="settings-font" className="w-48">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {APP_FONTS.map((f) => (
            <SelectItem key={f.id} value={f.id} style={{ fontFamily: fontStack(appFont(f.id)) }}>
              {f.label}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </div>
  );
}
