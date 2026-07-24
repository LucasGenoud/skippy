import 'package:flutter/material.dart';

/// Small "managed by the server" hint shown under a locked setting.
class ManagedNote extends StatelessWidget {
  const ManagedNote({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline, size: 13, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            'Managed by the server',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Subtitle for a toggle that may be server-managed: the usual line, plus a
/// "managed by the server" hint when the toggle is locked.
class ManagedToggleSubtitle extends StatelessWidget {
  final bool managed;
  final String text;
  const ManagedToggleSubtitle({
    super.key,
    required this.managed,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    if (!managed) return Text(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [Text(text), const ManagedNote()],
    );
  }
}
