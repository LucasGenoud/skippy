import 'package:flutter/material.dart';
import '../theme.dart';

import '../util/motion.dart';

/// A shimmering placeholder grid shown on a genuine cold load (no cache yet),
/// so the app feels like it's filling in rather than staring at a spinner.
/// With a local cache present, loads are instant and this never appears.
class NotesSkeleton extends StatefulWidget {
  final int columns;
  const NotesSkeleton({super.key, required this.columns});

  @override
  State<NotesSkeleton> createState() => _NotesSkeletonState();
}

class _NotesSkeletonState extends State<NotesSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  // A handful of varied heights so the placeholder reads as a masonry grid.
  static const _heights = [
    148.0,
    96.0,
    184.0,
    120.0,
    88.0,
    156.0,
    108.0,
    132.0,
  ];

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduce = Motion.reduced(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var col = 0; col < widget.columns; col++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                right: col == widget.columns - 1 ? 0 : 8,
              ),
              child: Column(
                children: [
                  for (var i = col; i < _heights.length; i += widget.columns)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: AnimatedBuilder(
                        animation: _pulse,
                        builder: (context, _) => Container(
                          height: _heights[i],
                          decoration: BoxDecoration(
                            color: Color.lerp(
                              scheme.surfaceContainerHighest,
                              scheme.surfaceContainer,
                              reduce ? 0.5 : _pulse.value,
                            ),
                            borderRadius: BorderRadius.circular(kRadius),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
