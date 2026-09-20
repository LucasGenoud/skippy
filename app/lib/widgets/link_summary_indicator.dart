import 'package:flutter/material.dart';

/// A quiet progress cue for the server-side automatic link summary job.
class LinkSummaryIndicator extends StatelessWidget {
  final bool compact;

  const LinkSummaryIndicator({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = compact ? 14.0 : 16.0;
    return Semantics(
      label: 'Summarizing link',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Summarizing link…',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
