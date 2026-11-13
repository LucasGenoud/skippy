"use client";

import { useState, type ComponentProps } from "react";
import { Eye, EyeOff } from "lucide-react";
import { Input } from "@/components/ui/input";
import { IconButton } from "@/components/common/icon-button";

/** A password field with a show/hide toggle at its end. */
export function PasswordInput({ autoComplete = "current-password", ...props }: Omit<ComponentProps<typeof Input>, "type">) {
  const [shown, setShown] = useState(false);
  return (
    <div className="relative">
      <Input {...props} type={shown ? "text" : "password"} autoComplete={autoComplete} className="pr-10" />
      <IconButton
        type="button"
        size="sm"
        label={shown ? "Hide password" : "Show password"}
        icon={shown ? <EyeOff /> : <Eye />}
        onClick={() => setShown((v) => !v)}
        className="absolute top-0.5 right-0.5"
      />
    </div>
  );
}
