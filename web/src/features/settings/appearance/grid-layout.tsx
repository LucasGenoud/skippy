"use client";

import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { LayoutGrid, Scan } from "lucide-react";
import { GRID_DENSITIES, GRID_WIDTHS, useSettings, useSettingsController, type GridDensity, type GridWidth } from "@/lib/store";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";
import { SettingsRow } from "../kit/rows";
import { Segmented } from "../kit/segmented";

/** A representative large desktop the settings map onto for the preview. */
const REFERENCE_SCREEN = 1920;
const MIN_COLUMNS = 2;
/** Varied heights so a column reads as stacked notes, not a solid bar. */
const HEIGHTS = [0.62, 1.0, 0.5, 0.85, 0.7, 0.95, 0.55, 0.8];
const UNIT_PX = 22;

/** How many columns and how wide a band the preview draws. */
export function gridPreviewShape(density: GridDensity, width: GridWidth): { columns: number; widthFraction: number } {
  const d = GRID_DENSITIES.find((g) => g.id === density) ?? GRID_DENSITIES[1];
  const w = GRID_WIDTHS.find((g) => g.id === width) ?? GRID_WIDTHS[1];
  const effective = Math.min(w.maxWidth, REFERENCE_SCREEN);
  const columns = Math.min(d.maxColumns, Math.max(MIN_COLUMNS, Math.floor(effective / d.targetWidth)));
  return { columns, widthFraction: effective / REFERENCE_SCREEN };
}

/** Card density, how wide the centred grid grows, and a live miniature of both. */
export function GridLayoutSection() {
  const settings = useSettingsController();
  const density = useSettings((s) => s.gridDensity);
  const width = useSettings((s) => s.gridWidth);
  const blurb = GRID_DENSITIES.find((d) => d.id === density)?.blurb ?? "";

  return (
    <>
      <SettingsRow icon={LayoutGrid} title="Grid density" subtitle={blurb} />
      <div className="px-3 pb-2 pl-12">
        <Segmented
          label="Grid density"
          value={density}
          onChange={(v) => settings.setGridDensity(v)}
          options={GRID_DENSITIES.map((d) => ({ value: d.id, label: d.label }))}
        />
      </div>
      <SettingsRow icon={Scan} title="Content width" subtitle="How wide the grid grows on large screens" />
      <div className="px-3 pb-2 pl-12">
        <Segmented
          label="Content width"
          value={width}
          onChange={(v) => settings.setGridWidth(v)}
          options={GRID_WIDTHS.map((w) => ({ value: w.id, label: w.label }))}
        />
      </div>
      <div className="px-3 pt-1 pb-2 pl-12">
        <GridPreview density={density} width={width} />
      </div>
    </>
  );
}

function GridPreview({ density, width }: { density: GridDensity; width: GridWidth }) {
  const reduced = useReducedMotion();
  const { columns, widthFraction } = gridPreviewShape(density, width);
  return (
    <div aria-hidden className="flex h-[88px] justify-center overflow-hidden rounded-md border border-outline-variant bg-surface-container-highest/40 py-2.5">
      <motion.div className="relative h-full" initial={false} animate={{ width: `${widthFraction * 100}%` }} transition={transitionFor(TRANSITION.base, reduced)}>
        <AnimatePresence initial={false}>
          <motion.div
            key={columns}
            className="absolute inset-0 flex items-start gap-1"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={transitionFor(TRANSITION.base, reduced)}
          >
            {Array.from({ length: columns }, (_, c) => (
              <div key={c} className="flex min-w-0 flex-1 flex-col gap-1">
                {[c * 2, c * 2 + 1].map((i) => (
                  <div key={i} className="rounded-xs bg-primary/50" style={{ height: UNIT_PX * (HEIGHTS[i % HEIGHTS.length] ?? 1) }} />
                ))}
              </div>
            ))}
          </motion.div>
        </AnimatePresence>
      </motion.div>
    </div>
  );
}
