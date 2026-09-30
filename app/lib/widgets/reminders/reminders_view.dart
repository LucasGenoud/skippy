import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/note.dart';
import '../../models/saved_location.dart';
import '../../state/notes_store.dart';
import '../../state/reminder_agenda.dart';
import '../../state/settings_store.dart';
import '../../theme.dart';
import '../../util/location_geofences.dart';
import '../../util/motion.dart';
import '../../util/search_query.dart';
import '../../util/snack.dart';
import '../animated_presence.dart';
import '../animated_reveal.dart';
import '../empty_state.dart';
import '../page_header.dart';
import 'reminder_calendar.dart';
import 'reminder_editing.dart';
import 'reminder_tiles.dart';

/// Below this the calendar and the agenda take turns; above it they sit side
/// by side.
const double _twoPaneBreakpoint = 840;
const double _calendarPaneWidth = 360;

/// Lists never stretch wider than this; a row's time drifting half a screen
/// away from its title is harder to read, not easier.
const double _listMaxWidth = 720;

/// Room under the last row for the phone's floating new-note buttons.
const double _fabClearance = 96;

const List<String> _weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// How a narrow screen shows reminders. Wide screens show both at once.
enum _Mode { agenda, calendar }

/// Whether the calendar and the agenda share the width or take turns. With
/// two panes, place reminders move under the calendar and the agenda hugs it.
enum _Panes { one, two }

/// The Reminders destination: every reminder in the open workspace, timed or
/// at a place, as a day-by-day agenda and a month calendar.
///
/// ```text
///   wide                               narrow
///   +-----------+------------------+   +---------------------+
///   | calendar  | Today            |   | [Agenda | Calendar] |
///   |           |   09:00 ...      |   | Today               |
///   | At a place| Tomorrow         |   |   09:00 ...         |
///   |   ...     |   ...            |   | At a place ...      |
///   +-----------+------------------+   +---------------------+
/// ```
///
/// Picking a day on a wide calendar narrows the agenda to it; on a phone the
/// calendar tab lists the picked day under the month.
class RemindersView extends StatefulWidget {
  /// The home screen's search box, applied like it is to the grid.
  final String query;

  const RemindersView({super.key, this.query = ''});

  @override
  State<RemindersView> createState() => _RemindersViewState();
}

class _RemindersViewState extends State<RemindersView> {
  _Mode _mode = _Mode.agenda;
  DateTime? _selectedDay;
  bool _showEarlier = false;
  DateTime _now = DateTime.now();

  /// Keeps "past" styling and the Today group honest while the view sits open.
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(
      const Duration(minutes: 1),
      (_) => setState(() => _now = DateTime.now()),
    );
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  List<Note> _matching(List<Note> notes) {
    final query = parseSearchQuery(widget.query);
    final search = SearchContext(context.read<NotesStore>().labels);
    return [
      for (final note in notes)
        if (!note.trashed && query.matches(note, search)) note,
    ];
  }

  /// A wide calendar's day narrows the agenda; picking it again widens it.
  void _toggleDay(DateTime day) =>
      setState(() => _selectedDay = _selectedDay == day ? null : day);

  void _moveToDay(ReminderOccurrence reminder, DateTime day) {
    final store = context.read<NotesStore>();
    final settings = context.read<SettingsStore>();
    rescheduleReminder(store, reminder, movedToDay(reminder.at, day));
    showAppSnack(
      'Moved to ${settings.formatDate(day, withYear: day.year != _now.year)}',
      icon: Icons.event_outlined,
      actionLabel: 'Undo',
      onAction: () => rescheduleReminder(store, reminder, reminder.at),
    );
  }

