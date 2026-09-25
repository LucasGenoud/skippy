import 'package:flutter/material.dart';

import '../util/motion.dart';
import 'state_cross_fade.dart';

/// Shows [child], or nothing when it is null, growing and fading in and out
/// rather than pushing what sits below it in a single frame.
///
/// For a row that comes and goes under a form or list: an error line, a
/// progress bar, a probe result. The swap is keyed on presence only, so a
/// child that merely changes (a new error message) updates in place.
class AnimatedReveal extends StatelessWidget {
  final Widget? child;

  const AnimatedReveal({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: Motion.reduced(context) ? Duration.zero : Motion.base,
      curve: Motion.emphasized,
      alignment: AlignmentDirectional.topStart,
      child: StateCrossFade(
        state: child != null,
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
