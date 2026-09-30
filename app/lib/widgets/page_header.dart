import 'package:flutter/material.dart';

import '../theme.dart';
import '../util/motion.dart';

/// The title block a destination opens with: Reminders, Archive, Trash.
///
/// ```text
///   Title                                  [trailing]
///   subtitle
/// ```
///
/// Callers place it on the same edge as the cards below; the title is inset a
/// touch from that edge, the same inset as a section label, and [trailing]
/// sits flush with it.
class PageHeader extends StatelessWidget {
  final String title;

  /// One quiet line under the title. Cross-fades when it changes.
  final String? subtitle;
  final Widget? trailing;

  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = this.subtitle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSpaceSm, kSpaceLg, 0, kSpaceXs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.headlineSmall),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  AnimatedSwitcher(
                    duration: Motion.fast,
                    switchInCurve: Motion.standard,
                    switchOutCurve: Motion.standard,
                    layoutBuilder: (current, previous) => Stack(
                      alignment: AlignmentDirectional.centerStart,
                      children: [...previous, ?current],
                    ),
                    child: Text(
                      subtitle,
                      key: ValueKey(subtitle),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
