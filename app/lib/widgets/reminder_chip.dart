import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../state/settings_store.dart';
import '../theme.dart';

/// The "when" pill for a reminder, shared by the grid card (a note's own
/// reminder) and the checklist editor (one row's). One widget so the two never
/// drift into looking like different features.
///
/// A reminder whose time has passed keeps its place and reads struck through:
/// it is history, not an error, and the server's sweep has already delivered
/// it.
class ReminderChip extends StatelessWidget {
  final DateTime at;
  final ReminderRepeat? repeat;

  /// Opens the picker. Null renders the chip as plain decoration, which is
  /// what the card wants: its whole surface is already a tap target.
  final VoidCallback? onTap;

  const ReminderChip({super.key, required this.at, this.repeat, this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final past = at.isBefore(DateTime.now());
    // select: re-render only when the formatted label itself changes (date
    // or clock format edits), not on every settings notification.
    final when = context.select<SettingsStore, String>(
      (s) => s.reminderLabel(at),
    );
    final label = '$when${repeat == null ? '' : ' · ${repeat!.label}'}';
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadius),
        color: scheme.onSurface.withValues(alpha: 0.08),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.alarm, size: 13, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                decoration: past ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return chip;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(kRadius),
      child: chip,
    );
  }
}
