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

  const ReminderSelection.set(this.at, {this.repeat})
    : assert(at != null),
      locationId = null,
      locationTrigger = null;
  const ReminderSelection.location(this.locationId, this.locationTrigger)
    : assert(locationId != null),
      assert(locationTrigger != null),
      at = null,
      repeat = null;
  const ReminderSelection.clear()
    : at = null,
      repeat = null,
      locationId = null,
      locationTrigger = null;
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

/// Builds the phone quick actions independently from the UI so their date
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
/// Phones get one stable bottom sheet containing presets and an inline
/// date/time wheel. Wide layouts retain the familiar Material date and time
/// dialogs. Callers should await this method before allowing another picker to
/// open, which prevents rapid duplicate taps from stacking routes.
class ReminderPicker {
  const ReminderPicker._();

  static Future<ReminderSelection?> show(
    BuildContext context, {
    required DateTime? current,
    ReminderRepeat? currentRepeat,
    LocationReminder? currentLocation,
    List<SavedLocation> savedLocations = const [],
    bool locationSupported = false,
    required bool use24hTime,
    DateTime Function()? clock,
  }) async {
    final now = (clock ?? DateTime.now)();
    final offersLocation =
        locationSupported &&
        (savedLocations.isNotEmpty || currentLocation != null);
    if (offersLocation) {
      final kind = await _pickKind(
        context,
        hasExisting: current != null || currentLocation != null,
        locationsAvailable: savedLocations.isNotEmpty,
      );
      if (!context.mounted || kind == null) return null;
      if (kind == 'remove') return const ReminderSelection.clear();
      if (kind == 'location') {
        return _showLocation(
          context,
          locations: savedLocations,
          current: currentLocation,
        );
      }
    }
    if (isNarrowScreen(context)) {
      return showModalBottomSheet<ReminderSelection>(
        context: context,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
        showDragHandle: true,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => _MobileReminderSheet(
          current: current,
          currentRepeat: currentRepeat,
          now: now,
          use24hTime: use24hTime,
        ),
      );
    }
    return _showDesktop(
      context,
      current: current,
      currentRepeat: currentRepeat,
      now: now,
      use24hTime: use24hTime,
      skipExistingChoice: offersLocation,
    );
  }

  static Future<String?> _pickKind(
    BuildContext context, {
    required bool hasExisting,
    required bool locationsAvailable,
  }) => showAdaptiveSelectionSurface<String>(
    context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.schedule_outlined),
            title: const Text('At a time'),
            subtitle: const Text('Choose a date and time'),
            onTap: () => Navigator.pop(context, 'time'),
          ),
          ListTile(
            leading: const Icon(Icons.location_on_outlined),
            title: const Text('At a saved location'),
            subtitle: Text(
              locationsAvailable
                  ? 'When you arrive or leave'
                  : 'Add a place in Settings first',
            ),
            enabled: locationsAvailable,
            onTap: locationsAvailable
                ? () => Navigator.pop(context, 'location')
                : null,
          ),
          if (hasExisting)
            ListTile(
              leading: const Icon(Icons.alarm_off),
              title: const Text('Remove reminder'),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
        ],
      ),
    ),
  );

  static Future<ReminderSelection?> _showLocation(
    BuildContext context, {
    required List<SavedLocation> locations,
    required LocationReminder? current,
  }) => showAdaptiveSelectionSurface<ReminderSelection>(
    context,
    isScrollControlled: true,
    builder: (context) =>
        _LocationReminderSheet(locations: locations, current: current),
  );

  static Future<ReminderSelection?> _showDesktop(
    BuildContext context, {
    required DateTime? current,
    required ReminderRepeat? currentRepeat,
    required DateTime now,
    required bool use24hTime,
    bool skipExistingChoice = false,
  }) async {
    if (current != null && !skipExistingChoice) {
      final action = await showAdaptiveSelectionSurface<String>(
        context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Change reminder'),
                onTap: () => Navigator.pop(context, 'change'),
              ),
              ListTile(
                leading: const Icon(Icons.alarm_off),
                title: const Text('Remove reminder'),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
            ],
          ),
        ),
      );
      if (!context.mounted) return null;
      if (action == 'remove') return const ReminderSelection.clear();
      if (action != 'change') return null;
    }

    final initial = current ?? now;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365 * 5)),
      helpText: 'Remind me on',
    );
    if (date == null || !context.mounted) return null;
    await Motion.waitForOverlayDismissal(context);
    if (!context.mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: 'Remind me at',
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(alwaysUse24HourFormat: use24hTime),
        child: child!,
      ),
    );
    if (time == null) return null;
    if (!context.mounted) return null;
    final repeat = await _pickDesktopRepeat(context, currentRepeat);
    if (repeat == null) return null;
    return ReminderSelection.set(
      DateTime(date.year, date.month, date.day, time.hour, time.minute),
      repeat: repeat.repeat,
    );
  }

  static Future<_RepeatChoice?> _pickDesktopRepeat(
    BuildContext context,
    ReminderRepeat? current,
  ) => showAdaptiveSelectionSurface<_RepeatChoice>(
    context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.looks_one_outlined),
            title: const Text('Does not repeat'),
            trailing: current == null ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(context, const _RepeatChoice(null)),
          ),
          for (final repeat in ReminderRepeat.values)
            ListTile(
              leading: const Icon(Icons.repeat),
              title: Text(repeat.label),
              trailing: current == repeat ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, _RepeatChoice(repeat)),
            ),
        ],
      ),
    ),
  );
}

