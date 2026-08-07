import 'package:flutter/material.dart';

/// The screen *width* on its own, so branching on it doesn't tie a widget to
/// the screen height as well.
///
/// [MediaQuery.sizeOf] is a single aspect covering both axes: a widget that
/// only wants to know "is this a phone?" is still rebuilt every time the height
/// changes. On Android that happens on every frame of the keyboard's slide (the
/// activity is `adjustResize`, so the view really does shrink), which had the
/// whole note grid rebuilding ~60 times per keyboard open. Reading the size in
/// one place and republishing just the width fixes that for every consumer at
/// once: a rebuild here is one widget, and [updateShouldNotify] stops it there
/// unless the width genuinely moved.
///
/// Use [of] for a raw width and [isAtLeast] for a breakpoint. Prefer the
/// breakpoint: it only notifies when the answer flips, so a window drag from
/// 900 to 800 rebuilds nothing.
class ScreenWidth extends StatelessWidget {
  final Widget child;

  const ScreenWidth({super.key, required this.child});

  /// The current width. Rebuilds the caller whenever it changes at all; reach
  /// for [isAtLeast] instead when a threshold is what you actually need.
  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ScreenWidthScope>()?.width ??
      MediaQuery.sizeOf(context).width;

  /// Whether the screen is at least [breakpoint] wide, rebuilding the caller
  /// only when that answer changes.
  static bool isAtLeast(BuildContext context, double breakpoint) {
    final scope = context.dependOnInheritedWidgetOfExactType<_ScreenWidthScope>(
      aspect: breakpoint,
    );
    final width = scope?.width ?? MediaQuery.sizeOf(context).width;
    return width >= breakpoint;
  }

  @override
  Widget build(BuildContext context) =>
      _ScreenWidthScope(width: MediaQuery.sizeOf(context).width, child: child);
}

/// Publishes the width, and notifies a dependent only about the breakpoints it
/// asked for (an [InheritedModel] aspect is the breakpoint itself).
class _ScreenWidthScope extends InheritedModel<double> {
  final double width;

  const _ScreenWidthScope({required this.width, required super.child});

  @override
  bool updateShouldNotify(_ScreenWidthScope oldWidget) =>
      width != oldWidget.width;

  @override
  bool updateShouldNotifyDependent(
    _ScreenWidthScope oldWidget,
    Set<double> breakpoints,
  ) {
    // A dependent that asked for no breakpoint wants the raw width.
    if (breakpoints.isEmpty) return width != oldWidget.width;
    for (final breakpoint in breakpoints) {
      if ((width >= breakpoint) != (oldWidget.width >= breakpoint)) return true;
    }
    return false;
  }
}
