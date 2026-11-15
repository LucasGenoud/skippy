"use client";

import type { ReactNode } from "react";
import { motion, useReducedMotion } from "motion/react";
import { Archive, AudioLines, Bell, ChartColumn, File, Flag, Image, Paperclip, Pencil, StickyNote, Trash2 } from "lucide-react";
import { EmptyState } from "@/components/common/empty-state";
import { LabelChip } from "@/components/common/label-chip";
import { Progress } from "@/components/ui/progress";
import type { NoteKind } from "@/lib/models";
import { editedLabel, formatDate, useSettings, useWorkspaceStats } from "@/lib/store";
import { labelColor } from "@/lib/theme/label-style";
import { DURATION } from "@/lib/theme/motion";
import { busiestMonth, checklistProgress, formatStatBytes, statsEmpty, type WorkspaceStats } from "@/lib/util/workspace-stats";
import { plural } from "@/features/settings/kit/files";
import { SettingsSection } from "@/features/settings/kit/rows";
import { Breakdown, FactRow, MonthChart, seriesColor, StatCard } from "./stats-charts";
import { WorkspacePage } from "./workspace-settings-screen";
import { useLeavingWorkspace } from "./use-leaving-workspace";

const KIND_LABELS: Record<NoteKind, string> = { text: "Text", checklist: "Checklists", markdown: "Markdown", audio: "Audio" };

/** Each section enters a beat after the one above it. */
const STAGGER_S = 0.04;
const RISE_PX = 8;
const MS_PER_S = 1000;

function Staggered({ index, children }: { index: number; children: ReactNode }) {
  const reduced = useReducedMotion();
  return (
    <motion.div
      initial={reduced ? false : { opacity: 0, y: RISE_PX }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: DURATION.base / MS_PER_S, delay: index * STAGGER_S, ease: [0.2, 0, 0, 1] }}
    >
      {children}
    </motion.div>
  );
}

/**
 * What a workspace holds, counted from the notes this device already has (no
 * request, works offline). Sections with nothing to say are left out.
 */
export default function WorkspaceStatsScreen({ workspaceId }: { workspaceId: string }) {
  const workspace = useLeavingWorkspace(workspaceId);
  const stats = useWorkspaceStats(workspaceId);

  if (!workspace) {
    return (
      <WorkspacePage title="Statistics">
        <EmptyState icon={ChartColumn} message="This workspace is gone." />
      </WorkspacePage>
    );
  }
  if (statsEmpty(stats)) {
    return (
      <WorkspacePage title="Statistics" subtitle={workspace.name}>
        <EmptyState icon={ChartColumn} message="Nothing to count yet. Add a note and come back." />
      </WorkspacePage>
    );
  }

  const sections: { title?: string; body: ReactNode }[] = [
    { body: <Overview stats={stats} /> },
    ...(stats.byKind.length > 0
      ? [{ title: "Content", body: <Breakdown slices={stats.byKind.map((s, i) => ({ label: KIND_LABELS[s.value], count: s.count, color: seriesColor(i) }))} /> }]
      : []),
    ...(stats.checklistItems > 0 ? [{ title: "Checklists", body: <Checklists stats={stats} /> }] : []),
    { title: "Activity", body: <Activity stats={stats} /> },
    ...(stats.labelCount > 0 ? [{ title: "Labels", body: <Labels stats={stats} /> }] : []),
    ...(stats.byStage.length > 0
      ? [
          {
            title: "Board",
            body: (
              <Breakdown
                slices={stats.byStage.map((s, i) => ({
                  label: s.value?.name ?? "Unassigned",
                  count: s.count,
                  color: s.value === null ? "var(--outline-variant)" : (labelColor(s.value.color) ?? seriesColor(i)),
                }))}
              />
            ),
          },
        ]
      : []),
    ...(stats.byAuthor.length > 0
      ? [{ title: "People", body: <Breakdown countLabel="notes written" slices={stats.byAuthor.map((s, i) => ({ label: s.value.name, count: s.count, color: seriesColor(i) }))} /> }]
      : []),
    ...(stats.attachmentCount > 0 ? [{ title: "Attachments", body: <Attachments stats={stats} /> }] : []),
  ];

  return (
    <WorkspacePage title="Statistics" subtitle={workspace.name}>
      {sections.map((section, i) => (
        <SettingsSection key={section.title ?? "overview"} title={section.title}>
          <Staggered index={i}>{section.body}</Staggered>
        </SettingsSection>
      ))}
    </WorkspacePage>
  );
}

