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

  /// Touch long presses that end without movement select this note; moving
  /// after the hold keeps the existing reorder behavior.
  final ValueChanged<String>? onStationaryLongPress;

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
    this.onStationaryLongPress,
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

  // Tile widgets, kept between our own rebuilds. A note card is expensive to
  // build (markdown, linkified spans, image resolution, an OpenContainer
  // each), while a reorder changes where cards go, not what they are — so the
  // same widget instances are handed back and the framework skips their
  // subtrees outright (`Element.updateChild` short-circuits on an identical
  // widget). Dragging is exactly this case: the grid setStates on every step
  // and nothing about the cards themselves has changed.
  //
  // The cache is dropped whenever the note object changes, and wholesale on
  // every parent rebuild ([didUpdateWidget]) — the parent's [itemBuilder] can
  // read state of its own (selection, search query), so anything that could
  // make it produce a different card also empties this.
  final Map<String, Widget> _tiles = {};
  final Map<String, Note> _tileNotes = {};

  Widget _tileFor(Note note) {
    final cached = _tiles[note.id];
    if (cached != null && identical(_tileNotes[note.id], note)) return cached;
    final built = widget.itemBuilder(context, note);
    _tiles[note.id] = built;
    _tileNotes[note.id] = note;
    return built;
  }

  /// Whether the user actually moved anything during this drag. Guards
  /// against committing order changes that came from elsewhere (e.g. a
  /// collaborator's update merged mid-drag).
  bool _dragChangedOrder = false;
  bool _dragMoved = false;
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
    // A brisk, one-shot cascade: each tile takes a 0.5 slice (see
    // [_TileEntrance]), so no single tile animates longer than 210ms.
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
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
    final live = ids.toSet();
    _heights.removeWhere((id, _) => !live.contains(id));
    _tiles.clear();
    _tileNotes.clear();
    _invalidateLayout();
  }

  // The packed layout only changes when the order, the heights, or the
  // geometry do — not when a finger moves. Dragging asks for it on every
  // pointer sample, so hand back the last one instead of rebuilding the slot
  // map dozens of times a second.
  _Layout? _layout;
  double _layoutWidth = -1;

  void _invalidateLayout() => _layout = null;

  _Layout _computeLayout(double maxWidth) {
    final cached = _layout;
    if (cached != null && _layoutWidth == maxWidth) return cached;
    final layout = _packLayout(maxWidth);
    _layout = layout;
    _layoutWidth = maxWidth;
    return layout;
  }

  _Layout _packLayout(double maxWidth) {
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
      _invalidateLayout();
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
    _dragMoved = false;
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
      _invalidateLayout();
    });
    _dragChangedOrder = true;
    HapticFeedback.selectionClick();
  }

  void _onDragEnd({bool selectWhenStationary = false}) {
    _stopAutoScroll();
    _lastGlobalDragPoint = null;
    final draggingId = _draggingId;
    if (draggingId == null) return;
    final stationary = !_dragMoved;
    setState(() => _draggingId = null);
    final original = [for (final n in widget.notes) n.id];
    if (_dragChangedOrder && !listEquals(original, _orderIds)) {
      widget.onReorder?.call(List<String>.from(_orderIds));
    }
    _dragChangedOrder = false;
    if (selectWhenStationary && stationary) {
      widget.onStationaryLongPress?.call(draggingId);
    }
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
    final child = _tileFor(note);
    if (!widget.dragEnabled || widget.onReorder == null) return child;

    // Built through a Builder so the second copy of the card only comes into
    // existence when a drag actually lifts one. Eagerly building feedback for
    // every tile doubled the cost of every grid rebuild — and rebuilds happen
    // on each reorder step, which is exactly when the frame budget is tight.
    // It must be its own instance rather than the cached child: both are
    // mounted at once during a drag.
    final feedback = Builder(
      builder: (context) => _DragFeedback(
        width: layout.columnWidth,
        child: widget.itemBuilder(context, note),
      ),
    );
    final ghost = Opacity(opacity: 0.30, child: child);

    // Mouse users get instant grab-and-drag (desktop scrolls with the wheel,
    // so nothing competes for the gesture). On touch, moving after the hold
    // reorders while releasing in place selects the card.
    if (!isTouchPrimaryPlatform) {
      return Draggable<String>(
        data: note.id,
        feedback: feedback,
        childWhenDragging: ghost,
        onDragStarted: () => _onDragStarted(note.id),
        onDragUpdate: (details) {
          _dragMoved = true;
          _onDragMove(details.globalPosition);
        },
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
      onDragUpdate: (details) {
        if (details.delta != Offset.zero) _dragMoved = true;
        if (_dragMoved) _onDragMove(details.globalPosition);
      },
      onDraggableCanceled: (velocity, offset) =>
          _onDragEnd(selectWhenStationary: true),
      onDragEnd: (_) => _onDragEnd(selectWhenStationary: true),
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
          _invalidateLayout();
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

/// Fades and slides each tile into its masonry slot on first appearance. Every
/// tile shares the masonry's one entrance controller; [index] offsets each
/// tile's slice of it (capped) so the grid arrives like staggered bricks,
/// rather than popping together.
class _TileEntrance extends StatelessWidget {
  static const _verticalOffset = 28.0;

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
        // Entrance over: hand back the bare tile. Leaving the opacity and
        // transform in place would keep a compositing layer per tile alive for
        // the rest of the session, for an animation that already finished.
        if (raw == 1) return child!;
        final t = Motion.standard.transform(raw);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, _verticalOffset * (1 - t)),
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
      // The lifted card is repositioned on every pointer sample. Without a
      // boundary of its own, each of those moves repaints the whole card *and*
      // its blurred shadow; with one, the rasterized layer is simply moved.
      child: RepaintBoundary(
        child: Material(type: MaterialType.transparency, child: child),
      ),
      builder: (context, t, child) {
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
            child: child,
          ),
        );
      },
    );
  }
}
