"use client";

import { Bot, MessagesSquare, Sparkles, Tag, WandSparkles } from "lucide-react";
import type { AiSwitches, Workspace } from "@/lib/models";
import { navigate } from "@/lib/router";
import { useNotesController, useSettings } from "@/lib/store";
import { Hint, ManagedNote, SettingsRow, StateRow, SwitchRow } from "@/features/settings/kit/rows";

type Feature = "labeling" | "chat" | "writing";

/** The server pin that overrides each feature switch in every workspace. */
const MANAGED_KEYS: Record<Feature, string> = { labeling: "llm_labeling", chat: "llm_chat", writing: "llm_writing" };

/** The line under "AI in this workspace": whose provider, and whether there is one. */
export function aiStatus(providerReady: boolean, isOwner: boolean, ownerName: string): string {
  if (providerReady) {
    return isOwner ? "Runs on your AI provider, for everyone here" : `Runs on ${ownerName}'s AI provider`;
  }
  return isOwner ? "Needs your AI provider" : `${ownerName} hasn't set up an AI provider`;
}

/**
 * A workspace's AI switches. Everything runs on the owner's provider, so the
 * owner decides and everyone else reads what is in effect:
 *
 *   AI in this workspace            [on]   runs on Ada's AI provider
 *     Automatic labeling            [on]   -+
 *     Notes chat                    [on]    | live only while AI is on
 *     AI note editing               [on]   -+
 *   Assistant access (MCP)          [on]   tokens, not the provider
 */
export function WorkspaceAiSection({ workspace, isOwner }: { workspace: Workspace; isOwner: boolean }) {
  const notes = useNotesController();
  const managed = useSettings((s) => s.managed);
  const searchCapable = useSettings((s) => s.semanticSearchCapable);
  const { switches, providerReady } = workspace.ai;
  const ownerName = workspace.owner?.name || "The owner";

  const set = (next: AiSwitches) => notes.updateWorkspaceAi(workspace.id, next);

  const features: readonly { key: Feature; icon: typeof Tag; title: string; subtitle: string }[] = [
    { key: "labeling", icon: Tag, title: "Automatic labeling", subtitle: "Apply this workspace's labels to new and edited notes" },
    { key: "chat", icon: MessagesSquare, title: "Notes chat", subtitle: searchCapable ? "Ask questions about these notes" : "Needs semantic search on this server" },
    { key: "writing", icon: WandSparkles, title: "AI note editing", subtitle: "Cleanup and rewrite actions in each note's menu" },
  ];

  return (
    <>
      {isOwner ? (
        <SwitchRow icon={Sparkles} title="AI in this workspace" subtitle={aiStatus(providerReady, true, ownerName)} checked={switches.enabled} onCheckedChange={(v) => set({ ...switches, enabled: v })} />
      ) : (
        <StateRow icon={Sparkles} title="AI in this workspace" subtitle={aiStatus(providerReady, false, ownerName)} on={switches.enabled} />
      )}
      {isOwner && !providerReady ? <SettingsRow title="Set up your AI provider" inset="nested" onClick={() => navigate({ name: "settings", page: "ai" })} /> : null}
      {features.map((f) => {
        const pinned = MANAGED_KEYS[f.key] in managed;
        const subtitle = (
          <>
            {f.subtitle}
            {pinned ? <ManagedNote /> : null}
          </>
        );
        if (!isOwner) {
          // A member reads what is in effect: a feature under a switched-off AI is off.
          return <StateRow key={f.key} icon={f.icon} title={f.title} subtitle={subtitle} inset="nested" on={switches.enabled && switches[f.key]} />;
        }
        return (
          <SwitchRow
            key={f.key}
            icon={f.icon}
            title={f.title}
            subtitle={subtitle}
            inset="nested"
            checked={switches[f.key]}
            onCheckedChange={!switches.enabled || pinned ? undefined : (v) => set({ ...switches, [f.key]: v })}
          />
        );
      })}
      {isOwner ? (
        <SwitchRow
          icon={Bot}
          title="Assistant access (MCP)"
          subtitle="Members' access tokens can read and add to these notes"
          checked={switches.assistantAccess}
          onCheckedChange={(v) => set({ ...switches, assistantAccess: v })}
        />
      ) : (
        <StateRow icon={Bot} title="Assistant access (MCP)" subtitle="Members' access tokens can read and add to these notes" on={switches.assistantAccess} />
      )}
      <Hint>{isOwner ? "These apply to everyone in this workspace." : `Only ${ownerName} can change these.`}</Hint>
    </>
  );
}
