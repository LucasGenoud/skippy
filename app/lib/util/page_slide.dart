import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'motion.dart';

/// A page pushed over another (settings, chat, history, a workspace's pages)
/// arrives from a short way to the right while fading in, and leaves the same
/// way, faster. Only the page moves; the one beneath stays put. The web
/// client's `PAGE` motion is the same.
///
/// ```text
///   push   page  x: +24 -> 0, opacity 0 -> 1   base, emphasized
///   pop    page  x: 0 -> +24, opacity 1 -> 0   fast, standard
/// ```
///
/// iOS keeps its own slide, which carries the edge swipe back.
class PageSlideTransitionsBuilder extends PageTransitionsBuilder {
  const PageSlideTransitionsBuilder();

  /// How far a page travels as it arrives or leaves.
  static const double _shift = 24;

  /// The transitions for every platform, iOS keeping its native one.
  static const PageTransitionsTheme theme = PageTransitionsTheme(
    builders: {
      TargetPlatform.android: PageSlideTransitionsBuilder(),
      TargetPlatform.fuchsia: PageSlideTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.linux: PageSlideTransitionsBuilder(),
      TargetPlatform.macOS: PageSlideTransitionsBuilder(),
      TargetPlatform.windows: PageSlideTransitionsBuilder(),
    },
  );

  @override
  Duration get transitionDuration => Motion.base;

  @override
  Duration get reverseTransitionDuration => Motion.fast;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (Motion.reduced(context)) {
      return child;
    }

    return _PageSlide(animation: animation, child: child);
  }
}

class _PageSlide extends StatefulWidget {
  final Animation<double> animation;
  final Widget child;

  const _PageSlide({required this.animation, required this.child});

  @override
  State<_PageSlide> createState() => _PageSlideState();
}

class _PageSlideState extends State<_PageSlide> {
  late CurvedAnimation _curve = _curved(widget.animation);

  static CurvedAnimation _curved(Animation<double> parent) => CurvedAnimation(
    parent: parent,
    curve: Motion.emphasized,
    reverseCurve: Motion.standard,
  );

  @override
  void didUpdateWidget(_PageSlide oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _curve.dispose();
      _curve = _curved(widget.animation);
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _curve,
    child: AnimatedBuilder(
      animation: _curve,
      child: widget.child,
      builder: (context, child) => Transform.translate(
        offset: Offset(
          (1 - _curve.value) * PageSlideTransitionsBuilder._shift,
          0,
        ),
        child: child,
      ),
    ),
  );
}
