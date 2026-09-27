import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/reminder_agenda.dart';
import '../../state/settings_store.dart';
import '../../theme.dart';
import '../../util/motion.dart';

/// A calendar week is always drawn as six rows, so paging between months
/// never changes the calendar's height.
const int _weeksShown = 6;
const double _cellHeight = 48;
const double _dayMarkSize = 32;
const double _dotSize = 5;

/// More reminders than this on one day still show this many dots.
const int _maxDots = 3;

/// Months either side of the opening one a swipe can reach. Far more than
/// anyone scrolls; it only has to be finite for [PageView].
const int _monthsReachable = 1200;

const List<String> _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const List<String> _weekdayInitials = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

/// A month of days, each marked with how many reminders fall on it. Swipe or
/// use the arrows to change month; tap a day to see its reminders.
///
/// With a pointer, a reminder dragged from a list can be dropped on a day to
/// move it there, keeping its time.
class ReminderCalendar extends StatefulWidget {
  final List<ReminderOccurrence> scheduled;
  final DateTime now;
  final DateTime? selectedDay;
  final ValueChanged<DateTime> onDaySelected;
  final void Function(ReminderOccurrence reminder, DateTime day)
  onReminderDropped;

  const ReminderCalendar({
    super.key,
    required this.scheduled,
    required this.now,
    required this.selectedDay,
    required this.onDaySelected,
    required this.onReminderDropped,
  });

  @override
  State<ReminderCalendar> createState() => _ReminderCalendarState();
}

class _ReminderCalendarState extends State<ReminderCalendar> {
  late final DateTime _origin = _monthOf(widget.selectedDay ?? widget.now);
  final _pages = PageController(initialPage: _monthsReachable);
  int _page = _monthsReachable;

  static DateTime _monthOf(DateTime t) => DateTime(t.year, t.month);

  DateTime _monthAt(int page) =>
      DateTime(_origin.year, _origin.month + page - _monthsReachable);

  int _pageOf(DateTime month) =>
      _monthsReachable +
      (month.year - _origin.year) * DateTime.monthsPerYear +
      month.month -
      _origin.month;

