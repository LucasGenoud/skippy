import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../models/note.dart';
import '../util/motion.dart';
import '../util/platform.dart';
import 'measure_size.dart';

/// A masonry grid where every layout change animates.
///
/// Tiles are absolutely positioned in a Stack; their heights are measured
/// after layout, and any reflow (reorder, edit, insert, column change) glides
/// tiles to their new spots with [AnimatedPositioned]. Long-pressing a tile
/// lifts it into a drag; the remaining tiles flow around the pointer in real
/// time and the grid auto-scrolls near the viewport edges.
///
/// Positions are recomputed for the full item set each build (no viewport
/// culling), which is the right trade-off for a personal notes grid.
class AnimatedMasonry extends StatefulWidget {
  final List<Note> notes;
  final int columns;
  final double spacing;
  final Widget Function(BuildContext context, Note note) itemBuilder;
  final bool dragEnabled;
  final ValueChanged<List<String>>? onReorder;

  /// The page-level scroll controller, used for edge auto-scroll while
  /// dragging.
  final ScrollController? scrollController;

  const AnimatedMasonry({
    super.key,
    required this.notes,
    required this.columns,
    required this.itemBuilder,
    this.spacing = 8,
    this.dragEnabled = true,
    this.onReorder,
    this.scrollController,
  });

  @override
  State<AnimatedMasonry> createState() => _AnimatedMasonryState();
}

class _Slot {
  final double x;
  final double y;
  const _Slot(this.x, this.y);
}

class _Layout {
  final Map<String, _Slot> slots;
  final double columnWidth;
  final double totalHeight;
  const _Layout(this.slots, this.columnWidth, this.totalHeight);
}

