import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/note.dart';
import '../models/saved_location.dart';
import '../util/motion.dart';
import 'form_dialog.dart';

/// The result of editing a reminder. A null result means the picker was
/// dismissed; [at] being null means the existing reminder should be removed.
class ReminderSelection {
  final DateTime? at;
  final ReminderRepeat? repeat;
  final String? locationId;
  final LocationReminderTrigger? locationTrigger;

  /// Whether a location reminder fires on every crossing instead of retiring
  /// after the first. Meaningless for a time reminder, which says the same
  /// thing through [repeat].
  final bool locationRepeats;

  const ReminderSelection.set(this.at, {this.repeat})
    : assert(at != null),
      locationId = null,
      locationTrigger = null,
      locationRepeats = false;
  const ReminderSelection.location(
    this.locationId,
    this.locationTrigger, {
    this.locationRepeats = false,
  }) : assert(locationId != null),
       assert(locationTrigger != null),
       at = null,
       repeat = null;
  const ReminderSelection.clear()
    : at = null,
      repeat = null,
      locationId = null,
      locationTrigger = null,
      locationRepeats = false;
}

class ReminderPreset {
  final String id;
  final String label;
  final DateTime at;

  const ReminderPreset({
    required this.id,
    required this.label,
    required this.at,
  });
}

/// Builds the quick actions independently from the UI so their date
/// arithmetic remains easy to test.
List<ReminderPreset> reminderPresets(DateTime now) {
  final daysUntilNextMonday = DateTime.monday - now.weekday;
  final nextMondayOffset = daysUntilNextMonday <= 0
      ? daysUntilNextMonday + 7
      : daysUntilNextMonday;
  final nextMonday = DateTime(
    now.year,
    now.month,
    now.day + nextMondayOffset,
    9,
  );
  final inSevenDays = DateTime(
    now.year,
    now.month,
    now.day + 7,
    now.hour,
    now.minute,
  );

  return [
    ReminderPreset(
      id: 'tomorrow-morning',
      label: 'Tomorrow morning',
      at: DateTime(now.year, now.month, now.day + 1, 9),
    ),
    ReminderPreset(
      id: 'tomorrow-noon',
      label: 'Tomorrow at noon',
      at: DateTime(now.year, now.month, now.day + 1, 12),
    ),
    ReminderPreset(
      id: 'tomorrow-evening',
      label: 'Tomorrow evening',
      at: DateTime(now.year, now.month, now.day + 1, 18),
    ),
    ReminderPreset(id: 'next-week', label: 'Next week', at: nextMonday),
    ReminderPreset(id: 'in-seven-days', label: 'In 7 days', at: inSevenDays),
  ];
}

/// A single entry point for reminder editing.
///
/// One surface, everywhere: everything a reminder can be — the quick
/// presets, a custom date and time, how it repeats, a saved place, and
/// removing it — lives on the one sheet, and the only difference between a
/// phone and a desktop is the box it arrives in (a bottom sheet against a
/// dialog) and the control the custom date is picked with (a wheel against a
/// calendar). Callers should await this method before allowing another picker
/// to open, which prevents rapid duplicate taps from stacking routes.
class ReminderPicker {
  const ReminderPicker._();

  static Future<ReminderSelection?> show(
    BuildContext context, {
    required DateTime? current,
    ReminderRepeat? currentRepeat,
    LocationReminder? currentLocation,
    List<SavedLocation> savedLocations = const [],

    /// Whether *this* device is the one that watches for saved places. It no
    /// longer decides whether a place can be chosen — the reminder lives in
    /// the account's settings and the phone arms it on its next sync, so a
    /// desktop sets one perfectly well — only whether the sheet has to say
    /// where the reminder will actually arrive.
    bool locationMonitored = false,
    required bool use24hTime,
    DateTime Function()? clock,
  }) {
    final now = (clock ?? DateTime.now)();
    final narrow = isNarrowScreen(context);
    Widget sheet(BuildContext context) => _ReminderSheet(
      current: current,
      currentRepeat: currentRepeat,
      currentLocation: currentLocation,
      savedLocations: savedLocations,
      locationMonitored: locationMonitored,
      now: now,
      use24hTime: use24hTime,
      inDialog: !narrow,
    );
    // The same shell every other picker arrives in, rather than a second one
    // that happened to pick a different paper and a different width.
    return showAdaptiveSelectionSurface<ReminderSelection>(
      context,
      isScrollControlled: true,
      maxWidth: 460,
      builder: sheet,
    );
  }
}

/// Which half of the sheet is showing. A reminder is one or the other: a note
/// reminded at a place is not also reminded at a time.
enum _ReminderKind { time, place }

