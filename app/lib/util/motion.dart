import 'package:flutter/physics.dart';
import 'package:flutter/material.dart';

/// Shared motion tokens so every animation in the app feels like one system.
/// Two rules keep it coherent: durations stay short (no transition over [slow]
/// = 250ms, animations should feel snappy, never slow; [celebration] and the
/// looping [pulse] are the exceptions, since nothing waits on them) and easing
/// is never linear. Transitions ease with [emphasized] or [standard]; the
/// remaining curves each have one job: [pop] for a small glyph landing,
/// [accelerate] for leaving, [swell] for a loop's rise and fall, [flourish]
/// for the checkbox tick. Reach for a token rather than a bare
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

  /// One cycle of a looping indicator: a loading shimmer, a pulse while
  /// something works, the recording ripple, typing dots, the sync spinner.
  /// One rhythm for all of them, calm enough to sit on screen for seconds.
  static const Duration pulse = Duration(milliseconds: 1400);

  /// Material 3 "emphasized" easing, lively but controlled. The default for
  /// enter/exit and anything that grows or morphs.
  static const Curve emphasized = Cubic(0.2, 0.0, 0.0, 1.0);

  /// A calmer ease-out cubic, for hovers, fades, and moves in place.
  static const Curve standard = Curves.easeOutCubic;

  /// A small glyph landing with a slight overshoot: a pin, a swatch's check,
  /// a chosen icon. Only for things small enough that the overshoot reads as
  /// a tap answered, never for a surface or a reflow.
  static const Curve pop = Curves.easeOutBack;

  /// Leaving: starts slow and gets out of the way, the counterpart of
  /// [standard] for an exit that should not linger.
  static const Curve accelerate = Curves.easeIn;

  /// The rise and fall inside a loop, so a pulse turns around softly instead
  /// of bouncing off its peaks.
  static const Curve swell = Curves.easeInOutCubic;

  /// The checkbox tick's springy settle, the one place a bounce is wanted.
  static const Curve flourish = Curves.elasticOut;

  /// For motion that can be retargeted or handed off from a finger: a moving
  /// card, a released note. A tween restarted midway jumps in speed; a spring
  /// starts from the speed it already has. Critically damped, so it never
  /// overshoots, and perceived as [base] long.
  static final SpringDescription spring =
      SpringDescription.withDurationAndBounce(duration: base);

  /// [spring] from [from] to [to], starting at [velocity] units per second.
  static Simulation springTo(double from, double to, {double velocity = 0}) =>
      SpringSimulation(spring, from, to, velocity, snapToEnd: true);

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

  /// An [Image.frameBuilder] that fades a picture in once its first frame is
  /// decoded instead of popping it over its placeholder. An image already in
  /// the cache arrives synchronously and shows at once, so scrolling back to
  /// it never flickers.
  static Widget fadeInFrame(
    BuildContext context,
    Widget child,
    int? frame,
    bool wasSynchronouslyLoaded,
  ) {
    if (wasSynchronouslyLoaded || reduced(context)) {
      return child;
    }

    return AnimatedOpacity(
      opacity: frame == null ? 0 : 1,
      duration: base,
      curve: standard,
      child: child,
    );
  }

  /// How far a view's notes rise when they replace another view's.
  static const double viewSlide = 12;

  /// Share of its entrance an incoming view waits before showing, so it
  /// arrives as the outgoing one is nearly gone.
  static const double _viewEnterDelay = 0.35;

  /// An [AnimatedSwitcher.transitionBuilder] for one set of notes replacing
  /// another, a fade through: the old set fades out where it is, and the new
  /// one fades in a beat later as it rises into place. Sliding the old set
  /// down while the new one rose dragged two grids through each other.
  ///
  /// The outgoing child runs this same builder with the animation reversed,
  /// which is how it is told apart.
  static Widget viewSwap(Widget child, Animation<double> animation) =>
      AnimatedBuilder(
        animation: animation,
        child: child,
        builder: (context, child) {
          final value = animation.value;
          final leaving =
              animation.status == AnimationStatus.reverse ||
              animation.status == AnimationStatus.dismissed;
          if (leaving) {
            return Opacity(opacity: value, child: child);
          }

          return viewEnter(value, child!);
        },
      );

  /// A view [t] of the way into place: hidden for the first beat, then
  /// fading in as it finishes rising from [viewSlide] below.
  static Widget viewEnter(double t, Widget child) {
    final shown = ((t - _viewEnterDelay) / (1 - _viewEnterDelay)).clamp(
      0.0,
      1.0,
    );
    return Opacity(
      opacity: shown,
      child: Transform.translate(
        offset: Offset(0, (1 - t) * viewSlide),
        child: child,
      ),
    );
  }

  /// True when the OS "reduce motion" accessibility setting is on. Callers skip
  /// or shorten decorative animation so the app stays comfortable to use.
  ///
  /// Depends on that one flag rather than on the whole [MediaQuery]: asking for
  /// all of it subscribes the caller to every unrelated metric change, and the
  /// soft keyboard sliding up changes them on every frame.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}
