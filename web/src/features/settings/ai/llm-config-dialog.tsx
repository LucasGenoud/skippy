"use client";

import { useState } from "react";
import { Lock, Zap } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import type { ProbeResult } from "@/lib/api/client";
import { useApi, useSettings, useSettingsController } from "@/lib/store";
import { Field, FormDialog } from "../kit/form-dialog";
import { ProbeRow, runSettingsProbe } from "../kit/probe-row";

const SECRET_PLACEHOLDER = "•••••• (set by the server)";
export const LLM_KEYS = ["llm_base_url", "llm_api_key", "llm_model"] as const;

const lock = <Lock aria-label="Set by the server" className="size-3.5 text-on-surface-variant" />;

/** Endpoint, key and model, with a connection probe of the values as typed. */
export function LlmConfigDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (open: boolean) => void }) {
  const api = useApi();
  const settings = useSettingsController();
  const managed = useSettings((s) => s.managed);
  const initial = useSettings((s) => ({ url: s.llmBaseUrl, key: s.llmApiKey, model: s.llmModel }), (a, b) => a.url === b.url && a.key === b.key && a.model === b.model);
  const [url, setUrl] = useState(initial.url);
  const [key, setKey] = useState(initial.key);
  const [model, setModel] = useState(initial.model);
  const [testing, setTesting] = useState(false);
  const [result, setResult] = useState<ProbeResult | null>(null);
  const urlLocked = "llm_base_url" in managed;
  const keyLocked = "llm_api_key" in managed;
  const modelLocked = "llm_model" in managed;

  async function test() {
    setTesting(true);
    setResult(null);
    const outcome = await runSettingsProbe(() => api.testLlm({ baseUrl: url.trim(), apiKey: key.trim(), model: model.trim() }));
    setTesting(false);
    setResult(outcome);
  }

  function save() {
    settings.setLlmConfig({ baseUrl: url, apiKey: key, model });
    onOpenChange(false);
  }

  return (
    <FormDialog
      open={open}
      onOpenChange={onOpenChange}
      title="AI provider"
      onSubmit={save}
      footer={
        <>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button onClick={save}>Save</Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        <Field
          label="Server URL"
          htmlFor="llm-url"
          trailing={urlLocked ? lock : null}
          helper={urlLocked ? "Set by the server" : "OpenAI-compatible endpoint, including /v1 (Ollama, OpenAI, LM Studio, …)"}
        >
          <Input id="llm-url" autoFocus value={url} disabled={urlLocked} placeholder="http://localhost:11434/v1" onChange={(e) => setUrl(e.target.value)} />
        </Field>
        <Field label="API key" htmlFor="llm-key" trailing={keyLocked ? lock : null} helper={keyLocked ? "Set by the server" : "Leave empty for Ollama"}>
          <Input
            id="llm-key"
            type={keyLocked ? "text" : "password"}
            autoComplete="off"
            value={key}
            disabled={keyLocked}
            placeholder={keyLocked ? SECRET_PLACEHOLDER : undefined}
            onChange={(e) => setKey(e.target.value)}
          />
        </Field>
        <Field label="Model" htmlFor="llm-model" trailing={modelLocked ? lock : null} helper={modelLocked ? "Set by the server" : undefined}>
          <Input id="llm-model" value={model} disabled={modelLocked} placeholder="gpt-5-mini, llama3.1, …" onChange={(e) => setModel(e.target.value)} />
        </Field>
        <ProbeRow testing={testing} result={result} onTest={() => void test()} icon={Zap} label="Test connection" successText="Connected" />
      </div>
    </FormDialog>
  );
}
