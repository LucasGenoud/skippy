"use client";

import { useId, type ComponentProps, type ReactNode } from "react";
import type { LucideIcon } from "lucide-react";
import { cn } from "cn";
import { Reveal } from "@/components/common/reveal";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { LabelIcon, labelStyle } from "@/lib/theme/label-style";

/** A labelled text field with an error line that grows in under it. */
export function TextField({
  label,
  error,
  hint,
  className,
  ...input
}: Omit<ComponentProps<typeof Input>, "id"> & { label: string; error?: string | null; hint?: string }) {
  const id = useId();
  return (
    <div className={cn("flex flex-col gap-1.5", className)}>
      <Label htmlFor={id}>{label}</Label>
      <Input id={id} aria-invalid={error ? true : undefined} aria-describedby={error ? `${id}-error` : undefined} {...input} />
      {/* The hint folds away as an error takes its place, rather than both jumping. */}
      <Reveal>{hint && !error ? <p className="text-xs text-on-surface-variant">{hint}</p> : null}</Reveal>
      <Reveal>
        {error ? (
          <p id={`${id}-error`} role="alert" className="text-xs text-error">
            {error}
          </p>
        ) : null}
      </Reveal>
    </div>
  );
}

/**
 * The square a label, smart view or collection wears in a list: its icon in
 * its colour on a faint wash of it (`LabelGlyph`, squared to the radius scale).
 */
export function GlyphBadge({
  icon,
  color,
  fallback,
  size = "md",
}: {
  icon: string | null;
  color: string | null;
  /** The glyph when [icon] is unset. */
  fallback?: LucideIcon;
  size?: "sm" | "md";
}) {
  const Fallback = fallback;
  const iconClass = size === "sm" ? "size-3.5" : "size-4";
  return (
    <span
      aria-hidden
      className={cn("inline-flex shrink-0 items-center justify-center rounded-md border transition-colors duration-150 ease-standard", size === "sm" ? "size-6" : "size-7")}
      style={labelStyle(color)}
    >
      {icon || !Fallback ? <LabelIcon iconKey={icon} className={cn(iconClass, "text-(--label-tint)")} /> : <Fallback className={cn(iconClass, "text-(--label-tint)")} />}
    </span>
  );
}

/** A row in a management list: grip, glyph, name, trailing actions. */
export function ManageRow({
  grip,
  leading,
  title,
  subtitle,
  subtitleFont = "mono",
  trailing,
  onOpen,
  dragging,
}: {
  grip?: ReactNode;
  leading: ReactNode;
  title: string;
  subtitle?: string;
  /** A smart view's subtitle is its query, set in code; anything else reads as text. */
  subtitleFont?: "mono" | "sans";
  trailing?: ReactNode;
  onOpen(): void;
  dragging?: boolean;
}) {
  return (
    <div
      className={cn(
        "group flex min-h-11 items-center gap-2 rounded-md pr-1 transition-[background-color,box-shadow] duration-150 ease-standard hover:bg-hover",
        dragging && "bg-surface shadow-raised",
      )}
    >
      {grip}
      <button type="button" onClick={onOpen} className="flex min-w-0 flex-1 items-center gap-3 rounded-md py-1.5 text-left outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50">
        {leading}
        <span className="flex min-w-0 flex-col">
          <span className="truncate text-sm text-on-surface">{title}</span>
          {subtitle ? <span className={cn("truncate text-xs text-on-surface-variant", subtitleFont === "mono" && "font-mono")}>{subtitle}</span> : null}
        </span>
      </button>
      {trailing}
    </div>
  );
}