class _AnimatedMasonryState extends State<AnimatedMasonry>
    with TickerProviderStateMixin {
  static const double _estimatedHeight = 120;
  static const Duration _moveDuration = Duration(milliseconds: 240);

  final Map<String, double> _heights = {};
  List<String> _orderIds = [];
  String? _draggingId;

  /// Whether the user actually moved anything during this drag. Guards
  /// against committing order changes that came from elsewhere (e.g. a
  /// collaborator's update merged mid-drag).
  bool _dragChangedOrder = false;
  bool _ready = false;

  // Skip the glide animation for one frame after geometry changes (initial
  // build, window resize, column count change) so tiles snap instead of
  // melting across the screen.
  double _lastWidth = -1;
  int _lastColumns = -1;
  bool _snapFrame = true;

  Offset? _lastGlobalDragPoint;
  late final Ticker _autoScrollTicker;
  Duration _lastTick = Duration.zero;

  // One-shot staggered entrance: every tile shares this controller and takes a
  // staggered slice of it (see [_TileEntrance]), so the grid cascades in once
  // heights are known.
  late final AnimationController _entranceController;
  bool _entranceStarted = false;

  @override
  void initState() {
    super.initState();
    _orderIds = [for (final n in widget.notes) n.id];
    _autoScrollTicker = createTicker(_onAutoScrollTick);
    // 500ms end-to-end: each tile takes a 0.5 slice (see [_TileEntrance]), so
    // no single tile animates longer than 250ms — the grid still cascades.
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
  }

  @override
  void dispose() {
    _autoScrollTicker.dispose();
    _entranceController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(AnimatedMasonry oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ids = [for (final n in widget.notes) n.id];
    if (_draggingId == null) {
      _orderIds = ids;
    } else {
      // Keep the in-progress drag order; just add/remove what changed.
      final incoming = ids.toSet();
      final existing = _orderIds.toSet();
      _orderIds = [
        for (final id in _orderIds)
          if (incoming.contains(id)) id,
        for (final id in ids)
          if (!existing.contains(id)) id,
      ];
    }
    _heights.removeWhere((id, _) => !ids.contains(id));
  }

  _Layout _computeLayout(double maxWidth) {
    final columns = widget.columns;
    final spacing = widget.spacing;
    final columnWidth = (maxWidth - spacing * (columns - 1)) / columns;
    final columnHeights = List<double>.filled(columns, 0);
    final slots = <String, _Slot>{};
    for (final id in _orderIds) {
      var col = 0;
      for (var c = 1; c < columns; c++) {
        if (columnHeights[c] < columnHeights[col] - 0.5) col = c;
      }
      slots[id] = _Slot(col * (columnWidth + spacing), columnHeights[col]);
      columnHeights[col] += (_heights[id] ?? _estimatedHeight) + spacing;
    }
    final total = columnHeights.reduce(math.max);
    return _Layout(slots, columnWidth, total <= 0 ? 0 : total - spacing);
  }

  void _onHeightMeasured(String id, double height) {
    if (!mounted) return;
    if ((_heights[id] ?? -1) == height) return;
    setState(() {
      _heights[id] = height;
      if (!_ready && _orderIds.every((id) => _heights.containsKey(id))) {
        _ready = true;
      }
    });
  }

  // -------------------------------------------------------------------
  // Drag handling

  void _onDragStarted(String id) {
    HapticFeedback.mediumImpact();
    _dragChangedOrder = false;
    setState(() => _draggingId = id);
  }

  void _onDragMove(Offset globalPosition) {
    _lastGlobalDragPoint = globalPosition;
    _reorderToPointer(globalPosition);
    _updateAutoScroll(globalPosition);
  }

  void _reorderToPointer(Offset globalPosition) {
    final draggingId = _draggingId;
    if (draggingId == null) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final local = box.globalToLocal(globalPosition);
    final layout = _computeLayout(box.size.width);

    String? targetId;
    for (final id in _orderIds) {
      if (id == draggingId) continue;
      final slot = layout.slots[id]!;
      final rect = Rect.fromLTWH(
        slot.x,
        slot.y,
        layout.columnWidth,
        _heights[id] ?? _estimatedHeight,
      );
      if (rect.contains(local)) {
        targetId = id;
        break;
      }
    }

    int? targetIndex;
    if (targetId != null) {
      targetIndex = _orderIds.indexOf(targetId);
    } else if (local.dy > layout.totalHeight &&
        local.dx >= 0 &&
        local.dx <= box.size.width) {
      targetIndex = _orderIds.length - 1;
    }
    if (targetIndex == null) return;

    final from = _orderIds.indexOf(draggingId);
    if (from == targetIndex) return;
    setState(() {
      _orderIds.removeAt(from);
      _orderIds.insert(targetIndex!, draggingId);
    });
    _dragChangedOrder = true;
    HapticFeedback.selectionClick();
  }

  void _onDragEnd() {
    _stopAutoScroll();
    _lastGlobalDragPoint = null;
    if (_draggingId == null) return;
    setState(() => _draggingId = null);
    final original = [for (final n in widget.notes) n.id];
    if (_dragChangedOrder && !listEquals(original, _orderIds)) {
      widget.onReorder?.call(List<String>.from(_orderIds));
    }
    _dragChangedOrder = false;
  }

  // -------------------------------------------------------------------
  // Edge auto-scroll while dragging

  static const double _edgeZone = 110;
  static const double _maxScrollSpeed = 1000; // px/s

  double _scrollVelocity = 0;

  void _updateAutoScroll(Offset globalPosition) {
    final controller = widget.scrollController;
    if (controller == null || !controller.hasClients) return;
    final viewportRect = _viewportRect();
    if (viewportRect == null) return;

    final topGap = globalPosition.dy - viewportRect.top;
    final bottomGap = viewportRect.bottom - globalPosition.dy;
    double v = 0;
    if (topGap < _edgeZone) {
      v = -_maxScrollSpeed * (1 - (topGap / _edgeZone)).clamp(0.0, 1.0);
    } else if (bottomGap < _edgeZone) {
      v = _maxScrollSpeed * (1 - (bottomGap / _edgeZone)).clamp(0.0, 1.0);
    }
    _scrollVelocity = v;
    if (v != 0 && !_autoScrollTicker.isActive) {
      _lastTick = Duration.zero;
      _autoScrollTicker.start();
    } else if (v == 0) {
      _stopAutoScroll();
    }
  }

  Rect? _viewportRect() {
    final context =
        widget.scrollController?.position.context.notificationContext;
    final box = context?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _onAutoScrollTick(Duration elapsed) {
    final controller = widget.scrollController;
    if (controller == null || !controller.hasClients || _scrollVelocity == 0) {
      _stopAutoScroll();
      return;
    }
    final dt = _lastTick == Duration.zero
        ? 1 / 60.0
        : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    final position = controller.position;
    final next = (position.pixels + _scrollVelocity * dt).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (next != position.pixels) {
      controller.jumpTo(next);
      // The grid moved under a stationary pointer; re-evaluate the target.
      if (_lastGlobalDragPoint != null) {
        _reorderToPointer(_lastGlobalDragPoint!);
      }
    }
  }

  void _stopAutoScroll() {
    _scrollVelocity = 0;
    if (_autoScrollTicker.isActive) _autoScrollTicker.stop();
    _lastTick = Duration.zero;
  }

  // -------------------------------------------------------------------

  Widget _buildTile(Note note, _Layout layout) {
    final child = widget.itemBuilder(context, note);
    if (!widget.dragEnabled || widget.onReorder == null) return child;

    final feedback = _DragFeedback(
      width: layout.columnWidth,
      child: widget.itemBuilder(context, note),
    );
    final ghost = Opacity(opacity: 0.30, child: child);

    // Mouse users get instant grab-and-drag (desktop scrolls with the wheel,
    // so nothing competes for the gesture). Touch keeps a short hold so
    // scrolling still wins the arena.
    if (!isTouchPrimaryPlatform) {
      return Draggable<String>(
        data: note.id,
        feedback: feedback,
        childWhenDragging: ghost,
        onDragStarted: () => _onDragStarted(note.id),
        onDragUpdate: (details) => _onDragMove(details.globalPosition),
        onDraggableCanceled: (velocity, offset) => _onDragEnd(),
        onDragEnd: (_) => _onDragEnd(),
        maxSimultaneousDrags: 1,
        child: child,
      );
    }
    return LongPressDraggable<String>(
      data: note.id,
      delay: const Duration(milliseconds: 220),
      feedback: feedback,
      childWhenDragging: ghost,
      onDragStarted: () => _onDragStarted(note.id),
      onDragUpdate: (details) => _onDragMove(details.globalPosition),
      onDraggableCanceled: (velocity, offset) => _onDragEnd(),
      onDragEnd: (_) => _onDragEnd(),
      maxSimultaneousDrags: 1,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.notes.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width != _lastWidth || widget.columns != _lastColumns) {
          _lastWidth = width;
          _lastColumns = widget.columns;
          _snapFrame = true;
        }
        final layout = _computeLayout(width);
        final notesById = {for (final n in widget.notes) n.id: n};
        final snap = _snapFrame;
        // Re-arm the glide animation for the frames that follow this one.
        if (snap) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _snapFrame = false);
          });
        }
        // Kick the one-shot entrance off once every tile has been measured
        // (before that, tiles sit at the controller's 0 value — invisible —
        // while their heights settle).
        if (_ready && !_entranceStarted) {
          _entranceStarted = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (Motion.reduced(context)) {
              _entranceController.value = 1;
            } else {
              _entranceController.forward(from: 0);
            }
          });
        }
        return SizedBox(
          height: layout.totalHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = 0; i < _orderIds.length; i++)
                if (notesById[_orderIds[i]] case final Note note)
                  AnimatedPositioned(
                    key: ValueKey(note.id),
                    duration: snap ? Duration.zero : _moveDuration,
                    curve: Motion.standard,
                    left: layout.slots[note.id]!.x,
                    top: layout.slots[note.id]!.y,
                    width: layout.columnWidth,
                    child: MeasureSize(
                      onChange: (size) =>
                          _onHeightMeasured(note.id, size.height),
                      child: _TileEntrance(
                        animation: _entranceController,
                        index: i,
                        child: RepaintBoundary(child: _buildTile(note, layout)),
                      ),
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }
}

/// Fades and lifts a tile into place on first appearance. Every tile shares the
/// masonry's one entrance controller; [index] offsets each tile's slice of it
/// (capped) so they cascade in rather than popping together.
class _TileEntrance extends StatelessWidget {
  final Animation<double> animation;
  final int index;
  final Widget child;
  const _TileEntrance({
    required this.animation,
    required this.index,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final start = math.min(index * 0.05, 0.5);
    final end = math.min(start + 0.5, 1.0);
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final raw = ((animation.value - start) / (end - start)).clamp(0.0, 1.0);
        final t = Motion.standard.transform(raw);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 8),
            child: child,
          ),
        );
      },
    );
  }
}

/// The floating tile that follows the pointer: lifts with a quick scale and
/// shadow animation on pick-up.
class _DragFeedback extends StatelessWidget {
  final double width;
  final Widget child;
  const _DragFeedback({required this.width, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      builder: (context, t, _) {
        return Transform.scale(
          scale: 1 + 0.04 * t,
          child: Container(
            width: width,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(kRadius),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28 * t),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Material(type: MaterialType.transparency, child: child),
          ),
        );
      },
    );
  }
}
