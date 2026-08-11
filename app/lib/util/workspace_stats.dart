import '../models/note.dart';

/// How many months of history the activity chart covers.
const int kActivityMonths = 12;

/// How many labels the stats screen names before falling back to a count.
const int kTopLabels = 5;

/// One row of a counted breakdown: a thing and how many notes it holds.
class StatSlice<T> {
  final T value;
  final int count;

  const StatSlice(this.value, this.count);
}

/// Notes created in one calendar month.
class MonthlyActivity {
  /// The first day of the month, so callers can format it however they like.
  final DateTime month;
  final int created;

  const MonthlyActivity({required this.month, required this.created});
}

/// What a workspace holds, counted.
///
/// Everything here is derived from the notes, labels and stages the client
/// already has: the stats screen makes no request of its own.
///
/// **Counting rule**: a breakdown describes notes that still exist, so trash is
/// excluded from every one of them and surfaces only as [trashed]. Archived
/// notes are ordinary notes that happen to be filed away, so they do count in
/// the breakdowns as well as in [archived].
class WorkspaceStats {
  /// Not archived, not trashed: what the notes grid shows.
  final int activeNotes;
  final int archived;
  final int trashed;
  final int pinned;
  final int withReminders;

  /// Notes per kind, largest first. Kinds with no notes are left out.
  final List<StatSlice<NoteKind>> byKind;

  /// Checklist items across every checklist note.
  final int checklistItems;
  final int checklistDone;

  /// Checklist notes whose items are all ticked (empty lists don't count).
  final int completedLists;

  final int labelCount;

  /// Labels no note in the workspace carries.
  final int unusedLabels;

  /// The busiest labels, largest first, at most [kTopLabels].
  final List<StatSlice<Label>> topLabels;

  /// Notes per board column, in board order. A null [StatSlice.value] is the
  /// unassigned bucket, and is last when present.
  final List<StatSlice<Stage?>> byStage;

  /// Notes per author, largest first. Empty unless more than one person has
  /// written in this workspace.
  final List<StatSlice<UserRef>> byAuthor;

  final int attachmentCount;
  final int attachmentBytes;
  final int imageCount;
  final int audioCount;
  final int fileCount;

  /// The last [kActivityMonths] months, oldest first, including quiet ones so
  /// the chart keeps an even time axis.
  final List<MonthlyActivity> monthlyCreated;

  /// Null when the workspace holds nothing.
  final DateTime? firstCreated;
  final DateTime? lastEdited;

  const WorkspaceStats({
    required this.activeNotes,
    required this.archived,
    required this.trashed,
    required this.pinned,
    required this.withReminders,
    required this.byKind,
    required this.checklistItems,
    required this.checklistDone,
    required this.completedLists,
    required this.labelCount,
    required this.unusedLabels,
    required this.topLabels,
    required this.byStage,
    required this.byAuthor,
    required this.attachmentCount,
    required this.attachmentBytes,
    required this.imageCount,
    required this.audioCount,
    required this.fileCount,
    required this.monthlyCreated,
    required this.firstCreated,
    required this.lastEdited,
  });

  /// Notes that still exist, archived ones included: the population every
  /// breakdown describes.
  int get liveNotes => activeNotes + archived;

  /// Whether the workspace has nothing at all to show yet.
  bool get isEmpty => liveNotes == 0 && trashed == 0;

  /// 0..1 across every checklist item, or null when there are no items.
  double? get checklistProgress =>
      checklistItems == 0 ? null : checklistDone / checklistItems;

  /// The busiest month in [monthlyCreated], for scaling the chart. Zero when
  /// nothing was created in the window.
  int get busiestMonth => monthlyCreated.fold(0, (a, m) => a > m.created ? a : m.created);
}

