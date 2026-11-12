"use client";

import { CircleAlert, CircleCheck, LoaderCircle, type LucideIcon } from "lucide-react";
import { Button } from "@/components/ui/button";
import { CrossFade } from "@/components/common/reveal";
import type { ProbeResult } from "@/lib/api/client";
import { ApiError } from "@/lib/api/errors";

/** Run a settings probe, folding transport errors into the server's shape. */
export async function runSettingsProbe(probe: () => Promise<ProbeResult>): Promise<ProbeResult> {
  try {
    return await probe();
  } catch (error) {
    if (error instanceof ApiError) {
      return { ok: false, error: error.serverMessage };
    }
    return { ok: false, error: "could not reach the server" };
  }
}

/**
 * The "test this configuration" row of the provider and channel dialogs: a
 * probe button (spinner while testing) and the latest result beside it. A
 * missing `onTest` disables the button.
 */
export function ProbeRow({
  testing,
  result,
  onTest,
  icon: Icon,
  label,
  successText,
}: {
  testing: boolean;
  result: ProbeResult | null;
  onTest?: () => void;
  icon: LucideIcon;
  label: string;
  successText: string;
}) {
  const key = result === null ? "none" : result.ok ? "ok" : `error:${result.error ?? ""}`;
  return (
    <div className="flex items-center gap-3">
      <Button type="button" variant="outline" size="sm" onClick={onTest} disabled={testing || !onTest}>
        {testing ? <LoaderCircle aria-hidden className="animate-spin" /> : <Icon aria-hidden />}
        {label}
      </Button>
      <div aria-live="polite" className="min-w-0 flex-1">
        <CrossFade stateKey={key} className="w-full">
          {result === null ? null : (
            <span className={result.ok ? "flex items-start gap-1.5 text-xs text-on-surface-variant" : "flex items-start gap-1.5 text-xs text-error"}>
              {result.ok ? <CircleCheck aria-hidden className="size-4 shrink-0 text-primary" /> : <CircleAlert aria-hidden className="size-4 shrink-0" />}
              <span className="line-clamp-3">{result.ok ? successText : (result.error ?? "failed")}</span>
            </span>
          )}
        </CrossFade>
      </div>
    </div>
  );
}
