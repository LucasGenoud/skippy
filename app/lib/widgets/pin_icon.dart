import 'package:flutter/material.dart';

import '../util/motion.dart';

/// The pin glyph, filled when [pinned], with a small scale-pop when it flips
/// so pinning reads as tactile rather than an instant glyph swap. Shared by
/// every pin toggle so they all answer the same way.
class PinIcon extends StatelessWidget {
  final bool pinned;
  final double? size;

  const PinIcon({super.key, required this.pinned, this.size});

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: Motion.reduced(context) ? Duration.zero : Motion.fast,
    switchInCurve: Curves.easeOutBack,
    switchOutCurve: Curves.easeIn,
    transitionBuilder: (child, animation) =>
        ScaleTransition(scale: animation, child: child),
    child: Icon(
      pinned ? Icons.push_pin : Icons.push_pin_outlined,
      key: ValueKey(pinned),
      size: size,
    ),
  );
}
