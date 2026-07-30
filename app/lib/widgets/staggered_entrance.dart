import 'package:flutter/material.dart';

import '../util/motion.dart';

/// Cascades a short, rarely-opened list's rows in on first mount, each row
/// fades and rises slightly, offset by [index] so they don't all land at
/// once. Meant for dialog-sized lists (a handful of rows); the note grid has
/// its own entrance built for hundreds of tiles (see `AnimatedMasonry`).
///
/// Keyed items (e.g. `ValueKey(stage.id)`) only replay the entrance when the
/// State is first created, a freshly-added row cascades in with the rest of
/// the list, but reordering or rebuilding an existing row does not.
class StaggeredEntrance extends StatefulWidget {
  final int index;
  final Widget child;

  const StaggeredEntrance({super.key, required this.index, required this.child});

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance> {
  static const _stagger = Duration(milliseconds: 28);
  static const _cap = Duration(milliseconds: 200);

  bool _shown = false;

  @override
  void initState() {
    super.initState();
    final delay = _stagger * widget.index;
    Future<void>.delayed(delay < _cap ? delay : _cap, () {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);
    final visible = _shown || reduced;
    final duration = reduced ? Duration.zero : Motion.base;
    return AnimatedSlide(
      offset: visible ? Offset.zero : const Offset(0, 0.1),
      duration: duration,
      curve: Motion.emphasized,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: duration,
        curve: Motion.standard,
        child: widget.child,
      ),
    );
  }
}
