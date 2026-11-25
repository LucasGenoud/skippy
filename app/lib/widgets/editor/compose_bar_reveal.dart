import 'package:flutter/material.dart';

import '../../util/motion.dart';

/// A bar under the note, such as the formatting toolbar, that rises out of
/// the bottom bar when [child] arrives and sinks back into it when [child]
/// goes null.
///
/// Only the height animates: the bar keeps its full width from the first
/// frame, so it never grows in from a point the way [AnimatedSize] would.
/// The space opens first and the bar fades in as it settles; the exit plays
/// the same in reverse, quicker: the bar fades, then the space closes.
class ComposeBarReveal extends StatefulWidget {
  final Widget? child;

  const ComposeBarReveal({super.key, required this.child});

  @override
  State<ComposeBarReveal> createState() => _ComposeBarRevealState();
}

class _ComposeBarRevealState extends State<ComposeBarReveal>
    with SingleTickerProviderStateMixin {
  /// Share of the entrance spent opening space before the bar shows.
  static const double _fadeStart = 0.3;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Motion.base,
    reverseDuration: Motion.fast,
    value: widget.child == null ? 0 : 1,
  )..addStatusListener(_onStatus);

  late final Animation<double> _size = CurvedAnimation(
    parent: _controller,
    curve: Motion.emphasized,
  );

  late final Animation<double> _opacity = CurvedAnimation(
    parent: _controller,
    curve: const Interval(_fadeStart, 1, curve: Motion.standard),
  );

  /// The bar on screen, kept through its exit after [widget.child] is gone.
  Widget? _shown;

  @override
  void initState() {
    super.initState();
    _shown = widget.child;
  }

  @override
  void didUpdateWidget(ComposeBarReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    final child = widget.child;
    final reduced = Motion.reduced(context);
    if (child != null) {
      _shown = child;
      if (reduced) {
        _controller.value = 1;
      } else {
        _controller.forward();
      }
      return;
    }

    if (reduced) {
      _controller.value = 0;
      _shown = null;
      return;
    }
    _controller.reverse();
  }

  /// Drops the bar from the tree once it has sunk out of sight.
  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed || widget.child != null) {
      return;
    }
    setState(() => _shown = null);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    if (shown == null) {
      return const SizedBox.shrink();
    }

    // Anchored to the bottom, so the bar comes up from the bottom bar.
    return SizeTransition(
      sizeFactor: _size,
      alignment: Alignment.bottomCenter,
      child: FadeTransition(opacity: _opacity, child: shown),
    );
  }
}
