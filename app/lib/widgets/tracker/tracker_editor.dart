import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/settings_store.dart';
import '../../state/tracker.dart';
import '../../theme.dart';
import '../../util/motion.dart';
import '../state_cross_fade.dart';

/// The big counter button and its smaller undo neighbour.
const double _plusSize = 72;
const double _minusSize = 52;

/// A calendar always shows six weeks, so changing month never moves what
/// sits under it.
const int _weeksShown = 6;
const double _dayCellHeight = 44;
const double _dayMarkSize = 34;

/// The editor's body for a tracker note: a style switch over either a tally
/// with plus and minus, or a month calendar of days ticked off. Every tap is
/// handed to [onChanged] whole, so each is one undo step.
class TrackerEditor extends StatelessWidget {
  final Tracker tracker;
  final DateTime today;
  final ValueChanged<Tracker>? onChanged;

  const TrackerEditor({
    super.key,
    required this.tracker,
    required this.today,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final change = onChanged;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: SegmentedButton<TrackerStyle>(
            showSelectedIcon: false,
            segments: [
              for (final style in TrackerStyle.values)
                ButtonSegment(value: style, label: Text(style.label)),
            ],
            selected: {tracker.style},
            onSelectionChanged: change == null
                ? null
                : (picked) => change(tracker.withStyle(picked.single)),
          ),
        ),
        const SizedBox(height: kSpaceLg),
        StateCrossFade(
          state: tracker.style,
          child: switch (tracker.style) {
            TrackerStyle.count => _CountView(
              tracker: tracker,
              today: today,
              onChanged: change,
            ),
            TrackerStyle.habit => _HabitView(
              tracker: tracker,
              today: today,
              onChanged: change,
            ),
          },
        ),
      ],
    );
  }
}

class _CountView extends StatelessWidget {
  final Tracker tracker;
  final DateTime today;
  final ValueChanged<Tracker>? onChanged;

  const _CountView({
    required this.tracker,
    required this.today,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final change = onChanged;
    final todayCount = tracker.on(today);
    return Column(
      children: [
        AnimatedCount(
          value: tracker.total,
          style: theme.textTheme.displayLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          '$todayCount today',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: kSpaceLg),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _RoundButton(
              size: _minusSize,
              tooltip: 'Take one off today',
              icon: Icons.remove,
              fill: toolbarTrayColor(scheme),
              ink: scheme.onSurface,
              onPressed: change == null || todayCount == 0
                  ? null
                  : () => change(tracker.add(today, -1)),
            ),
            const SizedBox(width: kSpaceLg),
            _RoundButton(
              size: _plusSize,
              tooltip: 'Add one',
              icon: Icons.add,
              fill: scheme.primaryContainer,
              ink: scheme.onPrimaryContainer,
              onPressed: change == null
                  ? null
                  : () => change(tracker.add(today, 1)),
            ),
          ],
        ),
      ],
    );
  }
}

class _HabitView extends StatefulWidget {
  final Tracker tracker;
  final DateTime today;
  final ValueChanged<Tracker>? onChanged;

  const _HabitView({
    required this.tracker,
    required this.today,
    required this.onChanged,
  });

  @override
  State<_HabitView> createState() => _HabitViewState();
}

class _HabitViewState extends State<_HabitView> {
  late DateTime _month = DateTime(widget.today.year, widget.today.month);

  /// Which way the last month change went, so the calendar slides with it.
  var _forward = true;

  void _shiftMonth(int by) => setState(() {
    _forward = by > 0;
    _month = DateTime(_month.year, _month.month + by);
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tracker = widget.tracker;
    final today = widget.today;
    final change = widget.onChanged;
    final doneToday = tracker.on(today) > 0;
    final firstWeekday = context.select<SettingsStore, int>(
      (s) => s.firstWeekday,
    );
    final labels = MaterialLocalizations.of(context);
    final atCurrentMonth =
        _month.year == today.year && _month.month == today.month;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _Stat(value: tracker.streak(today), label: 'day streak'),
            ),
            Expanded(
              child: _Stat(
                value: tracker.daysInMonth(today),
                label: 'days this month',
              ),
            ),
          ],
        ),
        const SizedBox(height: kSpaceLg),
        Center(
          child: FilledButton.tonalIcon(
            onPressed: change == null
                ? null
                : () => change(tracker.toggle(today)),
            icon: Icon(doneToday ? Icons.check_circle : Icons.circle_outlined),
            label: Text(doneToday ? 'Done today' : 'Mark today done'),
          ),
        ),
        const SizedBox(height: kSpaceLg),
        Row(
          children: [
            IconButton(
              tooltip: 'Previous month',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => _shiftMonth(-1),
            ),
            Expanded(
              child: StateCrossFade(
                state: _month,
                alignment: Alignment.center,
                child: Text(
                  labels.formatMonthYear(_month),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Next month',
              icon: const Icon(Icons.chevron_right),
              onPressed: atCurrentMonth ? null : () => _shiftMonth(1),
            ),
          ],
        ),
        Row(
          children: [
            for (var i = 0; i < DateTime.daysPerWeek; i++)
              Expanded(
                child: Text(
                  // narrowWeekdays starts on Sunday, DateTime.weekday at 7.
                  labels.narrowWeekdays[(firstWeekday + i) %
                      DateTime.daysPerWeek],
                  textAlign: TextAlign.center,
                  style: sectionLabelStyle(theme),
                ),
              ),
          ],
        ),
        const SizedBox(height: kSpaceXs),
        ClipRect(
          child: AnimatedSwitcher(
            duration: Motion.reduced(context) ? Duration.zero : Motion.base,
            switchInCurve: Motion.emphasized,
            switchOutCurve: Motion.accelerate,
            transitionBuilder: (child, animation) {
              final incoming = child.key == ValueKey(_month);
              final from = (_forward == incoming) ? 0.25 : -0.25;
              return SlideTransition(
                position: Tween(
                  begin: Offset(from, 0),
                  end: Offset.zero,
                ).animate(animation),
                child: FadeTransition(opacity: animation, child: child),
              );
            },
            child: _HabitMonth(
              key: ValueKey(_month),
              month: _month,
              firstWeekday: firstWeekday,
              tracker: tracker,
              today: today,
              scheme: scheme,
              onToggle: change == null
                  ? null
                  : (day) => change(tracker.toggle(day)),
            ),
          ),
        ),
      ],
    );
  }
}

