"use client";

import { Bot, Layers, ScanSearch, SlidersHorizontal, WandSparkles } from "lucide-react";
import { navigate } from "@/lib/router";
import { llmConfigured, useActiveWorkspace, useSettings, useSettingsController } from "@/lib/store";
import { Hint, ManagedNote, SettingsRow, SettingsSection, SwitchRow } from "../kit/rows";
import { useDialog } from "../kit/use-dialog";
import { EmbeddingStats } from "./embedding-stats";
import { LlmBehaviorDialog } from "./llm-behavior-dialog";
import { LLM_KEYS, LlmConfigDialog } from "./llm-config-dialog";
import { RewriteTasksDialog } from "./rewrite-tasks-dialog";
import { plural } from "../kit/files";

/** "model @ host", the provider as the row names it. */
export function providerSummary(baseUrl: string, model: string): string {
  let host = "";
  try {
    host = new URL(baseUrl).host;
  } catch {
    host = "";
  }
  return `${model} @ ${host || baseUrl}`;
}

export function AiPage() {
  const settings = useSettingsController();
  const capable = useSettings((s) => s.semanticSearchCapable);
  const enabled = useSettings((s) => s.semanticSearchEnabled);
  const configured = useSettings(llmConfigured);
  const summary = useSettings((s) => providerSummary(s.llmBaseUrl, s.llmModel));
  const locked = useSettings((s) => LLM_KEYS.some((k) => k in s.managed));
  const customPrompt = useSettings((s) => s.llmPrompt !== "");
  const taskCount = useSettings((s) => s.llmRewriteTasks.length);
  const config = useDialog();
  const behavior = useDialog();
  const tasks = useDialog();

  return (
    <>
      <SettingsSection title="Search">
        <SwitchRow
          icon={ScanSearch}
          title="Semantic search"
          subtitle={capable ? "Search your notes by meaning, not just keywords" : "Not available on this server"}
          checked={capable && enabled}
          onCheckedChange={capable ? (v) => settings.setSemanticSearchEnabled(v) : undefined}
        />
        {capable ? <EmbeddingStats /> : null}
      </SettingsSection>
      <SettingsSection title="Your AI provider">
        <Hint>Runs labeling, chat, and editing in the workspaces you own, for everyone in them. Each workspace turns these on or off in its own settings.</Hint>
        <SettingsRow
          icon={Bot}
          title="AI provider"
          subtitle={
            <>
              {configured ? summary : "Not configured, works with Ollama or any OpenAI-compatible API"}
              {locked ? <ManagedNote /> : null}
            </>
          }
          onClick={() => config.show(true)}
        />
        <SettingsRow
          icon={SlidersHorizontal}
          title="AI behavior"
          subtitle={customPrompt ? "Custom prompt and allowed note changes" : "Default prompt and allowed note changes"}
          onClick={() => behavior.show(true)}
        />
        <SettingsRow icon={WandSparkles} title="AI rewrite tasks" subtitle={plural(taskCount, "task")} onClick={() => tasks.show(true)} />
        <WorkspaceAiLink />
      </SettingsSection>
      <LlmConfigDialog key={`config-${config.key}`} open={config.open} onOpenChange={config.onOpenChange} />
      <LlmBehaviorDialog key={`behavior-${behavior.key}`} open={behavior.open} onOpenChange={behavior.onOpenChange} />
      <RewriteTasksDialog key={`tasks-${tasks.key}`} open={tasks.open} onOpenChange={tasks.onOpenChange} />
    </>
  );
}

/** Where the open workspace's AI switches live, and what they say. */
function WorkspaceAiLink() {
  const workspace = useActiveWorkspace();
  if (!workspace) {
    return null;
  }
  const s = workspace.ai.switches;
  const on = [s.labeling && "labeling", s.chat && "chat", s.writing && "editing"].filter((x): x is string => typeof x === "string");
  const state = !s.enabled || on.length === 0 ? "AI is off here" : `On: ${on.join(", ")}`;
  return <SettingsRow icon={Layers} title={`AI in ${workspace.name}`} subtitle={state} onClick={() => navigate({ name: "workspaceSettings", workspaceId: workspace.id })} />;
}
