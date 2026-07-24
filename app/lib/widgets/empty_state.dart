import 'package:flutter/material.dart';

import '../util/motion.dart';

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  const EmptyState({super.key, required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      // Gentle fade + rise on appearance, so an empty view settles in rather
      // than popping. Keyed by content: switching between empty views (Trash →
      // Archive) replays it, matching the grid's staggered entrance.
      child: TweenAnimationBuilder<double>(
        key: ValueKey('$icon-$message'),
        tween: Tween(begin: 0, end: 1),
        duration: Motion.reduced(context) ? Duration.zero : Motion.slow,
        curve: Motion.emphasized,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 16),
            child: child,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 96,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 20),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
