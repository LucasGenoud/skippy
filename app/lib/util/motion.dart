import 'package:flutter/widgets.dart';

/// Shared motion tokens so every animation in the app feels like one system.
/// Two rules keep it coherent: durations stay short (nothing over [slow] =
/// 250ms — animations should feel snappy, never slow) and easing is always a
/// cubic bezier ([emphasized] or [standard]), never linear. Reach for a token
/// rather than a bare `Duration`/`Curve` so a transition can't drift off-system.
class Motion {
  const Motion._();

  /// Small state flips (hover, ripple, toggles).
  static const Duration fast = Duration(milliseconds: 150);

  /// The workhorse: reflows, container morphs, most transitions.
  static const Duration base = Duration(milliseconds: 240);

  /// The ceiling — larger entrances (view changes, container transforms,
  /// staggered grid). Deliberately capped at 250ms; nothing should run longer.
  static const Duration slow = Duration(milliseconds: 250);

  /// Material 3 "emphasized" easing — lively but controlled. The default for
  /// enter/exit and anything that grows or morphs.
  static const Curve emphasized = Cubic(0.2, 0.0, 0.0, 1.0);

  /// A calmer ease-out cubic, for hovers, fades, and moves in place.
  static const Curve standard = Curves.easeOutCubic;

  /// True when the OS "reduce motion" accessibility setting is on. Callers skip
  /// or shorten decorative animation so the app stays comfortable to use.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;
}