  void _clearEarlier(List<ReminderOccurrence> earlier) {
    final store = context.read<NotesStore>();
    for (final reminder in earlier) {
      rescheduleReminder(store, reminder, null);
    }
    showAppSnack(
      earlier.length == 1
          ? 'Cleared 1 past reminder'
          : 'Cleared ${earlier.length} past reminders',
      icon: Icons.notifications_off_outlined,
      actionLabel: 'Undo',
      onAction: () {
        for (final reminder in earlier) {
          rescheduleReminder(store, reminder, reminder.at);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final notes = context.select<NotesStore, List<Note>>(
      (s) => s.displayNotesInActiveWorkspace,
    );
    final location = context.select<SettingsStore, _LocationSettings>(
      (s) => (reminders: s.locationReminders, places: s.savedLocations),
    );
    final visible = _matching(notes);
    final scheduled = scheduledReminders(visible);
    final places = placeReminders(
      notes: visible,
      reminders: location.reminders,
      places: location.places,
    );
    final summary = _summary(scheduled, places);
    return LayoutBuilder(
      builder: (context, constraints) =>
          constraints.maxWidth >= _twoPaneBreakpoint
          ? _twoPanes(scheduled, places, summary)
          : _onePane(scheduled, places, summary),
    );
  }

  Widget _twoPanes(
    List<ReminderOccurrence> scheduled,
    List<PlaceReminder> places,
    String summary,
  ) {
    const pad = 32.0;
    final header = _Header(summary: summary);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: pad),
      child: Column(
        children: [
          header,
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: _calendarPaneWidth,
                  child: ListView(
                    padding: const EdgeInsets.only(
                      top: kSpaceSm,
                      bottom: kSpaceLg,
                    ),
                    children: [
                      _CalendarCard(
                        child: ReminderCalendar(
                          scheduled: scheduled,
                          now: _now,
                          selectedDay: _selectedDay,
                          onDaySelected: _toggleDay,
                          onReminderDropped: _moveToDay,
                        ),
                      ),
                      _PlacesSection(places: places),
                    ],
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: _Fade(
                    child: _selectedDay == null
                        ? _agenda(scheduled, places, _Panes.two)
                        : _dayList(
                            scheduled,
                            _selectedDay!,
                            onClose: () => setState(() => _selectedDay = null),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _onePane(
    List<ReminderOccurrence> scheduled,
    List<PlaceReminder> places,
    String summary,
  ) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kSpaceLg),
          child: _Header(
            summary: summary,
            mode: _mode,
            onMode: (mode) => setState(() => _mode = mode),
          ),
        ),
        Expanded(
          child: _Fade(
            child: switch (_mode) {
              _Mode.agenda => _agenda(scheduled, places, _Panes.one),
              _Mode.calendar => _calendarTab(scheduled),
            },
          ),
        ),
      ],
    );
  }

  String _summary(
    List<ReminderOccurrence> scheduled,
    List<PlaceReminder> places,
  ) {
    final today = dayOf(_now);
    final laterToday = scheduled
        .where((r) => r.at.isAfter(_now) && dayOf(r.at) == today)
        .length;
    final upcoming = scheduled.where((r) => r.at.isAfter(_now)).length;
    final parts = [
      if (laterToday > 0) '$laterToday later today',
      if (upcoming > 0) '$upcoming upcoming',
      if (places.isNotEmpty)
        places.length == 1 ? '1 at a place' : '${places.length} at places',
    ];
    return parts.isEmpty ? 'Nothing coming up' : parts.join(' · ');
  }

  /// Every reminder from today on, one group per day, after a folded group of
  /// earlier ones, then [places] when the calendar is not showing them.
  Widget _agenda(
    List<ReminderOccurrence> scheduled,
    List<PlaceReminder> places,
    _Panes panes,
  ) {
    final agenda = agendaFor(scheduled, _now);
    final List<PlaceReminder> inlinePlaces = panes == _Panes.one
        ? places
        : const [];
    if (agenda.earlier.isEmpty && agenda.days.isEmpty && inlinePlaces.isEmpty) {
      final searching = widget.query.trim().isNotEmpty;
      return EmptyState(
        key: const ValueKey('empty'),
        icon: searching ? Icons.search_off : Icons.notifications_outlined,
        message: switch ((searching, places.isEmpty)) {
          (true, _) => 'No matching reminders',
          (false, true) => 'Notes with reminders appear here',
          (false, false) => 'Nothing scheduled for a time',
        },
      );
    }
    final earlier = agenda.earlier;
    return _ScrollingList(
      key: const ValueKey('agenda'),
      panes: panes,
      children: [
        if (earlier.isNotEmpty)
          Column(
            key: const ValueKey('earlier'),
            children: [
              ReminderGroupHeader(
                title: 'Earlier',
                count: _showEarlier ? null : earlier.length,
                trailing: _EarlierActions(
                  expanded: _showEarlier,
                  onToggle: () => setState(() => _showEarlier = !_showEarlier),
                  onClear: () => _clearEarlier(earlier),
                ),
              ),
              AnimatedReveal(
                child: _showEarlier
                    ? ReminderGroup(
                        children: [
                          for (final reminder in earlier)
                            ReminderTile(
                              key: ValueKey(reminder.key),
                              reminder: reminder,
                              now: _now,
                              timeStyle: ReminderTimeStyle.dayAndClock,
                            ),
                        ],
                      )
                    : null,
              ),
            ],
          ),
        for (final day in agenda.days)
          Column(
            key: ValueKey(day.day),
            children: [
              _DayHeader(day: day.day, now: _now, count: day.reminders.length),
              ReminderGroup(
                children: [
                  for (final reminder in day.reminders)
                    ReminderTile(
                      key: ValueKey(reminder.key),
                      reminder: reminder,
                      now: _now,
                    ),
                ],
              ),
            ],
          ),
        if (inlinePlaces.isNotEmpty)
          _PlacesSection(key: const ValueKey('places'), places: inlinePlaces),
      ],
    );
  }

  /// One day's reminders, repeats included, for a day picked on the calendar.
  Widget _dayList(
    List<ReminderOccurrence> scheduled,
    DateTime day, {
    VoidCallback? onClose,
  }) {
    return _ScrollingList(
      key: ValueKey(('day', day)),
      panes: _Panes.two,
      children: [
        _DaySection(
          key: ValueKey(day),
          day: day,
          now: _now,
          scheduled: scheduled,
          onClose: onClose,
        ),
      ],
    );
  }

  /// A phone's calendar tab: the month, then the picked day under it.
  Widget _calendarTab(List<ReminderOccurrence> scheduled) {
    final day = _selectedDay ?? dayOf(_now);
    return _ScrollingList(
      key: const ValueKey('calendar'),
      panes: _Panes.one,
      children: [
        Padding(
          key: const ValueKey('month'),
          padding: const EdgeInsets.only(top: kSpaceSm),
          child: _CalendarCard(
            child: ReminderCalendar(
              scheduled: scheduled,
              now: _now,
              selectedDay: day,
              onDaySelected: (day) => setState(() => _selectedDay = day),
              onReminderDropped: _moveToDay,
            ),
          ),
        ),
        _DaySection(
          key: const ValueKey('picked'),
          day: day,
          now: _now,
          scheduled: scheduled,
        ),
      ],
    );
  }
}

typedef _LocationSettings = ({
  List<LocationReminder> reminders,
  List<SavedLocation> places,
});

/// The view's title line, with the agenda/calendar switch on a phone.
class _Header extends StatelessWidget {
  final String summary;

  /// Null on a wide screen, which shows both and needs no switch.
  final _Mode? mode;
  final ValueChanged<_Mode>? onMode;

  const _Header({required this.summary, this.mode, this.onMode});

  @override
  Widget build(BuildContext context) {
    final mode = this.mode;
    // The grid opens a gap above its own header; match it.
    return Padding(
      padding: const EdgeInsets.only(top: kSpaceLg),
      child: PageHeader(
        title: 'Reminders',
        subtitle: summary,
        trailing: mode == null
            ? null
            : SegmentedButton<_Mode>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(
                    value: _Mode.agenda,
                    icon: Icon(Icons.view_agenda_outlined),
                    tooltip: 'Agenda',
                  ),
                  ButtonSegment(
                    value: _Mode.calendar,
                    icon: Icon(Icons.calendar_month_outlined),
                    tooltip: 'Calendar',
                  ),
                ],
                selected: {mode},
                onSelectionChanged: (selected) => onMode?.call(selected.single),
              ),
      ),
    );
  }
}

/// A day's group title: "Today  Wed 7 Oct", "Friday  9 Oct", "14 Nov
/// Saturday".
class _DayHeader extends StatelessWidget {
  final DateTime day;
  final DateTime now;
  final int? count;
  final Widget? trailing;

