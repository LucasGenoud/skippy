import 'package:flutter/material.dart';

import '../../state/tracker.dart';
import '../../theme.dart';
import '../../util/motion.dart';
import 'tracker_editor.dart' show AnimatedCount;

/// Days of history a habit card shows, ending today.
const int _recentDays = 7;
const double _recentDotSize = 10;

/// A tracker at card size: the count or streak, and a button that counts or
/// ticks off today without opening the note.
class TrackerCard extends StatelessWidget {
  final Tracker tracker;
  final DateTime today;

  /// Null on a card that cannot be edited, such as one in the trash.
  final ValueChanged<Tracker>? onChanged;

  const TrackerCard({
    super.key,
    required this.tracker,
    required this.today,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final change = onChanged;
    final caption = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final number = theme.textTheme.headlineMedium?.copyWith(
      fontWeight: FontWeight.w600,
    );
    final doneToday = tracker.on(today) > 0;

    final (Widget summary, Widget action) = switch (tracker.style) {
      TrackerStyle.count => (
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedCount(value: tracker.total, style: number),
            Text('${tracker.on(today)} today', style: caption),
          ],
        ),
        IconButton.filledTonal(
          tooltip: 'Add one',
          icon: const Icon(Icons.add),
          onPressed: change == null
              ? null
              : () => change(tracker.add(today, 1)),
        ),
      ),
      TrackerStyle.habit => (
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedCount(value: tracker.streak(today), style: number),
            Text('day streak', style: caption),
          ],
        ),
        IconButton.filledTonal(
          tooltip: doneToday ? 'Done today' : 'Mark today done',
          isSelected: doneToday,
          icon: const Icon(Icons.check),
          onPressed: change == null
              ? null
              : () => change(tracker.toggle(today)),
        ),
      ),
    };

    // The week of dots runs under the button too: beside it there is no
    // room on a phone's two-column grid.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: summary),
            action,
          ],
        ),
        if (tracker.style == TrackerStyle.habit) ...[
          const SizedBox(height: kSpaceSm),
          _RecentDays(tracker: tracker, today: today),
        ],
      ],
    );
  }
}

/// The last week as a row of dots, filled for the days done.
class _RecentDays extends StatelessWidget {
  final Tracker tracker;
  final DateTime today;

  const _RecentDays({required this.tracker, required this.today});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (var back = _recentDays - 1; back >= 0; back--)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: kSpaceXs),
            child: AnimatedContainer(
              duration: Motion.fast,
              curve: Motion.standard,
              width: _recentDotSize,
              height: _recentDotSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color:
                    tracker.on(
                          DateTime(today.year, today.month, today.day - back),
                        ) >
                        0
                    ? scheme.primaryContainer
                    : hairlineColor(scheme),
              ),
            ),
          ),
      ],
    );
  }
}
