import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/notes_store.dart';
import '../theme.dart';
import '../util/motion.dart';

/// A small floating pill that says whether every edit has reached the
/// server: "Synced", "Saving", "Offline". Sits beside the new-note button on
/// wide screens, where there is room to keep it in view; a phone keeps the
/// offline banner instead.
class SyncPill extends StatelessWidget {
  const SyncPill({super.key});

  @override
  Widget build(BuildContext context) {
    final status = context.select<NotesStore, SyncStatus>((s) => s.syncStatus);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = status == SyncStatus.failed;
    final color = failed ? scheme.error : scheme.onSurfaceVariant;
    final (icon, label) = _describe(status);

    return Semantics(
      liveRegion: true,
      label: 'Sync status: $label',
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.standard,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: kBorderRadius,
          border: Border.all(
            color: failed ? scheme.error : scheme.outlineVariant,
          ),
          boxShadow: cardShadow(scheme, CardLift.resting),
        ),
        child: AnimatedSize(
          duration: Motion.reduced(context) ? Duration.zero : Motion.base,
          curve: Motion.standard,
          child: AnimatedSwitcher(
            duration: Motion.reduced(context) ? Duration.zero : Motion.fast,
            switchInCurve: Motion.standard,
            switchOutCurve: Motion.standard,
            child: Row(
              key: ValueKey(status),
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon == null)
                  SizedBox.square(
                    dimension: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: color,
                    ),
                  )
                else
                  Icon(icon, size: 14, color: color),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The glyph and word for [status]. A null glyph means work in flight,
  /// drawn as a spinner.
  static (IconData?, String) _describe(SyncStatus status) => switch (status) {
    SyncStatus.synced => (Icons.check_rounded, 'Synced'),
    SyncStatus.syncing => (null, 'Saving'),
    SyncStatus.connecting => (null, 'Connecting'),
    SyncStatus.offline => (Icons.cloud_off_outlined, 'Offline'),
    SyncStatus.failed => (Icons.error_outline, 'Not synced'),
  };
}
