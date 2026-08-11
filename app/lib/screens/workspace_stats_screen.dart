import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../theme.dart';
import '../util/label_style.dart';
import '../util/motion.dart';
import '../util/workspace_stats.dart';
import '../widgets/empty_state.dart';
import '../widgets/staggered_entrance.dart';
import 'workspace_settings_screen.dart' show SectionHeader;

/// What a workspace holds, counted: how many notes and of what kind, how the
/// checklists are doing, which labels carry weight, how the board is filled,
/// who is contributing, and what it has all been costing in attachments.
///
/// Every figure comes from the notes this device already holds, so the page
/// makes no request and works offline. Sections with nothing to say are left
/// out rather than shown empty.
class WorkspaceStatsScreen extends StatelessWidget {
  final String workspaceId;

  const WorkspaceStatsScreen({super.key, required this.workspaceId});

  static Route<void> route(String workspaceId) => MaterialPageRoute(
    builder: (_) => WorkspaceStatsScreen(workspaceId: workspaceId),
  );

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final settings = context.watch<SettingsStore>();
    final workspace = store.workspaceById(workspaceId);

    if (workspace == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Statistics')),
        body: const EmptyState(
          icon: Icons.insights_outlined,
          message: 'This workspace is gone.',
        ),
      );
    }

    final stats = computeWorkspaceStats(
      notes: store.notesInWorkspace(workspaceId),
      labels: store.labelsInWorkspace(workspaceId),
      stages: store.stagesInWorkspace(workspaceId),
      now: DateTime.now(),
    );

    if (stats.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Statistics')),
        body: const EmptyState(
          icon: Icons.insights_outlined,
          message: 'Nothing to count yet. Add a note and come back.',
        ),
      );
    }

    // Each section is numbered as it is built so the entrance cascades down
    // the page rather than restarting per section.
    var row = 0;
    Widget staggered(Widget child) =>
        StaggeredEntrance(index: row++, child: child);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Statistics'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                workspace.name,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              staggered(_Overview(stats: stats)),
              if (stats.byKind.isNotEmpty) ...[
                const Divider(height: 32),
                const SectionHeader('Content'),
                staggered(_ContentMix(stats: stats)),
              ],
              if (stats.checklistItems > 0) ...[
                const Divider(height: 32),
                const SectionHeader('Checklists'),
                staggered(_Checklists(stats: stats)),
              ],
              const Divider(height: 32),
              const SectionHeader('Activity'),
              staggered(_Activity(stats: stats, settings: settings)),
              if (stats.labelCount > 0) ...[
                const Divider(height: 32),
                const SectionHeader('Labels'),
                staggered(_Labels(stats: stats)),
              ],
              if (workspace.boardEnabled && stats.byStage.isNotEmpty) ...[
                const Divider(height: 32),
                const SectionHeader('Board'),
                staggered(_Board(stats: stats)),
              ],
              if (stats.byAuthor.isNotEmpty) ...[
                const Divider(height: 32),
                const SectionHeader('People'),
                staggered(_People(stats: stats)),
              ],
              if (stats.attachmentCount > 0) ...[
                const Divider(height: 32),
                const SectionHeader('Attachments'),
                staggered(_Attachments(stats: stats)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sections

class _Overview extends StatelessWidget {
  final WorkspaceStats stats;
  const _Overview({required this.stats});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _StatCard(
          icon: Icons.sticky_note_2_outlined,
          value: stats.activeNotes,
          label: 'Notes',
          emphasized: true,
        ),
        _StatCard(
          icon: Icons.archive_outlined,
          value: stats.archived,
          label: 'Archived',
        ),
        _StatCard(
          icon: Icons.delete_outline,
          value: stats.trashed,
          label: 'In trash',
        ),
        _StatCard(
          icon: Icons.notifications_none,
          value: stats.withReminders,
          label: 'Reminders',
        ),
      ],
    );
  }
}

class _ContentMix extends StatelessWidget {
  final WorkspaceStats stats;
  const _ContentMix({required this.stats});

  static String _label(NoteKind kind) => switch (kind) {
    NoteKind.text => 'Text',
    NoteKind.checklist => 'Checklists',
    NoteKind.markdown => 'Markdown',
    NoteKind.audio => 'Audio',
  };

  @override
  Widget build(BuildContext context) {
    final palette = _seriesColors(context);
    return _Breakdown(
      slices: [
        for (final (i, slice) in stats.byKind.indexed)
          _BarSlice(
            label: _label(slice.value),
            count: slice.count,
            color: palette[i % palette.length],
          ),
      ],
      total: stats.liveNotes,
    );
  }
}