class _LocationReminderSheet extends StatefulWidget {
  final List<SavedLocation> locations;
  final LocationReminder? current;

  const _LocationReminderSheet({required this.locations, this.current});

  @override
  State<_LocationReminderSheet> createState() => _LocationReminderSheetState();
}

class _LocationReminderSheetState extends State<_LocationReminderSheet> {
  late String _locationId;
  late LocationReminderTrigger _trigger;

  @override
  void initState() {
    super.initState();
    final currentId = widget.current?.locationId;
    _locationId = widget.locations.any((location) => location.id == currentId)
        ? currentId!
        : widget.locations.first.id;
    _trigger = widget.current?.trigger ?? LocationReminderTrigger.arrive;
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Location reminder',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          SegmentedButton<LocationReminderTrigger>(
            segments: [
              for (final trigger in LocationReminderTrigger.values)
                ButtonSegment(value: trigger, label: Text(trigger.label)),
            ],
            selected: {_trigger},
            showSelectedIcon: false,
            onSelectionChanged: (value) =>
                setState(() => _trigger = value.first),
          ),
          const SizedBox(height: 12),
          RadioGroup<String>(
            groupValue: _locationId,
            onChanged: (value) {
              if (value != null) setState(() => _locationId = value);
            },
            child: Column(
              children: [
                for (final location in widget.locations)
                  RadioListTile<String>(
                    value: location.id,
                    title: Text(location.name),
                    subtitle: Text('${location.radiusMeters.round()} m radius'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const ValueKey('save-location-reminder'),
            onPressed: () => Navigator.of(
              context,
            ).pop(ReminderSelection.location(_locationId, _trigger)),
            icon: const Icon(Icons.location_on_outlined),
            label: const Text('Save location reminder'),
          ),
        ],
      ),
    ),
  );
}

class _RepeatChoice {
  final ReminderRepeat? repeat;
  const _RepeatChoice(this.repeat);
}

class _MobileReminderSheet extends StatefulWidget {
  final DateTime? current;
  final ReminderRepeat? currentRepeat;
  final DateTime now;
  final bool use24hTime;

  const _MobileReminderSheet({
    required this.current,
    required this.currentRepeat,
    required this.now,
    required this.use24hTime,
  });

  @override
  State<_MobileReminderSheet> createState() => _MobileReminderSheetState();
}

class _MobileReminderSheetState extends State<_MobileReminderSheet> {
  late DateTime _customValue;
  late ReminderRepeat? _repeat;
  bool _showCustom = false;

  @override
  void initState() {
    super.initState();
    final candidate = widget.current;
    _customValue = candidate != null && candidate.isAfter(widget.now)
        ? candidate
        : widget.now;
    _repeat = widget.currentRepeat;
  }

  String _whenLabel(BuildContext context, DateTime value) {
    final localizations = MaterialLocalizations.of(context);
    final date = localizations.formatMediumDate(value);
    final time = localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(value),
      alwaysUse24HourFormat: widget.use24hTime,
    );
    return '$date, $time';
  }

  void _select(DateTime value) {
    Navigator.of(context).pop(ReminderSelection.set(value, repeat: _repeat));
  }

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
        SizedBox(
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
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const ValueKey('save-custom-reminder'),
          onPressed: () => _select(_customValue),
          icon: const Icon(Icons.notifications_active_outlined),
          label: const Text('Save reminder'),
        ),
      ],
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
        for (final preset in presets)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OutlinedButton(
              key: ValueKey('reminder-preset-${preset.id}'),
              style: OutlinedButton.styleFrom(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              onPressed: () => _select(preset.at),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(preset.label),
                  const SizedBox(height: 2),
                  Text(
                    _whenLabel(context, preset.at),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          key: const ValueKey('custom-reminder-toggle'),
          onPressed: () => setState(() => _showCustom = true),
          icon: const Icon(Icons.calendar_month_outlined),
          label: const Text('Custom date & time'),
        ),
        if (widget.current != null) ...[
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
    final presets = reminderPresets(widget.now);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.9,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Set reminder',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            if (widget.current != null) ...[
              Text(
                'Currently ${_whenLabel(context, widget.current!)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
            ] else
              const SizedBox(height: 4),
            const SizedBox(height: 12),
            _repeatControl(),
            const SizedBox(height: 16),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: _showCustom
                  ? _customContent(theme, scheme)
                  : _quickContent(theme, scheme, presets),
            ),
          ],
        ),
      ),
    );
  }
}
