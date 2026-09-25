import 'package:flutter/material.dart';

import '../util/motion.dart';

/// One slot whose content cross-fades when [state] changes: a spinner giving
/// way to a page, a bare hostname to a page title. A new [child] for the same
/// [state] updates in place.
///
/// Mid-fade both children are pinned to [alignment], so a short line keeps
/// its place instead of centring in the space the other one leaves.
class StateCrossFade extends StatelessWidget {
  final Object? state;
  final Widget child;
  final AlignmentGeometry alignment;
  final Duration duration;

  const StateCrossFade({
    super.key,
    required this.state,
    required this.child,
    this.alignment = AlignmentDirectional.topStart,
    this.duration = Motion.fast,
  });

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: Motion.reduced(context) ? Duration.zero : duration,
    switchInCurve: Motion.standard,
    switchOutCurve: Motion.standard,
    layoutBuilder: (current, previous) =>
        Stack(alignment: alignment, children: [...previous, ?current]),
    child: KeyedSubtree(key: ValueKey(state), child: child),
  );
}