  const _DayHeader({
    required this.day,
    required this.now,
    this.count,
    this.trailing,
  });

  /// Whole days from [from] to [to], counted on the calendar rather than in
  /// hours, so a daylight-saving night still counts as one day.
  static int _daysBetween(DateTime from, DateTime to) => DateTime.utc(
    to.year,
    to.month,
    to.day,
  ).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

  @override
  Widget build(BuildContext context) {
    final date = context.select<SettingsStore, String>(
      (s) => s.formatDate(day, withYear: day.year != now.year),
    );
    final weekday = _weekdayNames[day.weekday - 1];
    final offset = _daysBetween(now, day);
    final relative = switch (offset) {
      -1 => 'Yesterday',
      0 => 'Today',
      1 => 'Tomorrow',
      > 1 && < DateTime.daysPerWeek => weekday,
      _ => null,
    };
    return ReminderGroupHeader(
      title: relative ?? date,
      subtitle: relative == null
          ? weekday
          : relative == weekday
          ? date
          : '$weekday, $date',
      count: count,
      highlighted: offset == 0,
      trailing: trailing,
    );
  }
}

/// The reminders on one picked day, forecast repeats included.
class _DaySection extends StatelessWidget {
  final DateTime day;
  final DateTime now;
  final List<ReminderOccurrence> scheduled;