class _HabitMonth extends StatelessWidget {
  final DateTime month;
  final int firstWeekday;
  final Tracker tracker;
  final DateTime today;
  final ColorScheme scheme;
  final ValueChanged<DateTime>? onToggle;

  const _HabitMonth({
    super.key,
    required this.month,
    required this.firstWeekday,
    required this.tracker,
    required this.today,
    required this.scheme,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // Back up from the 1st to the week's first day: the grid opens on the
    // tail of the previous month.
    final lead = (month.weekday - firstWeekday) % DateTime.daysPerWeek;
    final start = DateTime(month.year, month.month, 1 - lead);
    final lastDay = DateTime(today.year, today.month, today.day);

    return Column(
      children: [
        for (var week = 0; week < _weeksShown; week++)
          SizedBox(
            height: _dayCellHeight,
            child: Row(
              children: [
                for (var weekday = 0; weekday < DateTime.daysPerWeek; weekday++)
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final day = DateTime(
                          start.year,
                          start.month,
                          start.day + week * DateTime.daysPerWeek + weekday,
                        );
                        final inMonth = day.month == month.month;
                        final future = day.isAfter(lastDay);
                        final done = tracker.on(day) > 0;
                        final isToday = day == lastDay;
                        final toggle = onToggle;
                        return Semantics(
                          button: !future,
                          checked: done,
                          label: MaterialLocalizations.of(
                            context,
                          ).formatFullDate(day),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: future || toggle == null
                                ? null
                                : () => toggle(day),
                            child: Center(
                              child: AnimatedContainer(
                                duration: Motion.fast,
                                curve: Motion.standard,
                                width: _dayMarkSize,
                                height: _dayMarkSize,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: done
                                      ? scheme.primaryContainer
                                      : Colors.transparent,
                                  border: isToday && !done
                                      ? Border.all(color: scheme.primary)
                                      : null,
                                ),
                                child: Text(
                                  '${day.day}',
                                  style: textTheme.bodyMedium?.copyWith(
                                    color: done
                                        ? scheme.onPrimaryContainer
                                        : scheme.onSurface.withValues(
                                            alpha: future || !inMonth
                                                ? 0.35
                                                : 1,
                                          ),
                                    fontWeight: done ? FontWeight.w600 : null,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final int value;
  final String label;

  const _Stat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        AnimatedCount(
          value: value,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// A number that rolls to its new value: up when it grows, down when it
/// shrinks, so a tap reads as counted.
class AnimatedCount extends StatefulWidget {
  final int value;
  final TextStyle? style;

  const AnimatedCount({super.key, required this.value, this.style});

  @override
  State<AnimatedCount> createState() => _AnimatedCountState();
}

class _AnimatedCountState extends State<AnimatedCount> {
  var _rising = true;

  @override
  void didUpdateWidget(AnimatedCount old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      _rising = widget.value > old.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = (widget.style ?? DefaultTextStyle.of(context).style).copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return ClipRect(
      child: AnimatedSwitcher(
        duration: Motion.base,
        switchInCurve: Motion.emphasized,
        switchOutCurve: Motion.accelerate,
        transitionBuilder: (child, animation) {
          final incoming = child.key == ValueKey(widget.value);
          final from = (_rising == incoming) ? 0.6 : -0.6;
          return SlideTransition(
            position: Tween(
              begin: Offset(0, from),
              end: Offset.zero,
            ).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          );
        },
        child: Text(
          '${widget.value}',
          key: ValueKey(widget.value),
          style: style,
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final double size;
  final String tooltip;
  final IconData icon;
  final Color fill;
  final Color ink;
  final VoidCallback? onPressed;

  const _RoundButton({
    required this.size,
    required this.tooltip,
    required this.icon,
    required this.fill,
    required this.ink,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: AnimatedOpacity(
        duration: Motion.fast,
        opacity: enabled ? 1 : 0.4,
        child: Material(
          color: fill,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, color: ink, size: size * 0.45),
            ),
          ),
        ),
      ),
    );
  }
}