/// Count what [notes] holds. [notes] must already be narrowed to one workspace
/// (see `NotesStore.notesInWorkspace`), as must [labels] and [stages].
///
/// [now] anchors the activity window, so callers can pin it in tests.
WorkspaceStats computeWorkspaceStats({
  required Iterable<Note> notes,
  required Iterable<Label> labels,
  required Iterable<Stage> stages,
  required DateTime now,
}) {
  var activeNotes = 0;
  var archived = 0;
  var trashed = 0;
  var pinned = 0;
  var withReminders = 0;
  var checklistItems = 0;
  var checklistDone = 0;
  var completedLists = 0;
  var attachmentCount = 0;
  var attachmentBytes = 0;
  var imageCount = 0;
  var audioCount = 0;
  var fileCount = 0;
  DateTime? firstCreated;
  DateTime? lastEdited;

  final kindCounts = <NoteKind, int>{};
  final labelCounts = <String, int>{};
  final stageCounts = <String?, int>{};
  final authors = <String, UserRef>{};
  final authorCounts = <String, int>{};

  // The month buckets exist up front so quiet months keep their place on the
  // axis; anything older than the window simply finds no bucket.
  final months = <DateTime, int>{
    for (var back = kActivityMonths - 1; back >= 0; back--)
      _monthStart(DateTime(now.year, now.month - back)): 0,
  };

  for (final note in notes) {
    if (note.trashed) {
      // Trash is counted and then left out of everything else: a deleted note
      // should not still be shaping the label or board picture.
      trashed++;
      continue;
    }
    if (note.archived) {
      archived++;
    } else {
      activeNotes++;
    }
    if (note.pinned) pinned++;
    if (note.reminderAt != null) withReminders++;

    kindCounts.update(note.kind, (n) => n + 1, ifAbsent: () => 1);

    if (note.isChecklist && note.items.isNotEmpty) {
      final done = note.items.where((i) => i.done).length;
      checklistItems += note.items.length;
      checklistDone += done;
      if (done == note.items.length) completedLists++;
    }

    for (final id in note.labelIds) {
      labelCounts.update(id, (n) => n + 1, ifAbsent: () => 1);
    }
    stageCounts.update(note.stageId, (n) => n + 1, ifAbsent: () => 1);

    final owner = note.owner;
    if (owner != null) {
      authors[owner.id] = owner;
      authorCounts.update(owner.id, (n) => n + 1, ifAbsent: () => 1);
    }

    for (final attachment in note.attachments) {
      attachmentCount++;
      attachmentBytes += attachment.size;
      if (attachment.isImage) {
        imageCount++;
      } else if (attachment.isAudio) {
        audioCount++;
      } else {
        fileCount++;
      }
    }

    if (firstCreated == null || note.createdAt.isBefore(firstCreated)) {
      firstCreated = note.createdAt;
    }
    if (lastEdited == null || note.updatedAt.isAfter(lastEdited)) {
      lastEdited = note.updatedAt;
    }
    final bucket = _monthStart(note.createdAt);
    if (months.containsKey(bucket)) {
      months[bucket] = months[bucket]! + 1;
    }
  }

  final labelList = labels.toList();
  final topLabels = [
    for (final label in labelList)
      if ((labelCounts[label.id] ?? 0) > 0)
        StatSlice(label, labelCounts[label.id]!),
  ]..sort((a, b) => b.count.compareTo(a.count));

  final byStage = <StatSlice<Stage?>>[
    for (final stage in stages) StatSlice<Stage?>(stage, stageCounts[stage.id] ?? 0),
    if ((stageCounts[null] ?? 0) > 0)
      StatSlice<Stage?>(null, stageCounts[null]!),
  ];

  final byAuthor = <StatSlice<UserRef>>[
    for (final entry in authorCounts.entries)
      StatSlice(authors[entry.key]!, entry.value),
  ]..sort((a, b) => b.count.compareTo(a.count));

  final byKind = [
    for (final entry in kindCounts.entries) StatSlice(entry.key, entry.value),
  ]..sort((a, b) => b.count.compareTo(a.count));

  return WorkspaceStats(
    activeNotes: activeNotes,
    archived: archived,
    trashed: trashed,
    pinned: pinned,
    withReminders: withReminders,
    byKind: byKind,
    checklistItems: checklistItems,
    checklistDone: checklistDone,
    completedLists: completedLists,
    labelCount: labelList.length,
    unusedLabels: labelList
        .where((l) => (labelCounts[l.id] ?? 0) == 0)
        .length,
    topLabels: topLabels.take(kTopLabels).toList(),
    byStage: byStage,
    // One author is just "the owner", which the People section already says.
    byAuthor: byAuthor.length > 1 ? byAuthor : const [],
    attachmentCount: attachmentCount,
    attachmentBytes: attachmentBytes,
    imageCount: imageCount,
    audioCount: audioCount,
    fileCount: fileCount,
    monthlyCreated: [
      for (final entry in months.entries)
        MonthlyActivity(month: entry.key, created: entry.value),
    ],
    firstCreated: firstCreated,
    lastEdited: lastEdited,
  );
}

/// Midnight on the first of a timestamp's month, in local time: the bucket key
/// the activity chart groups by.
DateTime _monthStart(DateTime t) {
  final local = t.isUtc ? t.toLocal() : t;
  return DateTime(local.year, local.month);
}

/// "2.4 MB", "812 kB", "0 bytes". Decimal units, matching what file managers
/// and the OS report for the same attachment.
String formatBytes(int bytes) {
  if (bytes < 1000) return '$bytes ${bytes == 1 ? 'byte' : 'bytes'}';
  const units = ['kB', 'MB', 'GB', 'TB'];
  var value = bytes / 1000;
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  // One decimal below 10 (2.4 MB), none above it (812 kB): enough precision to
  // be useful without pretending to a byte-level accuracy nobody needs here.
  final text = value < 10 ? value.toStringAsFixed(1) : value.round().toString();
  return '$text ${units[unit]}';
}