class _ReminderSheet extends StatefulWidget {
  final DateTime? current;
  final ReminderRepeat? currentRepeat;
  final LocationReminder? currentLocation;
  final List<SavedLocation> savedLocations;
  final bool locationMonitored;
  final DateTime now;
  final bool use24hTime;

  /// Whether this is the wide layout's dialog rather than the phone's bottom
  /// sheet: no drag handle above it to pad around, and room for a calendar.
  final bool inDialog;

  const _ReminderSheet({
    required this.current,
    required this.currentRepeat,
    required this.currentLocation,
    required this.savedLocations,
    required this.locationMonitored,
    required this.now,
    required this.use24hTime,
    required this.inDialog,
  });

  @override
  State<_ReminderSheet> createState() => _ReminderSheetState();
}

class _ReminderSheetState extends State<_ReminderSheet> {
  late _ReminderKind _kind;
  late DateTime _customValue;
  late ReminderRepeat? _repeat;
  bool _showCustom = false;

  String? _locationId;
  late LocationReminderTrigger _trigger;
  late bool _locationRepeats;

  @override
  void initState() {
    super.initState();
    final candidate = widget.current;
    _customValue = candidate != null && candidate.isAfter(widget.now)
        ? candidate
        : widget.now;
    _repeat = widget.currentRepeat;
    final currentId = widget.currentLocation?.locationId;
    _locationId = widget.savedLocations.any((l) => l.id == currentId)
        ? currentId
        : widget.savedLocations.firstOrNull?.id;
    _trigger =
        widget.currentLocation?.trigger ?? LocationReminderTrigger.arrive;
    _locationRepeats = widget.currentLocation?.repeats ?? false;
    // Opens on whichever kind the note already has, so editing a reminder
    // starts on the thing being edited.
    _kind = widget.currentLocation != null && _offersPlace
        ? _ReminderKind.place
        : _ReminderKind.time;
  }

  /// A place can be chosen when the caller knows of any: the quick-add
  /// composer has no note to hang one on and passes none.
  bool get _offersPlace => widget.savedLocations.isNotEmpty;

  bool get _hasExisting =>
      widget.current != null || widget.currentLocation != null;

