import { hasReminder, isAudioAttachment, isImageAttachment, type Label, type Note, type NoteKind, type Stage, type UserRef } from "@/lib/models/note";

// What a workspace holds, counted from what the client already has. Ported
// from `util/workspace_stats.dart`. Trash is excluded from every breakdown and
// only surfaces as `trashed`; archived notes count everywhere.

export const ACTIVITY_MONTHS = 12;
export const TOP_LABELS = 5;

export interface StatSlice<T> {
  readonly value: T;
  readonly count: number;
}

export interface MonthlyActivity {
  /** First day of the month, local midnight. */
  readonly month: Date;
  readonly created: number;
}

export interface WorkspaceStats {
  readonly activeNotes: number;
  readonly archived: number;
  readonly trashed: number;
  readonly pinned: number;
  readonly withReminders: number;
  readonly byKind: readonly StatSlice<NoteKind>[];
  readonly checklistItems: number;
  readonly checklistDone: number;
  readonly completedLists: number;
  readonly labelCount: number;
  readonly unusedLabels: number;
  readonly topLabels: readonly StatSlice<Label>[];
  /** Board order; a null value is the unassigned bucket, last when present. */
  readonly byStage: readonly StatSlice<Stage | null>[];
  /** Empty unless more than one person wrote here. */
  readonly byAuthor: readonly StatSlice<UserRef>[];
  readonly attachmentCount: number;
  readonly attachmentBytes: number;
  readonly imageCount: number;
  readonly audioCount: number;
  readonly fileCount: number;
  readonly monthlyCreated: readonly MonthlyActivity[];
  readonly firstCreated: Date | null;
  readonly lastEdited: Date | null;
}

export const liveNotes = (s: WorkspaceStats): number => s.activeNotes + s.archived;
export const statsEmpty = (s: WorkspaceStats): boolean => liveNotes(s) === 0 && s.trashed === 0;
export const checklistProgress = (s: WorkspaceStats): number | null => (s.checklistItems === 0 ? null : s.checklistDone / s.checklistItems);
export const busiestMonth = (s: WorkspaceStats): number => s.monthlyCreated.reduce((a, m) => Math.max(a, m.created), 0);

const monthStart = (t: Date): Date => new Date(t.getFullYear(), t.getMonth());

function bump<K>(map: Map<K, number>, key: K): void {
  map.set(key, (map.get(key) ?? 0) + 1);
}

/** Inputs must already be narrowed to one workspace. */
export function computeWorkspaceStats(input: {
  notes: Iterable<Note>;
  labels: Iterable<Label>;
  stages: Iterable<Stage>;
  now: Date;
}): WorkspaceStats {
  let activeNotes = 0;
  let archived = 0;
  let trashed = 0;
  let pinned = 0;
  let withReminders = 0;
  let checklistItems = 0;
  let checklistDone = 0;
  let completedLists = 0;
  let attachmentCount = 0;
  let attachmentBytes = 0;
  let imageCount = 0;
  let audioCount = 0;
  let fileCount = 0;
  let firstCreated: Date | null = null;
  let lastEdited: Date | null = null;
  const kindCounts = new Map<NoteKind, number>();
  const labelCounts = new Map<string, number>();
  const stageCounts = new Map<string | null, number>();
  const authors = new Map<string, UserRef>();
  const authorCounts = new Map<string, number>();

  // Buckets exist up front so quiet months keep their place on the axis.
  const months = new Map<number, number>();
  for (let back = ACTIVITY_MONTHS - 1; back >= 0; back--) {
    months.set(new Date(input.now.getFullYear(), input.now.getMonth() - back).getTime(), 0);
  }

  for (const note of input.notes) {
    if (note.trashed) {
      trashed++;
      continue;
    }
    if (note.archived) {
      archived++;
    } else {
      activeNotes++;
    }
    if (note.pinned) {
      pinned++;
    }
    if (hasReminder(note)) {
      withReminders++;
    }
    bump(kindCounts, note.kind);
    if (note.kind === "checklist" && note.items.length > 0) {
      const done = note.items.filter((i) => i.done).length;
      checklistItems += note.items.length;
      checklistDone += done;
      if (done === note.items.length) {
        completedLists++;
      }
    }
    for (const id of note.labelIds) {
      bump(labelCounts, id);
    }
    bump(stageCounts, note.stageId);
    if (note.owner) {
      authors.set(note.owner.id, note.owner);
      bump(authorCounts, note.owner.id);
    }
    for (const attachment of note.attachments) {
      attachmentCount++;
      attachmentBytes += attachment.size;
      if (isImageAttachment(attachment)) {
        imageCount++;
      } else if (isAudioAttachment(attachment)) {
        audioCount++;
      } else {
        fileCount++;
      }
    }
    if (firstCreated === null || note.createdAt < firstCreated) {
      firstCreated = note.createdAt;
    }
    if (lastEdited === null || note.updatedAt > lastEdited) {
      lastEdited = note.updatedAt;
    }
    const bucket = monthStart(note.createdAt).getTime();
    const current = months.get(bucket);
    if (current !== undefined) {
      months.set(bucket, current + 1);
    }
  }

  const labelList = [...input.labels];
  const byCount = <T>(a: StatSlice<T>, b: StatSlice<T>): number => b.count - a.count;
  const topLabels = labelList
    .filter((l) => (labelCounts.get(l.id) ?? 0) > 0)
    .map((l) => ({ value: l, count: labelCounts.get(l.id) ?? 0 }))
    .sort(byCount);
  const byStage: StatSlice<Stage | null>[] = [...input.stages].map((s) => ({ value: s, count: stageCounts.get(s.id) ?? 0 }));
  const unassigned = stageCounts.get(null) ?? 0;
  if (unassigned > 0) {
    byStage.push({ value: null, count: unassigned });
  }
  const byAuthor = [...authorCounts.entries()]
    .map(([id, count]) => ({ value: authors.get(id) as UserRef, count }))
    .sort(byCount);
  const byKind = [...kindCounts.entries()].map(([value, count]) => ({ value, count })).sort(byCount);

  return {
    activeNotes,
    archived,
    trashed,
    pinned,
    withReminders,
    byKind,
    checklistItems,
    checklistDone,
    completedLists,
    labelCount: labelList.length,
    unusedLabels: labelList.filter((l) => (labelCounts.get(l.id) ?? 0) === 0).length,
    topLabels: topLabels.slice(0, TOP_LABELS),
    byStage,
    byAuthor: byAuthor.length > 1 ? byAuthor : [],
    attachmentCount,
    attachmentBytes,
    imageCount,
    audioCount,
    fileCount,
    monthlyCreated: [...months.entries()].map(([ms, created]) => ({ month: new Date(ms), created })),
    firstCreated,
    lastEdited,
  };
}

/** "2.4 MB", "812 kB", "0 bytes": decimal units, as file managers report. */
export function formatStatBytes(bytes: number): string {
  if (bytes < 1000) {
    return `${bytes} ${bytes === 1 ? "byte" : "bytes"}`;
  }
  const units = ["kB", "MB", "GB", "TB"];
  let value = bytes / 1000;
  let unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  const text = value < 10 ? value.toFixed(1) : String(Math.round(value));
  return `${text} ${units[unit]}`;
}