class _Checklists extends StatelessWidget {
  final WorkspaceStats stats;
  const _Checklists({required this.stats});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final progress = stats.checklistProgress ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${stats.checklistDone} of ${stats.checklistItems} items ticked',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              Text(
                '${(progress * 100).round()}%',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: progress),
            duration: Motion.base,
            curve: Motion.standard,
            builder: (context, value, _) => ClipRRect(
              borderRadius: kBorderRadius,
              child: LinearProgressIndicator(value: value, minHeight: 8),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            stats.completedLists == 0
                ? 'No list is finished yet'
                : '${stats.completedLists} ${stats.completedLists == 1 ? 'list is' : 'lists are'} fully ticked off',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _Activity extends StatelessWidget {
  final WorkspaceStats stats;
  final SettingsStore settings;

  const _Activity({required this.stats, required this.settings});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busiest = stats.busiestMonth;
    final created = stats.firstCreated;
    final edited = stats.lastEdited;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Notes created each month',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 96,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final (i, month) in stats.monthlyCreated.indexed)
                  Expanded(
                    child: _MonthBar(
                      activity: month,
                      busiest: busiest,
                      index: i,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (created != null)
            _FactRow(
              icon: Icons.flag_outlined,
              label: 'First note',
              value: settings.formatDate(created),
            ),
          if (edited != null)
            _FactRow(
              icon: Icons.edit_outlined,
              label: 'Last edited',
              value: settings.editedLabel(edited),
            ),
        ],
      ),
    );
  }
}

