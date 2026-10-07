import 'package:flutter/material.dart';

/// A quiet progress cue for the server-side automatic link summary job.
class LinkSummaryIndicator extends StatelessWidget {
  final bool compact;

  /// Stops the summary. Null hides the button.
  final VoidCallback? onCancel;

  const LinkSummaryIndicator({super.key, this.compact = false, this.onCancel});

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
          Flexible(
            child: Text(
              'Summarizing link…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (onCancel != null)
            IconButton(
              icon: Icon(Icons.close, size: compact ? 16 : 18),
              tooltip: 'Stop summarizing',
              color: theme.colorScheme.onSurfaceVariant,
              visualDensity: VisualDensity.compact,
              constraints: BoxConstraints.tightFor(
                width: compact ? 28 : 32,
                height: compact ? 28 : 32,
              ),
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: onCancel,
            ),
        ],
      ),
    );
  }
}
