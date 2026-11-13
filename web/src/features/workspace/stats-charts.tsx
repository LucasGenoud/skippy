"use client";

import type { ReactNode } from "react";
import { motion, useReducedMotion } from "motion/react";
import type { LucideIcon } from "lucide-react";
import { RollingCount } from "@/components/common/rolling-count";
import type { MonthlyActivity } from "@/lib/util/workspace-stats";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";
import { cn } from "@/lib/utils";

// The pieces the statistics page draws with: plain elements, sized as
// fractions and grown in on transforms, no chart library.

/** Series colours, from the theme so they follow the accent. */
export const SERIES_COLORS = ["var(--primary)", "var(--tertiary)", "var(--secondary-tone)", "var(--primary-container)", "var(--outline)"] as const;

export const seriesColor = (index: number): string => SERIES_COLORS[index % SERIES_COLORS.length] ?? "var(--primary)";

const MONTH_INITIALS = ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"];

/** The shortest a bar with anything in it is drawn, so one note never reads as an empty month. */
const BAR_FLOOR = 0.06;

/** How tall a month's bar is, as a fraction of the chart. */
export function monthBarFraction(created: number, busiest: number): number {
  if (busiest === 0 || created === 0) {
    return 0;
  }
  return Math.min(1, created / busiest) * (1 - BAR_FLOOR) + BAR_FLOOR;
}

/** A headline count; the emphasized one wears the accent fill. */
export function StatCard({ icon: Icon, value, label, emphasis }: { icon: LucideIcon; value: number; label: string; emphasis: "primary" | "plain" }) {
  const primary = emphasis === "primary";
  return (
    <div
      className={cn(
        "flex flex-col gap-2 rounded-md px-4 py-3.5",
        primary ? "bg-primary-container text-on-primary-container" : "border border-outline-variant bg-surface-container-low text-on-surface",
      )}
    >
      <Icon aria-hidden className={cn("size-5", primary ? "" : "text-on-surface-variant")} />
      <RollingCount count={value} className="text-2xl leading-8 font-semibold" />
      <span className={cn("text-xs", primary ? "" : "text-on-surface-variant")}>{label}</span>
    </div>
  );
}

export interface Slice {
  readonly label: string;
  readonly count: number;
  readonly color: string;
}

/**
 * A stacked proportion bar with a counted legend. Empty slices keep their
 * legend row (an empty board column is worth seeing) but take no width.
 */
export function Breakdown({ slices, countLabel }: { slices: readonly Slice[]; countLabel?: string }) {
  const reduced = useReducedMotion();
  return (
    <div className="flex flex-col gap-3 px-3">
      <div className="h-2.5 overflow-hidden rounded-md bg-surface-container-highest">
        <motion.div
          className="flex h-full origin-left"
          initial={{ scaleX: 0 }}
          animate={{ scaleX: 1 }}
          transition={transitionFor(TRANSITION.base, reduced)}
        >
          {slices
            .filter((s) => s.count > 0)
            .map((s, i) => (
              <div key={`${s.label}-${i}`} className="h-full" style={{ flexGrow: s.count, background: s.color }} />
            ))}
        </motion.div>
      </div>
      <ul className="flex flex-col gap-1.5">
        {slices.map((s, i) => (
          <li key={`${s.label}-${i}`} className="flex items-center gap-2.5 text-sm">
            <span aria-hidden className="size-2.5 shrink-0 rounded-xs" style={{ background: s.color }} />
            <span className="min-w-0 flex-1 truncate text-on-surface">{s.label}</span>
            <span className="text-on-surface-variant tabular-nums">{countLabel ? `${s.count} ${countLabel}` : s.count}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

/** Notes created each month: a bar per month, its count above, its initial below. */
export function MonthChart({ months, busiest }: { months: readonly MonthlyActivity[]; busiest: number }) {
  const reduced = useReducedMotion();
  return (
    <div role="img" aria-label="Notes created each month" className="flex h-28 items-stretch gap-1">
      {months.map((m) => {
        const fraction = monthBarFraction(m.created, busiest);
        return (
          <div key={m.month.getTime()} className="flex min-w-0 flex-1 flex-col items-center gap-1">
            <span className="h-4 text-2xs text-on-surface-variant tabular-nums">{m.created === 0 ? "" : m.created}</span>
            <div className="relative w-full flex-1">
              <motion.div
                className={cn("absolute inset-x-0.5 bottom-0 origin-bottom rounded-t-xs", m.created === 0 ? "bg-surface-container-highest" : "bg-primary")}
                style={{ height: m.created === 0 ? 3 : `${fraction * 100}%` }}
                initial={{ scaleY: 0 }}
                animate={{ scaleY: 1 }}
                transition={transitionFor(TRANSITION.base, reduced)}
              />
            </div>
            <span className="text-2xs text-on-surface-variant">{MONTH_INITIALS[m.month.getMonth()]}</span>
          </div>
        );
      })}
    </div>
  );
}

/** A labelled figure that is not worth a chart. */
export function FactRow({ icon: Icon, label, value }: { icon: LucideIcon; label: string; value: ReactNode }) {
  return (
    <div className="flex items-center gap-3 px-3 py-1 text-sm">
      <Icon aria-hidden className="size-[18px] text-on-surface-variant" />
      <span className="flex-1 text-on-surface-variant">{label}</span>
      <span className="font-medium text-on-surface">{value}</span>
    </div>
  );
}