  /// Shows a way back to the full agenda, on a wide screen.
  final VoidCallback? onClose;

  const _DaySection({
    super.key,
    required this.day,
    required this.now,
    required this.scheduled,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reminders = occurrencesBetween(
      scheduled,
      day,
      DateTime(day.year, day.month, day.day + 1),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DayHeader(
          day: day,
          now: now,
          count: onClose == null ? reminders.length : null,
          trailing: onClose == null
              ? null
              : TextButton.icon(
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('All reminders'),
                ),
        ),
        AnimatedSize(
          duration: Motion.base,
          curve: Motion.emphasized,
          alignment: Alignment.topCenter,
          child: reminders.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(kSpaceLg),
                  child: Text(
                    'No reminders on this day',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ReminderGroup(
                  children: [
                    for (final reminder in reminders)
                      ReminderTile(
                        key: ValueKey(reminder.key),
                        reminder: reminder,
                        now: now,
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Notes reminded at a saved place. They have no day, so they get a section
/// of their own.
class _PlacesSection extends StatelessWidget {
  final List<PlaceReminder> places;

  const _PlacesSection({super.key, required this.places});

  @override
  Widget build(BuildContext context) {
    return AnimatedReveal(
      child: places.isEmpty
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ReminderGroupHeader(
                  title: 'At a place',
                  // Places are watched by the phone; say so where they are
                  // shown but cannot fire.
                  subtitle: LocationGeofences.supported
                      ? null
                      : 'Arrives on your phone',
                  count: places.length,
                ),
                ReminderGroup(
                  children: [
                    for (final place in places)
                      PlaceReminderTile(
                        key: ValueKey(place.note.id),
                        reminder: place,
                      ),
                  ],
                ),
              ],
            ),
    );
  }
}

/// "Show" / "Hide" and, once shown, "Clear" for the earlier group.
class _EarlierActions extends StatelessWidget {
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onClear;

  const _EarlierActions({
    required this.expanded,
    required this.onToggle,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSwitcher(
          duration: Motion.fast,
          switchInCurve: Motion.standard,
          switchOutCurve: Motion.standard,
          child: expanded
              ? TextButton(onPressed: onClear, child: const Text('Clear all'))
              : const SizedBox.shrink(),
        ),
        IconButton(
          tooltip: expanded ? 'Hide earlier' : 'Show earlier',
          onPressed: onToggle,
          icon: AnimatedRotation(
            turns: expanded ? 0.5 : 0,
            duration: Motion.base,
            curve: Motion.emphasized,
            child: const Icon(Icons.expand_more),
          ),
        ),
      ],
    );
  }
}

/// The surface the month sits on.
class _CalendarCard extends StatelessWidget {
  final Widget child;

  const _CalendarCard({required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: kBorderRadius,
        border: Border.all(color: hairlineColor(scheme)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          kSpaceXs,
          kSpaceXs,
          kSpaceXs,
          kSpaceSm,
        ),
        child: child,
      ),
    );
  }
}

/// A pull-to-refresh column of keyed sections, capped to a readable width.
/// Sections that come and go (a day's last reminder done) fold away rather
/// than popping.
class _ScrollingList extends StatelessWidget {
  final List<Widget> children;

  /// Centred with side gutters in one pane; against the calendar in two,
  /// where the view already pads the edges.
  final _Panes panes;

  const _ScrollingList({
    super.key,
    required this.children,
    required this.panes,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final gutter = panes == _Panes.one ? kSpaceLg : 0.0;
    return RefreshIndicator(
      onRefresh: context.read<NotesStore>().refresh,
      color: scheme.primary,
      backgroundColor: scheme.surfaceContainerHigh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(gutter, 0, gutter, _fabClearance),
        children: [
          Align(
            alignment: panes == _Panes.one
                ? Alignment.topCenter
                : AlignmentDirectional.topStart,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _listMaxWidth),
              child: AnimatedPresence(
                layout: (children) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Cross-fades between the view's panes (agenda, a picked day, the month).
class _Fade extends StatelessWidget {
  final Widget child;

  const _Fade({required this.child});

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: Motion.reduced(context) ? Duration.zero : Motion.base,
    switchInCurve: Motion.standard,
    switchOutCurve: Motion.standard,
    layoutBuilder: (current, previous) => Stack(
      alignment: Alignment.topCenter,
      children: [...previous, ?current],
    ),
    child: child,
  );
}
