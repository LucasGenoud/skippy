import 'package:flutter/material.dart';

import '../util/motion.dart';

/// Lays out keyed [children] with [layout], growing and fading each one in
/// when it arrives and out when it leaves, instead of popping. What is there
/// on the first build shows at once.
///
/// A child that disappears from [children] stays where it was until its exit
/// has played:
///
/// ```text
///   build 1: [a, b, c]
///   build 2: [a, c, d]   ->  shown [a, b (leaving), c, d (entering)]
///   exit ends            ->  shown [a, c, d]
/// ```
///
/// Every child needs a key unique among its siblings.
class AnimatedPresence extends StatefulWidget {
  final List<Widget> children;
  final Widget Function(List<Widget> children) layout;

  /// The direction items grow along: vertical for a column, horizontal for
  /// chips in a row.
  final Axis axis;

  const AnimatedPresence({
    super.key,
    required this.children,
    required this.layout,
    this.axis = Axis.vertical,
  });

  @override
  State<AnimatedPresence> createState() => _AnimatedPresenceState();
}

class _AnimatedPresenceState extends State<AnimatedPresence> {
  late List<Widget> _shown = [...widget.children];
  final Set<Key> _leaving = {};
  final Set<Key> _entering = {};

  @override
  void didUpdateWidget(AnimatedPresence oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = {for (final child in widget.children) child.key!: child};
    final order = [for (final child in widget.children) child.key!];
    final before = {for (final child in _shown) child.key!};

    // Walk the old order, emitting new children as their old neighbours come
    // up, so a leaving child keeps its slot between the ones around it.
    final merged = <Widget>[];
    final placed = <Key>{};
    var next = 0;
    for (final old in _shown) {
      final key = old.key!;
      if (!incoming.containsKey(key)) {
        merged.add(old);
        _leaving.add(key);
        continue;
      }
      if (placed.contains(key)) {
        continue;
      }
      while (next < order.length) {
        final candidate = order[next++];
        if (placed.add(candidate)) {
          merged.add(incoming[candidate]!);
        }
        if (candidate == key) {
          break;
        }
      }
    }
    for (; next < order.length; next++) {
      if (placed.add(order[next])) {
        merged.add(incoming[order[next]]!);
      }
    }

    for (final key in order) {
      _leaving.remove(key);
      if (!before.contains(key)) {
        _entering.add(key);
      }
    }
    _shown = merged;
  }

  void _drop(Key key) {
    if (!mounted || !_leaving.contains(key)) {
      return;
    }

    setState(() {
      _shown.removeWhere((child) => child.key == key);
      _leaving.remove(key);
      _entering.remove(key);
    });
  }

  @override
  Widget build(BuildContext context) => widget.layout([
    for (final child in _shown)
      _PresenceItem(
        key: child.key,
        presence: _leaving.contains(child.key)
            ? _Presence.leaving
            : _entering.contains(child.key)
            ? _Presence.arriving
            : _Presence.present,
        axis: widget.axis,
        onExited: () => _drop(child.key!),
        child: child,
      ),
  ]);
}

/// Where a child is in its life in the layout.
enum _Presence { arriving, present, leaving }

class _PresenceItem extends StatefulWidget {
  final _Presence presence;
  final Axis axis;
  final VoidCallback onExited;
  final Widget child;

  const _PresenceItem({
    super.key,
    required this.presence,
    required this.axis,
    required this.onExited,
    required this.child,
  });

  @override
  State<_PresenceItem> createState() => _PresenceItemState();
}

class _PresenceItemState extends State<_PresenceItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Motion.base,
    reverseDuration: Motion.fast,
    value: widget.presence == _Presence.arriving ? 0 : 1,
  );
  late final Animation<double> _size = CurvedAnimation(
    parent: _controller,
    curve: Motion.emphasized,
    reverseCurve: Motion.standard,
  );
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _controller,
    curve: Motion.standard,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = Motion.reduced(context);
    _controller.duration = reduced ? Duration.zero : Motion.base;
    _controller.reverseDuration = reduced ? Duration.zero : Motion.fast;
    if (widget.presence == _Presence.arriving && _controller.isDismissed) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(_PresenceItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    final leaving = widget.presence == _Presence.leaving;
    if (leaving == (oldWidget.presence == _Presence.leaving)) {
      return;
    }

    if (!leaving) {
      _controller.forward();
    } else {
      // A cancelled reverse (the child came back) never completes, so this
      // only drops a child whose exit actually finished.
      _controller.reverse().then((_) => widget.onExited());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizeTransition(
    sizeFactor: _size,
    axis: widget.axis,
    alignment: AlignmentDirectional.topStart,
    child: FadeTransition(opacity: _opacity, child: widget.child),
  );
}
