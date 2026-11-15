"use client";

import { forwardRef, useId, useState, type ComponentProps, type ReactNode } from "react";
import { Eye, EyeOff, type LucideIcon } from "lucide-react";
import { Reveal } from "@/components/common/reveal";
import { IconButton } from "@/components/common/icon-button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

// One input of the sign-in and reset forms (`widgets/login_field.dart`): a
// label, a leading icon, an inline error that grows in, and an optional
// trailing control.

type InputProps = Omit<ComponentProps<"input">, "id" | "className">;

export interface LoginFieldProps extends InputProps {
  label: string;
  icon: LucideIcon;
  error?: string | null;
  /** Outline in the error colour with no message: the banner carries it. */
  rejected?: boolean;
  trailing?: ReactNode;
}

export const LoginField = forwardRef<HTMLInputElement, LoginFieldProps>(function LoginField(
  { label, icon: Icon, error, rejected = false, trailing, ...input },
  ref,
) {
  const id = useId();
  const errorId = `${id}-error`;
  const invalid = Boolean(error) || rejected;
  return (
    <div className="flex flex-col gap-1.5">
      <Label htmlFor={id} className="text-xs font-medium text-on-surface-variant">
        {label}
      </Label>
      <div className="relative">
        <Icon aria-hidden className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-on-surface-variant" />
        <Input
          ref={ref}
          id={id}
          aria-invalid={invalid || undefined}
          aria-describedby={error ? errorId : undefined}
          className={trailing ? "h-10 pr-10 pl-9" : "h-10 pl-9"}
          {...input}
        />
        {trailing ? <div className="absolute top-1/2 right-1 -translate-y-1/2">{trailing}</div> : null}
      </div>
      <Reveal>
        {error ? (
          <p id={errorId} className="text-xs text-error">
            {error}
          </p>
        ) : null}
      </Reveal>
    </div>
  );
});

/** The show/hide toggle a password field carries. */
export function RevealPasswordButton({ shown, onToggle }: { shown: boolean; onToggle(): void }) {
  return (
    <IconButton
      type="button"
      size="sm"
      label={shown ? "Hide password" : "Show password"}
      icon={shown ? <EyeOff /> : <Eye />}
      onClick={onToggle}
    />
  );
}

/** Password visibility shared by the fields of one form. */
export function usePasswordVisibility(): { shown: boolean; toggle(): void } {
  const [shown, setShown] = useState(false);
  return { shown, toggle: () => setShown((s) => !s) };
}
