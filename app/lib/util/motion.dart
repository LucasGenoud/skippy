import 'package:flutter/material.dart';

/// Shared motion tokens so every animation in the app feels like one system.
/// Two rules keep it coherent: durations stay short (no transition over [slow]
/// = 250ms, animations should feel snappy, never slow; [celebration] is the one
/// decorative exception) and easing is always a cubic bezier ([emphasized] or
/// [standard]), never linear. Reach for a token rather than a bare
/// `Duration`/`Curve` so a transition can't drift off-system.
class Motion {
  const Motion._();

  /// Small state flips (hover, ripple, toggles).
  static const Duration fast = Duration(milliseconds: 150);

  /// The workhorse: reflows, container morphs, most transitions.
  static const Duration base = Duration(milliseconds: 240);

  /// The ceiling, larger entrances (view changes, container transforms,
  /// staggered grid). Deliberately capped at 250ms; nothing should run longer.
  static const Duration slow = Duration(milliseconds: 250);

  /// The one exception to that ceiling: a decorative flourish that nothing
  /// waits on and that never moves a control the user is reaching for (the
  /// completed-checklist burst). It plays over the interface rather than
  /// changing it, so its length is about how long the moment should last, not
  /// about how quickly the app responds. Skipped outright under reduce motion.
  static const Duration celebration = Duration(milliseconds: 1100);

  /// Material 3 "emphasized" easing, lively but controlled. The default for
  /// enter/exit and anything that grows or morphs.
  static const Curve emphasized = Cubic(0.2, 0.0, 0.0, 1.0);

  /// A calmer ease-out cubic, for hovers, fades, and moves in place.
  static const Curve standard = Curves.easeOutCubic;

  /// Popup menus use Flutter's native anchored route and item sequencing, but
  /// the stock linear 300 ms grow feels sluggish beside the rest of Skippy.
  /// This gives them a controlled, emphasized entrance and a quick close.
  static const AnimationStyle menu = AnimationStyle(
    duration: base,
    reverseDuration: fast,
    curve: emphasized,
    reverseCurve: standard,
  );

  /// The menu route has no access to [MediaQuery], so callers select the
  /// accessible no-animation variant before opening it.
  static AnimationStyle menuFor(BuildContext context) =>
      reduced(context) ? AnimationStyle.noAnimation : menu;

  /// Waits until a popup menu's reverse animation has released the overlay.
  /// `PopupMenuButton.onSelected` runs when the route is popped, not when its
  /// visual dismissal has finished, so presenting another route immediately
  /// can make the two surfaces flash through each other.
  static Duration menuDismissalDuration(BuildContext context) =>
      reduced(context) ? Duration.zero : fast;

  static Future<void> waitForMenuDismissal(BuildContext context) =>
      Future<void>.delayed(menuDismissalDuration(context));

  /// Waits for a dialog, page, or bottom sheet to finish reversing after its
  /// result future completes. Use when another route is opened or closed
  /// immediately afterward.
  static Duration overlayDismissalDuration(BuildContext context) =>
      reduced(context) ? Duration.zero : base;

  static Future<void> waitForOverlayDismissal(BuildContext context) =>
      Future<void>.delayed(overlayDismissalDuration(context));

  /// True when the OS "reduce motion" accessibility setting is on. Callers skip
  /// or shorten decorative animation so the app stays comfortable to use.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;
}
