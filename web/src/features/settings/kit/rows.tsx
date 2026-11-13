"use client";

import { useId, type ReactNode } from "react";
import { ChevronRight, Lock, type LucideIcon } from "lucide-react";
import { SectionLabel } from "@/components/common/section-label";
import { Switch } from "@/components/ui/switch";
import { cn } from "@/lib/utils";

// The rows every settings sheet is printed with: a section (small caps over a
// group), a row (icon, title, one line under it, something trailing), a
// switch row, and a quiet hint. Account and workspace settings share them so
// the two read as one family.

/** A group under small caps; groups after the first sit below a hairline. */
export function SettingsSection({ title, children, className }: { title?: string; children: ReactNode; className?: string }) {
  return (
    <section className={cn("border-t border-hairline pt-5 pb-3 first:border-t-0 first:pt-2", className)}>
      {title ? <SectionLabel className="px-3 pb-2">{title}</SectionLabel> : null}
      <div className="flex flex-col gap-0.5">{children}</div>
    </section>
  );
}

/** A quiet line explaining the rows around it. */
export function Hint({ children, className }: { children: ReactNode; className?: string }) {
  return <p className={cn("px-3 pt-1 pb-2 text-xs text-on-surface-variant", className)}>{children}</p>;
}

/** "Managed by the server", under a setting the deployment pins. */
export function ManagedNote() {
  return (
    <span className="mt-0.5 flex items-center gap-1 text-xs text-on-surface-variant">
      <Lock aria-hidden className="size-3" />
      Managed by the server
    </span>
  );
}

export type RowTone = "default" | "destructive";

export interface SettingsRowProps {
  icon?: LucideIcon;
  /** Drawn in the icon's place (a tinted glyph, an avatar). */
  leading?: ReactNode;
  title: ReactNode;
  subtitle?: ReactNode;
  /** Replaces the chevron a clickable row shows; null shows nothing. */
  trailing?: ReactNode;
  onClick?: () => void;
  disabled?: boolean;
  tone?: RowTone;
  /** Sit under the row that gates this one. */
  inset?: "none" | "nested";
  className?: string;
}

const ROW = "flex w-full min-h-14 items-center gap-4 rounded-md px-3 py-2.5 text-left";

function RowBody({ icon: Icon, leading, title, subtitle, tone }: Pick<SettingsRowProps, "icon" | "leading" | "title" | "subtitle" | "tone">) {
  const destructive = tone === "destructive";
  return (
    <>
      {leading}
      {Icon && !leading ? <Icon aria-hidden className={cn("size-5 shrink-0", destructive ? "text-error" : "text-on-surface-variant")} /> : null}
      <span className="flex min-w-0 flex-1 flex-col">
        <span className={cn("text-sm text-on-surface", destructive && "text-error")}>{title}</span>
        {subtitle ? <span className="text-xs text-on-surface-variant">{subtitle}</span> : null}
      </span>
    </>
  );
}

/** One settings row; with `onClick` the whole row is a button. */
export function SettingsRow({ icon, leading, title, subtitle, trailing, onClick, disabled, tone, inset = "none", className }: SettingsRowProps) {
  const nested = inset === "nested" && "pl-9";
  if (!onClick) {
    return (
      <div className={cn(ROW, nested, disabled && "opacity-50", className)}>
        <RowBody icon={icon} leading={leading} title={title} subtitle={subtitle} tone={tone} />
        {trailing}
      </div>
    );
  }
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className={cn(
        ROW,
        nested,
        "transition-colors duration-150 ease-standard outline-none hover:bg-hover active:bg-pressed focus-visible:ring-[3px] focus-visible:ring-ring/50 disabled:pointer-events-none disabled:opacity-50",
        className,
      )}
    >
      <RowBody icon={icon} leading={leading} title={title} subtitle={subtitle} tone={tone} />
      {trailing === undefined ? <ChevronRight aria-hidden className="size-4 shrink-0 text-on-surface-variant" /> : trailing}
    </button>
  );
}

/** A row whose trailing control is a switch; the text toggles it too. */
export function SwitchRow({
  icon,
  title,
  subtitle,
  checked,
  onCheckedChange,
  disabled,
  inset,
}: {
  icon?: LucideIcon;
  title: ReactNode;
  subtitle?: ReactNode;
  checked: boolean;
  onCheckedChange?: (value: boolean) => void;
  disabled?: boolean;
  inset?: SettingsRowProps["inset"];
}) {
  const id = useId();
  const inert = disabled || !onCheckedChange;
  return (
    <div className={cn(ROW, inset === "nested" && "pl-9")}>
      <label htmlFor={id} className={cn("flex min-w-0 flex-1 items-center gap-4", inert ? "cursor-default" : "cursor-pointer")}>
        <RowBody icon={icon} title={title} subtitle={subtitle} />
      </label>
      <Switch id={id} checked={checked} onCheckedChange={onCheckedChange} disabled={inert} />
    </div>
  );
}

/** A read-only on/off for someone who cannot change the switch. */
export function StateRow({ icon, title, subtitle, on, inset }: { icon?: LucideIcon; title: ReactNode; subtitle?: ReactNode; on: boolean; inset?: SettingsRowProps["inset"] }) {
  return (
    <SettingsRow
      icon={icon}
      title={title}
      subtitle={subtitle}
      inset={inset}
      trailing={<span className="text-sm font-medium text-on-surface-variant">{on ? "On" : "Off"}</span>}
    />
  );
}
