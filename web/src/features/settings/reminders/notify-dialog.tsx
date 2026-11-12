"use client";

import { useState } from "react";
import { BellRing, Lock } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import type { ProbeResult } from "@/lib/api/client";
import { NOTIFY_CHANNELS, channelConfiguredIn, isChoiceField, type NotifyField } from "@/lib/models";
import { useApi, useSettings, useSettingsController } from "@/lib/store";
import { Field, FormDialog } from "../kit/form-dialog";
import { ProbeRow, runSettingsProbe } from "../kit/probe-row";
import { notifyFormValues, trimmedValues } from "./notify-form";

const SECRET_PLACEHOLDER = "•••••• (set by the server)";

/**
 * Every channel in the registry, field by field, with a delivery probe that
 * tests the values as typed (before Save). Fields the server pins are locked;
 * a pinned secret is never sent to the client, so it shows a masked hint.
 */
export function NotifyDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (open: boolean) => void }) {
  const api = useApi();
  const settings = useSettingsController();
  const stored = useSettings((s) => s.notifyValues);
  const managed = useSettings((s) => s.managed);
  const [values, setValues] = useState(() => notifyFormValues(stored));
  const [testing, setTesting] = useState(false);
  const [result, setResult] = useState<ProbeResult | null>(null);
  const anyConfigured = NOTIFY_CHANNELS.some((c) => channelConfiguredIn(c, trimmedValues(values)));

  const set = (key: string, value: string) => setValues((v) => ({ ...v, [key]: value }));

  async function test() {
    setTesting(true);
    setResult(null);
    const outcome = await runSettingsProbe(() => api.testNotify(trimmedValues(values)));
    setTesting(false);
    setResult(outcome);
  }

  function save() {
    settings.setNotifyValues(trimmedValues(values));
    onOpenChange(false);
  }

  return (
    <FormDialog
      open={open}
      onOpenChange={onOpenChange}
      title="Notification channels"
      onSubmit={save}
      footer={
        <div className="flex w-full flex-col gap-3">
          <ProbeRow testing={testing} result={result} onTest={anyConfigured ? () => void test() : undefined} icon={BellRing} label="Send test" successText="Sent, check your device" />
          <div className="flex justify-end gap-2">
            <Button variant="ghost" onClick={() => onOpenChange(false)}>
              Cancel
            </Button>
            <Button onClick={save}>Save</Button>
          </div>
        </div>
      }
    >
      <div className="flex flex-col gap-6">
        {NOTIFY_CHANNELS.map((channel) => (
          <section key={channel.key} className="flex flex-col gap-3">
            <div>
              <h3 className="text-sm font-semibold text-on-surface">{channel.label}</h3>
              <p className="text-xs text-on-surface-variant">{channel.blurb}</p>
            </div>
            {channel.fields.map((field) => (
              <NotifyFieldControl key={field.key} field={field} value={values[field.key] ?? ""} locked={field.key in managed} onChange={(v) => set(field.key, v)} />
            ))}
          </section>
        ))}
      </div>
    </FormDialog>
  );
}

function NotifyFieldControl({ field, value, locked, onChange }: { field: NotifyField; value: string; locked: boolean; onChange: (value: string) => void }) {
  const id = `notify-field-${field.key}`;
  const helper = locked ? "Set by the server" : field.helper;
  const lock = locked ? <Lock aria-label="Set by the server" className="size-3.5 text-on-surface-variant" /> : null;
  if (isChoiceField(field)) {
    return (
      <Field label={field.label} htmlFor={id} helper={helper} trailing={lock}>
        <Select value={value} onValueChange={onChange} disabled={locked}>
          <SelectTrigger id={id} className="w-full">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {(field.options ?? []).map((o) => (
              <SelectItem key={o.value} value={o.value}>
                {o.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </Field>
    );
  }
  const label = field.mandatory === false ? `${field.label} (optional)` : field.label;
  return (
    <Field label={label} htmlFor={id} helper={helper} trailing={lock}>
      <Input
        id={id}
        value={value}
        disabled={locked}
        type={field.obscure && !locked ? "password" : "text"}
        autoComplete="off"
        inputMode={field.numeric ? "numeric" : undefined}
        placeholder={locked && field.obscure ? SECRET_PLACEHOLDER : field.hint}
        onChange={(e) => onChange(field.numeric ? e.target.value.replace(/\D/g, "") : e.target.value)}
      />
    </Field>
  );
}