  String _whenLabel(DateTime value) {
    final localizations = MaterialLocalizations.of(context);
    final date = localizations.formatMediumDate(value);
    final time = localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(value),
      alwaysUse24HourFormat: widget.use24hTime,
    );
    return '$date, $time';
  }

  String _timeLabel(DateTime value) =>
      MaterialLocalizations.of(context).formatTimeOfDay(
        TimeOfDay.fromDateTime(value),
        alwaysUse24HourFormat: widget.use24hTime,
      );

  /// What the note is reminded of right now, for the line under the title.
  String? get _currentLabel {
    final location = widget.currentLocation;
    if (location != null) {
      final name = widget.savedLocations
          .where((l) => l.id == location.locationId)
          .map((l) => l.name)
          .firstOrNull;
      // The chip's own wording ("When I arrive"), turned around to describe
      // the note rather than speak for the reader, and lowercased so it
      // continues the sentence it is now the tail of.
      final what = location.label
          .replaceFirst(' I ', ' you ')
          .replaceRange(0, 1, location.label[0].toLowerCase());
      return name == null ? 'Currently $what' : 'Currently $what at $name';
    }
    final at = widget.current;
    return at == null ? null : 'Currently ${_whenLabel(at)}';
  }

  void _selectTime(DateTime value) {
    Navigator.of(context).pop(ReminderSelection.set(value, repeat: _repeat));
  }

  void _selectPlace() {
    final id = _locationId;
    if (id == null) return;
    Navigator.of(context).pop(
      ReminderSelection.location(
        id,
        _trigger,
        locationRepeats: _locationRepeats,
      ),
    );
  }

  Future<void> _pickCustomTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_customValue),
      helpText: 'Remind me at',
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(alwaysUse24HourFormat: widget.use24hTime),
        child: child!,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _customValue = DateTime(
        _customValue.year,
        _customValue.month,
        _customValue.day,
        picked.hour,
        picked.minute,
      );
    });
  }

  Widget _kindSwitch() => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: SegmentedButton<_ReminderKind>(
      key: const ValueKey('reminder-kind'),
      segments: const [
        ButtonSegment(
          value: _ReminderKind.time,
          icon: Icon(Icons.schedule_outlined),
          label: Text('At a time'),
        ),
        ButtonSegment(
          value: _ReminderKind.place,
          icon: Icon(Icons.location_on_outlined),
          label: Text('At a place'),
        ),
      ],
      selected: {_kind},
      showSelectedIcon: false,
      onSelectionChanged: (value) => setState(() => _kind = value.first),
    ),
  );

  Widget _repeatControl() => DropdownButtonFormField<ReminderRepeat?>(
    key: const ValueKey('reminder-repeat'),
    initialValue: _repeat,
    decoration: const InputDecoration(labelText: 'Repeat'),
    hint: const Text('Does not repeat'),
    items: [
      const DropdownMenuItem<ReminderRepeat?>(
        value: null,
        child: Text('Does not repeat'),
      ),
      for (final repeat in ReminderRepeat.values)
        DropdownMenuItem<ReminderRepeat?>(
          value: repeat,
          child: Text(repeat.label),
        ),
    ],
    onChanged: (value) => setState(() => _repeat = value),
  );

  /// The date and time in full. A phone spins a wheel; a wide layout has the
  /// room for a calendar, which is also what a desktop user expects to click
  /// a date in — and it keeps the whole reminder on one surface instead of
  /// sending them through a stack of modal date and time dialogs.
  Widget _customPicker(ThemeData theme, ColorScheme scheme) {
    if (!widget.inDialog) {
      return SizedBox(
        height: 216,
        child: CupertinoTheme(
          data: CupertinoTheme.of(context).copyWith(
            primaryColor: scheme.primary,
            brightness: theme.brightness,
          ),
          child: CupertinoDatePicker(
            key: const ValueKey('custom-reminder-picker'),
            mode: CupertinoDatePickerMode.dateAndTime,
            initialDateTime: _customValue,
            minimumDate: widget.now,
            maximumDate: widget.now.add(const Duration(days: 365 * 5)),
            use24hFormat: widget.use24hTime,
            onDateTimeChanged: (value) => _customValue = value,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Above the calendar, not below it: the calendar is tall enough to
        // push whatever follows it out of a short window, and the time is
        // half of what is being chosen here.
        OutlinedButton.icon(
          key: const ValueKey('custom-reminder-time'),
          onPressed: _pickCustomTime,
          icon: const Icon(Icons.schedule_outlined),
          label: Text('At ${_timeLabel(_customValue)}'),
        ),
        const SizedBox(height: 4),
        CalendarDatePicker(
          key: const ValueKey('custom-reminder-calendar'),
          initialDate: _customValue,
          firstDate: DateTime(
            widget.now.year,
            widget.now.month,
            widget.now.day,
          ),
          lastDate: widget.now.add(const Duration(days: 365 * 5)),
          onDateChanged: (date) => setState(() {
            _customValue = DateTime(
              date.year,
              date.month,
              date.day,
              _customValue.hour,
              _customValue.minute,
            );
          }),
        ),
      ],
    );
  }

  Widget _customContent(ThemeData theme, ColorScheme scheme) {
    return Column(
      key: const ValueKey('custom-reminder-content'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          key: const ValueKey('custom-reminder-toggle'),
          onPressed: () => setState(() => _showCustom = false),
          icon: const Icon(Icons.arrow_back),
          label: const Text('Quick reminder options'),
        ),
        const SizedBox(height: 8),
        _customPicker(theme, scheme),
      ],
    );
  }

  Widget _presetTile(
    ReminderPreset preset,
    ThemeData theme,
    ColorScheme scheme,
  ) => OutlinedButton(
    key: ValueKey('reminder-preset-${preset.id}'),
    style: OutlinedButton.styleFrom(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
    onPressed: () => _selectTime(preset.at),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(preset.label),
        const SizedBox(height: 2),
        Text(
          _whenLabel(preset.at),
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );

  /// One preset per line under a thumb, two to a line in a dialog: a wide
  /// layout has the width for it, and it keeps the whole surface inside a
  /// short desktop window instead of making the reader scroll for the custom
  /// option below.
  Widget _presets(
    ThemeData theme,
    ColorScheme scheme,
    List<ReminderPreset> presets,
  ) {
    if (!widget.inDialog) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final preset in presets)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _presetTile(preset, theme, scheme),
            ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - 8) / 2;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in presets)
              SizedBox(width: width, child: _presetTile(preset, theme, scheme)),
          ],
        );
      },
    );
  }

  Widget _quickContent(
    ThemeData theme,
    ColorScheme scheme,
    List<ReminderPreset> presets,
  ) {
    return Column(
      key: const ValueKey('quick-reminder-content'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Quick add', style: theme.textTheme.titleSmall),
        const SizedBox(height: 10),
        _presets(theme, scheme, presets),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const ValueKey('custom-reminder-toggle'),
          onPressed: () => setState(() => _showCustom = true),
          icon: const Icon(Icons.calendar_month_outlined),
          label: const Text('Custom date & time'),
        ),
      ],
    );
  }

  Widget _timePane(ThemeData theme, ColorScheme scheme) => Column(
    key: const ValueKey('time-reminder-pane'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _repeatControl(),
      const SizedBox(height: 16),
      AnimatedSwitcher(
        duration: Motion.base,
        switchInCurve: Motion.emphasized,
        switchOutCurve: Motion.standard,
        child: _showCustom
            ? _customContent(theme, scheme)
            : _quickContent(theme, scheme, reminderPresets(widget.now)),
      ),
    ],
  );

  Widget _placePane(ThemeData theme, ColorScheme scheme) => Column(
    key: const ValueKey('place-reminder-pane'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SegmentedButton<LocationReminderTrigger>(
        segments: [
          for (final trigger in LocationReminderTrigger.values)
            ButtonSegment(value: trigger, label: Text(trigger.label)),
        ],
        selected: {_trigger},
        showSelectedIcon: false,
        onSelectionChanged: (value) => setState(() => _trigger = value.first),
      ),
      const SizedBox(height: 8),
      SegmentedButton<bool>(
        key: const ValueKey('location-reminder-repeats'),
        segments: const [
          ButtonSegment(
            value: false,
            icon: Icon(Icons.looks_one_outlined),
            label: Text('Once'),
          ),
          ButtonSegment(
            value: true,
            icon: Icon(Icons.repeat),
            label: Text('Every time'),
          ),
        ],
        selected: {_locationRepeats},
        showSelectedIcon: false,
        onSelectionChanged: (value) =>
            setState(() => _locationRepeats = value.first),
      ),
      const SizedBox(height: 4),
      Text(
        _locationRepeats
            ? 'Stays on the note and reminds you on every visit.'
            : 'Comes off the note once it has reminded you.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 12),
      RadioGroup<String>(
        groupValue: _locationId,
        onChanged: (value) {
          if (value != null) setState(() => _locationId = value);
        },
        child: Column(
          children: [
            for (final location in widget.savedLocations)
              RadioListTile<String>(
                value: location.id,
                title: Text(location.name),
                subtitle: Text('${location.radiusMeters.round()} m radius'),
              ),
          ],
        ),
      ),
      // Set here, delivered there. Only a phone can watch a geofence, and a
      // reminder saved on a laptop that said nothing about it would look
      // broken the moment the laptop stayed silent.
      if (!widget.locationMonitored) ...[
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.phone_iphone, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Watched for by Skippy on your phone, so the reminder '
                'arrives there.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    ],
  );

  /// The sheet's committing actions: whatever the visible pane can be saved
  /// with, and removing what the note already has. Kept out of the panes
  /// because a dialog pins them below its scrolling part — a calendar plus a
  /// list of presets is taller than a short desktop window, and the button
  /// that finishes the job must not be the thing scrolled off the bottom.
  Widget? _actions(ColorScheme scheme) {
    final Widget? primary = switch (_kind) {
      _ReminderKind.place => FilledButton.icon(
        key: const ValueKey('save-location-reminder'),
        onPressed: _locationId == null ? null : _selectPlace,
        icon: const Icon(Icons.location_on_outlined),
        label: const Text('Save location reminder'),
      ),
      // The presets commit themselves; only the custom date needs a button.
      _ReminderKind.time when _showCustom => FilledButton.icon(
        key: const ValueKey('save-custom-reminder'),
        onPressed: () => _selectTime(_customValue),
        icon: const Icon(Icons.notifications_active_outlined),
        label: const Text('Save reminder'),
      ),
      _ReminderKind.time => null,
    };
    if (primary == null && !_hasExisting) return null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?primary,
        if (_hasExisting) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            key: const ValueKey('remove-reminder'),
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            onPressed: () =>
                Navigator.of(context).pop(const ReminderSelection.clear()),
            icon: const Icon(Icons.alarm_off),
            label: const Text('Remove reminder'),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final currentLabel = _currentLabel;

    final actions = _actions(scheme);
    final header = ModalHeader(
      title: 'Set reminder',
      subtitle: currentLabel,
      onClose: () => Navigator.of(context).pop(),
    );
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_offersPlace) _kindSwitch(),
        AnimatedSize(
          duration: Motion.base,
          curve: Motion.emphasized,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: Motion.base,
            switchInCurve: Motion.emphasized,
            switchOutCurve: Motion.standard,
            child: _kind == _ReminderKind.time
                ? _timePane(theme, scheme)
                : _placePane(theme, scheme),
          ),
        ),
      ],
    );

    // A sheet grows with what is in it and is dragged around by its own
    // handle, so its actions ride along at the bottom of the content. A
    // dialog is capped by the window, so the same actions are pinned under
    // the part that scrolls.
    if (!widget.inDialog) {
      return SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              Padding(
                padding: modalBodyPadding(hasFooter: actions != null),
                child: body,
              ),
              if (actions != null)
                ModalFooter(stacked: true, children: [actions]),
            ],
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Flexible(
          child: SingleChildScrollView(
            padding: modalBodyPadding(hasFooter: actions != null),
            child: body,
          ),
        ),
        if (actions != null) ModalFooter(stacked: true, children: [actions]),
      ],
    );
  }
}
