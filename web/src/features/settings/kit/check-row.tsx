"use client";

import { useId, type ReactNode } from "react";
import { Checkbox } from "@/components/ui/checkbox";

/** A checkbox with a title and an optional line under it, inside a form. */
export function CheckRow({
  title,
  subtitle,
  checked,
  onCheckedChange,
  disabled,
}: {
  title: ReactNode;
  subtitle?: ReactNode;
  checked: boolean;
  onCheckedChange: (value: boolean) => void;
  disabled?: boolean;
}) {
  const id = useId();
  return (
    <div className="flex items-start gap-3 rounded-md px-2 py-2 transition-colors duration-150 ease-standard hover:bg-hover">
      <Checkbox id={id} className="mt-0.5" checked={checked} disabled={disabled} onCheckedChange={(v) => onCheckedChange(v === true)} />
      <label htmlFor={id} className="flex min-w-0 flex-1 cursor-pointer flex-col">
        <span className="text-sm text-on-surface">{title}</span>
        {subtitle ? <span className="text-xs text-on-surface-variant">{subtitle}</span> : null}
      </label>
    </div>
  );
}
