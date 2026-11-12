import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../util/motion.dart';

/// Swaps one view of notes for another: when [viewKey] changes, the new view
/// rises into place from below while the old one sinks away, both fading.
///
/// The old view leaves as a picture of its last frame rather than as live
/// widgets. A view reads the store's active collection and workspace, which
/// have already changed by the time it starts leaving, so a live board would
/// spend its exit redrawing itself as the collection it is being replaced by.
///
///   frame n    [ board A ]                      live
///   switch     [ picture of A ]  sinks, fades   frozen
///              [ grid B ]        rises, fades   live
class ViewSwap extends StatefulWidget {
  final Object viewKey;
  final Widget child;

  const ViewSwap({super.key, required this.viewKey, required this.child});

  @override
  State<ViewSwap> createState() => _ViewSwapState();
}

class _ViewSwapState extends State<ViewSwap> {
  final _boundary = GlobalKey();
  ui.Image? _leaving;
  int _swaps = 0;

  @override
  void didUpdateWidget(ViewSwap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewKey == widget.viewKey) {
      return;
    }

    // Still the old view's frame: nothing has been laid out or painted since
    // the change that brought us here.
    _swaps++;
    _leaving?.dispose();
    _leaving = Motion.reduced(context) ? null : _snapshot();
  }

  @override
  void dispose() {
    _leaving?.dispose();
    super.dispose();
  }

  ui.Image? _snapshot() {
    final boundary = _boundary.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.hasSize) {
      return null;
    }

    try {
      return boundary.toImageSync(
        pixelRatio: MediaQuery.devicePixelRatioOf(context),
      );
    } catch (_) {
      // Not painted yet (debug asserts it), or a renderer without sync
      // snapshots: the old view just goes, the new one still rises in.
      return null;
    }
  }

  void _left(ui.Image image) {
    if (!identical(_leaving, image)) {
      return;
    }

    setState(() => _leaving = null);
    image.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);
    final leaving = _leaving;
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (leaving != null)
            IgnorePointer(
              child: TweenAnimationBuilder<double>(
                key: ValueKey('leaving-$_swaps'),
                tween: Tween(begin: 1, end: 0),
                duration: Motion.fast,
                curve: Motion.standard,
                onEnd: () => _left(leaving),
                builder: (context, t, child) => _placed(t, child!),
                child: RawImage(image: leaving, fit: BoxFit.fill),
              ),
            ),
          RepaintBoundary(
            key: _boundary,
            child: TweenAnimationBuilder<double>(
              key: ValueKey(widget.viewKey),
              // The first view of the screen is just there.
              tween: Tween(begin: _swaps == 0 || reduced ? 1 : 0, end: 1),
              duration: Motion.base,
              curve: Motion.emphasized,
              builder: (context, t, child) => _placed(t, child!),
              child: widget.child,
            ),
          ),
        ],
      ),
    );
  }

  /// A view [t] of the way into place: below it and faded until 1.
  Widget _placed(double t, Widget child) => Opacity(
    opacity: t,
    child: Transform.translate(
      offset: Offset(0, (1 - t) * Motion.viewSlide),
      child: child,
    ),
  );
}