  @override
  void didUpdateWidget(ReminderCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Follow a selection made elsewhere (the Today button, a day in the next
    // month's leading row) to its month.
    final selected = widget.selectedDay;
    if (selected != null && selected != oldWidget.selectedDay) {
      _showMonth(_monthOf(selected));
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _showMonth(DateTime month) {
    final page = _pageOf(month);
    if (page == _page || !_pages.hasClients) {
      return;
    }
    if (Motion.reduced(context)) {
      _pages.jumpToPage(page);
      return;
    }
    _pages.animateToPage(page, duration: Motion.slow, curve: Motion.emphasized);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Countries that write the month first also start the week on Sunday.
    final firstWeekday = context.select<SettingsStore, int>(
      (s) =>
          s.dateFormat == AppDateFormat.monthFirst ||
              s.dateFormat == AppDateFormat.numericUS
          ? DateTime.sunday
          : DateTime.monday,
    );
    final month = _monthAt(_page);
    final today = dayOf(widget.now);
    final showingToday =
        _monthOf(today) == month && widget.selectedDay == today;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const SizedBox(width: kSpaceSm),
            Expanded(
              child: AnimatedSwitcher(
                duration: Motion.fast,
                switchInCurve: Motion.standard,
                switchOutCurve: Motion.standard,
                layoutBuilder: (current, previous) => Stack(
                  alignment: AlignmentDirectional.centerStart,
                  children: [...previous, ?current],
                ),
                child: Text(
                  '${_monthNames[month.month - 1]} ${month.year}',
                  key: ValueKey(month),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            AnimatedOpacity(
              opacity: showingToday ? 0 : 1,
              duration: Motion.fast,
              curve: Motion.standard,
              child: TextButton(
                onPressed: showingToday
                    ? null
                    : () {
                        widget.onDaySelected(today);
                        _showMonth(_monthOf(today));
                      },
                child: const Text('Today'),
              ),
            ),
            IconButton(
              tooltip: 'Previous month',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => _showMonth(_monthAt(_page - 1)),
            ),
            IconButton(
              tooltip: 'Next month',
              icon: const Icon(Icons.chevron_right),
              onPressed: () => _showMonth(_monthAt(_page + 1)),
            ),
          ],
        ),
        const SizedBox(height: kSpaceXs),
        ExcludeSemantics(
          child: Row(
            children: [
              for (var i = 0; i < DateTime.daysPerWeek; i++)
                Expanded(
                  child: Center(
                    child: Text(
                      _weekdayInitials[(firstWeekday - 1 + i) %
                          DateTime.daysPerWeek],
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: kSpaceXs),
        SizedBox(
          height: _cellHeight * _weeksShown,
          child: PageView.builder(
            controller: _pages,
            itemCount: _monthsReachable * 2,
            onPageChanged: (page) => setState(() => _page = page),
            itemBuilder: (context, page) => _MonthGrid(
              month: _monthAt(page),
              firstWeekday: firstWeekday,
              scheduled: widget.scheduled,
              now: widget.now,
              selectedDay: widget.selectedDay,
              onDaySelected: widget.onDaySelected,
              onReminderDropped: widget.onReminderDropped,
            ),
          ),
        ),
      ],
    );
  }
}

class _MonthGrid extends StatelessWidget {
  final DateTime month;
  final int firstWeekday;
  final List<ReminderOccurrence> scheduled;
  final DateTime now;
  final DateTime? selectedDay;
  final ValueChanged<DateTime> onDaySelected;
  final void Function(ReminderOccurrence reminder, DateTime day)
  onReminderDropped;

  const _MonthGrid({
    required this.month,
    required this.firstWeekday,
    required this.scheduled,
    required this.now,
    required this.selectedDay,
    required this.onDaySelected,
    required this.onReminderDropped,
  });

  @override
  Widget build(BuildContext context) {
    // Back up from the 1st to the week's first day: the grid opens on the
    // tail of the previous month and closes on the head of the next one.
    final lead = (month.weekday - firstWeekday) % DateTime.daysPerWeek;
    final start = DateTime(month.year, month.month, 1 - lead);
    final end = DateTime(
      start.year,
      start.month,
      start.day + _weeksShown * DateTime.daysPerWeek,
    );
    final byDay = remindersByDay(scheduled, start, end);
    final today = dayOf(now);

    return Column(
      children: [
        for (var week = 0; week < _weeksShown; week++)
          SizedBox(
            height: _cellHeight,
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
                        return DragTarget<ReminderOccurrence>(
                          onWillAcceptWithDetails: (details) =>
                              dayOf(details.data.at) != day,
                          onAcceptWithDetails: (details) =>
                              onReminderDropped(details.data, day),
                          builder: (context, candidates, _) => _DayCell(
                            day: day,
                            inMonth: day.month == month.month,
                            isToday: day == today,
                            isSelected: day == selectedDay,
                            isPast: day.isBefore(today),
                            isDropTarget: candidates.isNotEmpty,
                            reminderCount: byDay[day]?.length ?? 0,
                            onTap: () => onDaySelected(day),
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

class _DayCell extends StatelessWidget {
  final DateTime day;
  final bool inMonth;
  final bool isToday;
  final bool isSelected;
  final bool isPast;
  final bool isDropTarget;
  final int reminderCount;
  final VoidCallback onTap;

  const _DayCell({
    required this.day,
    required this.inMonth,
    required this.isToday,
    required this.isSelected,
    required this.isPast,
    required this.isDropTarget,
    required this.reminderCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final settings = context.read<SettingsStore>();
    final Color numberColor;
    if (isSelected) {
      numberColor = scheme.onPrimaryContainer;
    } else if (isToday) {
      numberColor = scheme.primary;
    } else if (!inMonth) {
      numberColor = scheme.onSurfaceVariant.withValues(alpha: 0.5);
    } else {
      numberColor = scheme.onSurface;
    }
    final Color fill;
    if (isSelected) {
      fill = scheme.primaryContainer;
    } else if (isDropTarget) {
      fill = scheme.primaryContainer.withValues(alpha: 0.4);
    } else {
      fill = scheme.primaryContainer.withValues(alpha: 0);
    }
    final dotColor = isPast
        ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
        : scheme.primary;
    final reminders = switch (reminderCount) {
      0 => 'no reminders',
      1 => '1 reminder',
      _ => '$reminderCount reminders',
    };

    return Semantics(
      button: true,
      selected: isSelected,
      label: '${settings.formatDate(day)}, $reminders',
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        radius: _cellHeight / 2,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: Motion.fast,
              curve: Motion.standard,
              width: _dayMarkSize,
              height: _dayMarkSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fill,
                border: Border.all(
                  width: 1.5,
                  color: isToday && !isSelected
                      ? scheme.primary
                      : scheme.primary.withValues(alpha: 0),
                ),
              ),
              child: Text(
                '${day.day}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: numberColor,
                  fontWeight: isToday || isSelected ? FontWeight.w600 : null,
                ),
              ),
            ),
            const SizedBox(height: 3),
            SizedBox(
              height: _dotSize,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < reminderCount && i < _maxDots; i++)
                    Container(
                      width: _dotSize,
                      height: _dotSize,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: dotColor,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
