import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../util/motion.dart';
import 'form_dialog.dart';

/// The result of editing a reminder. A null result means the picker was
/// dismissed; [at] being null means the existing reminder should be removed.
class ReminderSelection {
  final DateTime? at;

  const ReminderSelection.set(this.at) : assert(at != null);
  const ReminderSelection.clear() : at = null;
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
    required bool use24hTime,
    DateTime Function()? clock,
  }) {
    final now = (clock ?? DateTime.now)();
    if (isNarrowScreen(context)) {
      return showModalBottomSheet<ReminderSelection>(
        context: context,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
        showDragHandle: true,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => _MobileReminderSheet(
          current: current,
          now: now,
          use24hTime: use24hTime,
        ),
      );
    }
    return _showDesktop(
      context,
      current: current,
      now: now,
      use24hTime: use24hTime,
    );
  }

  static Future<ReminderSelection?> _showDesktop(
    BuildContext context, {
    required DateTime? current,
    required DateTime now,
    required bool use24hTime,
  }) async {
    if (current != null) {
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

    final initial = current ?? DateTime(now.year, now.month, now.day + 1, 9);
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
    return ReminderSelection.set(
      DateTime(date.year, date.month, date.day, time.hour, time.minute),
    );
  }
}

class _MobileReminderSheet extends StatefulWidget {
  final DateTime? current;
  final DateTime now;
  final bool use24hTime;

  const _MobileReminderSheet({
    required this.current,
    required this.now,
    required this.use24hTime,
  });

  @override
  State<_MobileReminderSheet> createState() => _MobileReminderSheetState();
}

class _MobileReminderSheetState extends State<_MobileReminderSheet> {
  late DateTime _customValue;
  bool _showCustom = false;

  @override
  void initState() {
    super.initState();
    final fallback = DateTime(
      widget.now.year,
      widget.now.month,
      widget.now.day + 1,
      9,
    );
    final candidate = widget.current;
    _customValue = candidate != null && candidate.isAfter(widget.now)
        ? candidate
        : fallback;
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
    Navigator.of(context).pop(ReminderSelection.set(value));
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
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
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
              onPressed: () => setState(() => _showCustom = !_showCustom),
              icon: Icon(
                _showCustom ? Icons.expand_less : Icons.calendar_month_outlined,
              ),
              label: Text(
                _showCustom ? 'Hide custom date & time' : 'Custom date & time',
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: _showCustom
                  ? Column(
                      children: [
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
                              maximumDate: widget.now.add(
                                const Duration(days: 365 * 5),
                              ),
                              use24hFormat: widget.use24hTime,
                              onDateTimeChanged: (value) =>
                                  _customValue = value,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          key: const ValueKey('save-custom-reminder'),
                          onPressed: () => _select(_customValue),
                          icon: const Icon(Icons.notifications_active_outlined),
                          label: const Text('Save reminder'),
                        ),
                      ],
                    )
                  : const SizedBox.shrink(),
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
        ),
      ),
    );
  }
}