class _Labels extends StatelessWidget {
  final WorkspaceStats stats;
  const _Labels({required this.stats});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            stats.unusedLabels == 0
                ? '${stats.labelCount} ${stats.labelCount == 1 ? 'label' : 'labels'}, all in use'
                : '${stats.labelCount} ${stats.labelCount == 1 ? 'label' : 'labels'}, '
                      '${stats.unusedLabels} on no note',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (stats.topLabels.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final slice in stats.topLabels)
                  Chip(
                    avatar: Icon(
                      labelIcon(slice.value),
                      size: 18,
                      color: labelColor(slice.value, scheme.onSurfaceVariant),
                    ),
                    label: Text('${slice.value.name}  ${slice.count}'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Board extends StatelessWidget {
  final WorkspaceStats stats;
  const _Board({required this.stats});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = _seriesColors(context);
    return _Breakdown(
      slices: [
        for (final (i, slice) in stats.byStage.indexed)
          _BarSlice(
            label: slice.value?.name ?? 'Unassigned',
            count: slice.count,
            color: slice.value == null
                ? scheme.outlineVariant
                : PaletteEntry.hexToColor(slice.value!.color) ??
                      palette[i % palette.length],
          ),
      ],
      total: stats.byStage.fold(0, (sum, slice) => sum + slice.count),
    );
  }
}

class _People extends StatelessWidget {
  final WorkspaceStats stats;
  const _People({required this.stats});

  @override
  Widget build(BuildContext context) {
    final palette = _seriesColors(context);
    return _Breakdown(
      slices: [
        for (final (i, slice) in stats.byAuthor.indexed)
          _BarSlice(
            label: slice.value.name,
            count: slice.count,
            color: palette[i % palette.length],
          ),
      ],
      total: stats.byAuthor.fold(0, (sum, slice) => sum + slice.count),
      countLabel: 'notes written',
    );
  }
}

class _Attachments extends StatelessWidget {
  final WorkspaceStats stats;
  const _Attachments({required this.stats});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FactRow(
            icon: Icons.attachment_outlined,
            label: 'Files',
            value:
                '${stats.attachmentCount} · ${formatBytes(stats.attachmentBytes)}',
          ),
          if (stats.imageCount > 0)
            _FactRow(
              icon: Icons.image_outlined,
              label: 'Pictures',
              value: '${stats.imageCount}',
            ),
          if (stats.audioCount > 0)
            _FactRow(
              icon: Icons.graphic_eq,
              label: 'Recordings',
              value: '${stats.audioCount}',
            ),
          if (stats.fileCount > 0)
            _FactRow(
              icon: Icons.insert_drive_file_outlined,
              label: 'Documents',
              value: '${stats.fileCount}',
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pieces

/// The series colours breakdown bars cycle through. Derived from the theme, so
/// they follow the user's accent instead of hardcoding a palette.
List<Color> _seriesColors(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return [
    scheme.primary,
    scheme.tertiary,
    scheme.secondary,
    scheme.primaryContainer,
    scheme.tertiaryContainer,
  ];
}

/// A headline count. The first card of a row is emphasized, so the eye lands
/// on the number that matters before reading the rest.
class _StatCard extends StatelessWidget {
  final IconData icon;
  final int value;
  final String label;
  final bool emphasized;

  const _StatCard({
    required this.icon,
    required this.value,
    required this.label,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = emphasized ? scheme.onPrimaryContainer : scheme.onSurface;
    return Container(
      width: 140,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: emphasized ? scheme.primaryContainer : scheme.surfaceContainerLow,
        borderRadius: kBorderRadius,
        border: Border.all(
          color: emphasized ? Colors.transparent : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 20,
            color: emphasized ? foreground : scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 8),
          // Counts change as notes sync in; rolling to the new number keeps
          // the card from blinking a different figure.
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: value.toDouble()),
            duration: Motion.base,
            curve: Motion.standard,
            builder: (context, animated, _) => Text(
              animated.round().toString(),
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: emphasized ? foreground : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// One segment of a proportion bar, and its legend row.
class _BarSlice {
  final String label;
  final int count;
  final Color color;

  const _BarSlice({
    required this.label,
    required this.count,
    required this.color,
  });
}

/// A stacked proportion bar with a counted legend below it. Empty slices keep
/// their legend row (a board column with no cards is worth seeing) but take no
/// width in the bar.
class _Breakdown extends StatelessWidget {
  final List<_BarSlice> slices;
  final int total;

  /// Trailing noun for the legend counts, when "notes" is not what is counted.
  final String? countLabel;

  const _Breakdown({
    required this.slices,
    required this.total,
    this.countLabel,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final safeTotal = total == 0 ? 1 : total;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: Motion.base,
            curve: Motion.standard,
            builder: (context, grown, _) => ClipRRect(
              borderRadius: kBorderRadius,
              child: SizedBox(
                height: 10,
                child: Row(
                  children: [
                    for (final slice in slices)
                      if (slice.count > 0)
                        Expanded(
                          flex: (slice.count * 1000 * grown).round().clamp(
                            1,
                            1 << 30,
                          ),
                          child: ColoredBox(color: slice.color),
                        ),
                    // The unfilled remainder while the bar grows in.
                    if (grown < 1)
                      Expanded(
                        flex: ((1 - grown) * safeTotal * 1000).round().clamp(
                          1,
                          1 << 30,
                        ),
                        child: ColoredBox(color: scheme.surfaceContainerHighest),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          for (final slice in slices)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: slice.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      slice.label,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  Text(
                    countLabel == null
                        ? '${slice.count}'
                        : '${slice.count} $countLabel',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One bar of the monthly activity chart, with its month initial beneath.
class _MonthBar extends StatelessWidget {
  final MonthlyActivity activity;
  final int busiest;
  final int index;

  const _MonthBar({
    required this.activity,
    required this.busiest,
    required this.index,
  });

  static const _initials = [
    'J',
    'F',
    'M',
    'A',
    'M',
    'J',
    'J',
    'A',
    'S',
    'O',
    'N',
    'D',
  ];

  /// The shortest a bar with anything in it may be drawn, as a fraction of the
  /// column, so a single note never reads as an empty month.
  static const _floor = 0.06;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fraction = busiest == 0 || activity.created == 0
        ? 0.0
        : ((activity.created / busiest).clamp(0.0, 1.0) * (1 - _floor)) + _floor;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(
            activity.created == 0 ? '' : '${activity.created}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          // The bar takes whatever the labels leave, and is sized as a
          // fraction of that: arithmetic on font metrics would overflow the
          // chart the moment a text scale factor moved.
          Expanded(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: fraction),
              duration: Motion.base,
              curve: Motion.standard,
              builder: (context, value, _) => Align(
                alignment: Alignment.bottomCenter,
                // Quiet months keep a hairline, so the axis stays readable.
                heightFactor: 1,
                child: FractionallySizedBox(
                  alignment: Alignment.bottomCenter,
                  heightFactor: value.clamp(0.0, 1.0),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 3),
                    decoration: BoxDecoration(
                      color: activity.created == 0
                          ? scheme.surfaceContainerHighest
                          : scheme.primary,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(3),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _initials[activity.month.month - 1],
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// A labelled figure that isn't worth a chart.
class _FactRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _FactRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
