import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Desktop rectangle selection. Regions report the rendered cards and the
/// background they sit on, so it works with virtualized grids and lists.
class MarqueeSelection extends StatefulWidget {
  final Widget child;
  final Set<String> selectedIds;
  final ValueChanged<Set<String>> onSelected;

  const MarqueeSelection({
    super.key,
    required this.child,
    required this.selectedIds,
    required this.onSelected,
  });

  @override
  State<MarqueeSelection> createState() => _MarqueeSelectionState();
}

class _MarqueeSelectionState extends State<MarqueeSelection>
    with SingleTickerProviderStateMixin {
  final _regions = <_MarqueeRegionState>{};
  late final Ticker _scrollTicker = createTicker(_autoScroll);
  Duration _lastTick = Duration.zero;
  int? _pointer;
  Offset? _start;
  Offset? _current;
  Set<String> _initialSelection = const {};
  Set<String> _pendingSelection = const {};
  List<ScrollController> _originControllers = const [];
  bool _additive = false;
  bool _dragging = false;

  void register(_MarqueeRegionState region) => _regions.add(region);
  void unregister(_MarqueeRegionState region) => _regions.remove(region);

  Rect? _rectOf(_MarqueeRegionState region) {
    final box = region.context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Rect get _viewport {
    final box = context.findRenderObject()! as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  _MarqueeRegionState? _canvasAt(Offset point) {
    for (final region in _regions) {
      if (region.widget.noteId == null &&
          (_rectOf(region)?.contains(point) ?? false)) {
        return region;
      }
    }
    return null;
  }

  void _down(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        event.buttons != kPrimaryMouseButton ||
        _pointer != null) {
      return;
    }
    final canvas = _canvasAt(event.position);
    if (canvas == null) return;
    for (final region in _regions) {
      if (region.widget.noteId != null &&
          (_rectOf(region)?.contains(event.position) ?? false)) {
        return; // A card owns its own drag.
      }
    }
    _pointer = event.pointer;
    _start = event.position;
    _current = event.position;
    _initialSelection = Set.of(widget.selectedIds);
    _pendingSelection = _initialSelection;
    _originControllers = canvas.widget.scrollControllers;
    final keyboard = HardwareKeyboard.instance;
    _additive = keyboard.isControlPressed || keyboard.isMetaPressed;
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer || _start == null) return;
    _current = event.position;
    if (!_dragging && (event.position - _start!).distanceSquared < 16) return;
    if (!_dragging) {
      _dragging = true;
      _scrollTicker.start();
    }
    _updateSelection();
  }

  void _updateSelection() {
    if (!_dragging || _start == null || _current == null) return;
    final viewport = _viewport;
    final area = Rect.fromPoints(_start!, _current!).intersect(viewport);
    final ids = <String>{if (_additive) ..._initialSelection};
    if (!area.isEmpty) {
      for (final region in _regions) {
        final id = region.widget.noteId;
        if (id != null && (_rectOf(region)?.overlaps(area) ?? false)) {
          ids.add(id);
        }
      }
    }
    _pendingSelection = ids;
    setState(() {});
  }

  void _autoScroll(Duration elapsed) {
    if (!_dragging || _current == null) return;
    final dt = _lastTick == Duration.zero
        ? 1 / 60.0
        : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    final viewport = _viewport;
    final controllers =
        _canvasAt(_current!)?.widget.scrollControllers ?? _originControllers;
    var scrolled = false;
    for (final controller in controllers) {
      if (!controller.hasClients) continue;
      final position = controller.position;
      final horizontal = position.axis == Axis.horizontal;
      final coordinate = horizontal ? _current!.dx : _current!.dy;
      final start = horizontal ? viewport.left : viewport.top;
      final end = horizontal ? viewport.right : viewport.bottom;
      const edge = 48.0;
      final direction = coordinate < start + edge
          ? -((start + edge - coordinate) / edge).clamp(0.0, 1.0)
          : coordinate > end - edge
          ? ((coordinate - end + edge) / edge).clamp(0.0, 1.0)
          : 0.0;
      if (direction == 0) continue;
      final next = (position.pixels + direction * 700 * dt).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (next != position.pixels) {
        controller.jumpTo(next);
        scrolled = true;
      }
    }
    if (scrolled) _updateSelection();
  }

  void _end(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerUpEvent &&
        _dragging &&
        !setEquals(_pendingSelection, widget.selectedIds)) {
      widget.onSelected(_pendingSelection);
    }
    _pointer = null;
    _start = null;
    _current = null;
    _originControllers = const [];
    _dragging = false;
    _scrollTicker.stop();
    _lastTick = Duration.zero;
    setState(() {});
  }

  @override
  void dispose() {
    _scrollTicker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final box = context.findRenderObject();
    final origin = box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero)
        : Offset.zero;
    final area = _dragging && _start != null && _current != null
        ? Rect.fromPoints(_start! - origin, _current! - origin)
        : null;
    final scheme = Theme.of(context).colorScheme;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _end,
      onPointerCancel: _end,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (area != null)
            Positioned.fromRect(
              rect: area,
              child: IgnorePointer(
                child: DecoratedBox(
                  key: const Key('marquee-selection-rect'),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    border: Border.all(color: scheme.primary),
                    borderRadius: kBorderRadius,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A background where marquee selection may begin, or a selectable card.
class MarqueeRegion extends StatefulWidget {
  final Widget child;
  final String? noteId;
  final List<ScrollController> scrollControllers;

  const MarqueeRegion.canvas({
    super.key,
    required this.child,
    this.scrollControllers = const [],
  }) : noteId = null;

  const MarqueeRegion.note({super.key, required this.child, required String id})
    : noteId = id,
      scrollControllers = const [];

  @override
  State<MarqueeRegion> createState() => _MarqueeRegionState();
}

class _MarqueeRegionState extends State<MarqueeRegion> {
  _MarqueeSelectionState? _selection;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context.findAncestorStateOfType<_MarqueeSelectionState>();
    if (next == _selection) return;
    _selection?.unregister(this);
    _selection = next;
    next?.register(this);
  }

  @override
  void dispose() {
    _selection?.unregister(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
