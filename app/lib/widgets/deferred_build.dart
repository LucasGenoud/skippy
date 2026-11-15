import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../util/motion.dart';

/// Builds [child] [frames] frames after it mounts, showing [placeholder] until
/// then.
///
/// For parts of a screen that are expensive to build and not yet visible when
/// the screen appears, so the cost lands in frames nobody sees rather than in
/// the one that starts an animation. With reduced motion a screen is visible
/// at once, so [child] is built straight away.
class DeferredBuild extends StatefulWidget {
  final int frames;
  final Widget placeholder;
  final Widget child;

  const DeferredBuild({
    super.key,
    this.frames = 1,
    this.placeholder = const SizedBox.shrink(),
    required this.child,
  });

  @override
  State<DeferredBuild> createState() => _DeferredBuildState();
}

class _DeferredBuildState extends State<DeferredBuild> {
  int _waited = 0;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addPostFrameCallback(_afterFrame);
  }

  void _afterFrame(Duration _) {
    if (!mounted || _ready) {
      return;
    }

    _waited++;
    if (_waited >= widget.frames) {
      setState(() => _ready = true);
      return;
    }

    SchedulerBinding.instance
      ..addPostFrameCallback(_afterFrame)
      ..scheduleFrame();
  }

  @override
  Widget build(BuildContext context) {
    _ready |= Motion.reduced(context);
    return _ready ? widget.child : widget.placeholder;
  }
}
