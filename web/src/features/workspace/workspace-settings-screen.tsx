"use client";

import { ArrowLeft, ChartColumn, Copy, Folder, Layers, Pencil, Plus } from "lucide-react";
import { EmptyState } from "@/components/common/empty-state";
import { IconButton } from "@/components/common/icon-button";
import type { NoteCollection } from "@/lib/models";
import { closeTo, navigate } from "@/lib/router";
import { isWorkspaceOwnedBy } from "@/lib/models";
import { useNotesController, useNotesSelector, useWorkspace } from "@/lib/store";
import { LabelIcon, labelColor } from "@/lib/theme/label-style";
import { computeWorkspaceStats } from "@/lib/util/workspace-stats";
import { plural } from "@/features/settings/kit/files";
import { SettingsRow, SettingsSection } from "@/features/settings/kit/rows";
import { useDialog } from "@/features/settings/kit/use-dialog";
import { layoutLabel } from "./collection-labels";
import { CollectionSettingsDialog } from "./collection-settings-dialog";
import { DangerZone } from "./danger-zone";
import { DuplicateWorkspaceDialog } from "./duplicate-workspace-dialog";
import { PeopleSection } from "./people-section";
import { WorkspaceAiSection } from "./workspace-ai-section";
import { RenameWorkspaceDialog } from "./workspace-dialogs";

/** A full page with a back button, shared by the workspace's settings and stats. */
export function WorkspacePage({ title, subtitle, children }: { title: string; subtitle?: string; children: React.ReactNode }) {
  return (
    <div className="flex h-dvh flex-col bg-surface text-on-surface">
      <header className="flex h-14 shrink-0 items-center gap-2 border-b border-hairline px-2">
        <IconButton label="Back" icon={<ArrowLeft />} onClick={() => closeTo({ name: "home" })} />
        <div className="flex min-w-0 flex-col">
          <h1 className="truncate text-base leading-5 font-semibold">{title}</h1>
          {subtitle ? <span className="truncate text-xs text-on-surface-variant">{subtitle}</span> : null}
        </div>
      </header>
      <main className="min-h-0 flex-1 overflow-y-auto">
        <div className="mx-auto max-w-[640px] px-4 pt-2 pb-8">{children}</div>
      </main>
    </div>
  );
}

function CollectionIcon({ collection }: { collection: NoteCollection }) {
  const color = labelColor(collection.color);
  const props = { "aria-hidden": true, className: "size-5 shrink-0 text-on-surface-variant", style: color ? { color } : undefined } as const;
  return collection.icon === null ? <Folder {...props} /> : <LabelIcon iconKey={collection.icon} {...props} />;
}

/**
 * One workspace's settings: its name, collections, duplication, statistics,
 * who is in it, what AI it allows, and how to delete or leave it.
 */
export function WorkspaceSettingsScreen({ workspaceId }: { workspaceId: string }) {
  const notes = useNotesController();
  const workspace = useWorkspace(workspaceId);
  const rename = useDialog();
  const duplicate = useDialog();
  const collection = useDialog<{ id?: string }>();

  if (!workspace) {
    // Deleted or left on another device while this page was open.
    return (
      <WorkspacePage title="Workspace">
        <EmptyState icon={Layers} message="This workspace is gone." />
      </WorkspacePage>
    );
  }

  const isOwner = isWorkspaceOwnedBy(workspace, notes.currentUserId);

  return (
    <WorkspacePage title={workspace.name}>
      <SettingsSection title="General">
        <SettingsRow
          icon={Layers}
          title={workspace.name}
          subtitle={isOwner ? "Owned by you" : `Owned by ${workspace.owner?.name || "someone else"}`}
          trailing={isOwner ? <IconButton size="sm" label="Rename workspace" icon={<Pencil />} onClick={() => rename.show(true)} /> : null}
        />
      </SettingsSection>
      <SettingsSection title="Collections">
        {workspace.collections.map((c) => (
          <SettingsRow key={c.id} leading={<CollectionIcon collection={c} />} title={c.name} subtitle={layoutLabel(c.layout)} onClick={() => collection.show({ id: c.id })} />
        ))}
        <SettingsRow icon={Plus} title="New collection" trailing={null} onClick={() => collection.show({})} />
        <SettingsRow icon={Copy} title="Duplicate workspace" subtitle="Copy structure, or structure and notes" trailing={null} onClick={() => duplicate.show(true)} />
      </SettingsSection>
      <SettingsSection title="Statistics">
        <StatisticsRow workspaceId={workspace.id} />
      </SettingsSection>
      <SettingsSection title="People">
        <PeopleSection workspace={workspace} isOwner={isOwner} />
      </SettingsSection>
      <SettingsSection title="AI">
        <WorkspaceAiSection workspace={workspace} isOwner={isOwner} />
      </SettingsSection>
      <SettingsSection title="Danger zone">
        <DangerZone workspace={workspace} isOwner={isOwner} />
      </SettingsSection>
      <RenameWorkspaceDialog workspaceId={workspace.id} open={rename.open} onOpenChange={rename.onOpenChange} />
      <DuplicateWorkspaceDialog workspaceId={workspace.id} open={duplicate.open} onOpenChange={duplicate.onOpenChange} />
      <CollectionSettingsDialog workspaceId={workspace.id} collectionId={collection.value?.id} open={collection.open} onOpenChange={collection.onOpenChange} />
    </WorkspacePage>
  );
}

/** Counted the way the stats page counts, so the two never disagree. */
function StatisticsRow({ workspaceId }: { workspaceId: string }) {
  const notes = useNotesController();
  const summary = useNotesSelector(
    () => {
      const stats = computeWorkspaceStats({
        notes: notes.notesInWorkspace(workspaceId),
        labels: notes.labelsInWorkspace(workspaceId),
        stages: notes.stagesInWorkspace(workspaceId),
        now: new Date(),
      });
      return `${plural(stats.activeNotes, "note")} · ${plural(stats.labelCount, "label")}`;
    },
    Object.is,
    [workspaceId],
  );
  return <SettingsRow icon={ChartColumn} title="Statistics" subtitle={summary} onClick={() => navigate({ name: "workspaceStats", workspaceId })} />;
}