function Overview({ stats }: { stats: WorkspaceStats }) {
  return (
    <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-4">
      <StatCard icon={StickyNote} value={stats.activeNotes} label="Notes" emphasis="primary" />
      <StatCard icon={Archive} value={stats.archived} label="Archived" emphasis="plain" />
      <StatCard icon={Trash2} value={stats.trashed} label="In trash" emphasis="plain" />
      <StatCard icon={Bell} value={stats.withReminders} label="Reminders" emphasis="plain" />
    </div>
  );
}

function Checklists({ stats }: { stats: WorkspaceStats }) {
  const progress = checklistProgress(stats) ?? 0;
  return (
    <div className="flex flex-col gap-2 px-3">
      <div className="flex items-baseline gap-2">
        <span className="flex-1 text-sm text-on-surface">
          {stats.checklistDone} of {stats.checklistItems} items ticked
        </span>
        <span className="text-base font-semibold text-primary tabular-nums">{Math.round(progress * 100)}%</span>
      </div>
      <Progress aria-label="Checklist items ticked" value={progress * 100} className="h-2" />
      <span className="text-xs text-on-surface-variant">
        {stats.completedLists === 0 ? "No list is finished yet" : `${stats.completedLists} ${stats.completedLists === 1 ? "list is" : "lists are"} fully ticked off`}
      </span>
    </div>
  );
}

function Activity({ stats }: { stats: WorkspaceStats }) {
  const dateFormat = useSettings((s) => s.dateFormat);
  const use24hTime = useSettings((s) => s.use24hTime);
  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-col gap-3 px-3">
        <span className="text-xs text-on-surface-variant">Notes created each month</span>
        <MonthChart months={stats.monthlyCreated} busiest={busiestMonth(stats)} />
      </div>
      <div>
        {stats.firstCreated ? <FactRow icon={Flag} label="First note" value={formatDate(stats.firstCreated, dateFormat)} /> : null}
        {stats.lastEdited ? <FactRow icon={Pencil} label="Last edited" value={editedLabel(stats.lastEdited, { dateFormat, use24hTime })} /> : null}
      </div>
    </div>
  );
}

function Labels({ stats }: { stats: WorkspaceStats }) {
  const total = plural(stats.labelCount, "label");
  return (
    <div className="flex flex-col gap-3 px-3">
      <span className="text-sm text-on-surface">{stats.unusedLabels === 0 ? `${total}, all in use` : `${total}, ${stats.unusedLabels} on no note`}</span>
      {stats.topLabels.length > 0 ? (
        <ul className="flex flex-wrap gap-2">
          {stats.topLabels.map((s) => (
            <li key={s.value.id} className="flex items-center gap-1.5">
              <LabelChip name={s.value.name} color={s.value.color} icon={s.value.icon} />
              <span className="text-xs text-on-surface-variant tabular-nums">{s.count}</span>
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}

function Attachments({ stats }: { stats: WorkspaceStats }) {
  return (
    <div>
      <FactRow icon={Paperclip} label="Files" value={`${stats.attachmentCount} · ${formatStatBytes(stats.attachmentBytes)}`} />
      {stats.imageCount > 0 ? <FactRow icon={Image} label="Pictures" value={stats.imageCount} /> : null}
      {stats.audioCount > 0 ? <FactRow icon={AudioLines} label="Recordings" value={stats.audioCount} /> : null}
      {stats.fileCount > 0 ? <FactRow icon={File} label="Documents" value={stats.fileCount} /> : null}
    </div>
  );
}
