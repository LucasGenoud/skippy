import 'package:flutter/widgets.dart';

/// Shared motion tokens so every animation in the app feels like one system.
/// Durations escalate with the size of the change; [emphasized] is the default
/// easing for enter/exit.
class Motion {
  const Motion._();

  /// Small state flips (hover, ripple, toggles).
  static const Duration fast = Duration(milliseconds: 150);

  /// The workhorse: reflows, container morphs, most transitions.
  static const Duration base = Duration(milliseconds: 240);

  /// Larger entrances (view changes, staggered grid).
  static const Duration slow = Duration(milliseconds: 320);

  /// Material 3 "emphasized" easing — lively but controlled.
  static const Curve emphasized = Cubic(0.2, 0.0, 0.0, 1.0);
  static const Curve standard = Curves.easeOutCubic;

  /// True when the OS "reduce motion" accessibility setting is on. Callers skip
  /// or shorten decorative animation so the app stays comfortable to use.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;
}
