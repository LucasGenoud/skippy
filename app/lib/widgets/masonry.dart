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

/// The result of one drag reorder.
///
/// The layout owns these gesture facts; consumers should not have to infer the
/// dragged item from two lists, which is ambiguous for adjacent moves. Whether
/// an ancestor [DragTarget] accepted the drop is included so each consumer can
/// decide whether the reorder or the target action owns the gesture.
@immutable
class MasonryReorder {
  final String draggedId;
  final int fromIndex;
  final int toIndex;
  final List<String> orderedIds;
  final bool acceptedByTarget;

  MasonryReorder({
    required this.draggedId,
    required this.fromIndex,
    required this.toIndex,
    required Iterable<String> orderedIds,
    required this.acceptedByTarget,
  }) : orderedIds = List<String>.unmodifiable(orderedIds);
}

/// What the masonry should do with its temporary order after the callback.
enum MasonryReorderDecision { keep, restore }

/// Persists or otherwise accepts a reorder.
///
/// Return [MasonryReorderDecision.keep] after accepting the reorder. Return
/// [MasonryReorderDecision.restore] when another target owns the gesture or the
/// reorder is stale/invalid; the masonry then restores the order supplied
/// through [AnimatedMasonry.notes].
typedef MasonryReorderCallback =
    MasonryReorderDecision Function(MasonryReorder reorder);

/// Asks the enclosing [AnimatedMasonry] to paint one tile above the others.
///
/// Tiles are absolutely positioned siblings in a Stack, so a card that moves
/// out of its own slot under a finger — a swipe — slides *under* whichever
/// neighbour the packer happened to place after it, and over the ones it
/// placed before: the same gesture would look different in each column. A tile
/// dispatches this while it is off its slot, and again with [raised] false
/// once it has settled back.
class MasonryRaiseTileNotification extends Notification {
  final String noteId;
  final bool raised;

  const MasonryRaiseTileNotification(this.noteId, {required this.raised});
}

/// A masonry grid where every layout change animates.
///
/// Tiles are absolutely positioned in a Stack; their heights are measured
/// after layout, and any reflow (reorder, edit, insert, column change) glides
/// tiles to their new spots with [AnimatedPositioned]. Long-pressing a tile
/// lifts it into a drag; the remaining tiles flow around the pointer in real
/// time and the grid auto-scrolls near the viewport edges.
///
/// Positions are recomputed for the full item set, but only cards near the
/// viewport are mounted. Unseen cards use an estimated height until measured.
class AnimatedMasonry extends StatefulWidget {
  final List<Note> notes;
  final int columns;
  final double spacing;
  final Widget Function(BuildContext context, Note note) itemBuilder;

  /// Everything [itemBuilder] reads besides the note itself, per card.
  ///
  /// [itemBuilder] is a closure rebuilt with its parent, so it is never equal
  /// to the previous one and cannot say whether it would still produce the
  /// same card. Left null, the tile cache is therefore dropped on *every*
  /// parent rebuild, which is always correct but can be very wasteful: the
  /// parent rebuilds for reasons that have nothing to do with the cards, and
  /// the grid in particular is built inside a `LayoutBuilder`, so the keyboard
  /// sliding up (which changes the available height, never the width) re-ran
  /// it on every frame of the animation and rebuilt every card with it.
  ///
  /// Return the state the builder closes over (selection, query) for [note].
  /// A selection change then rebuilds only cards whose own key changed.
  final Object? Function(Note note)? itemBuildKey;

  final bool dragEnabled;

  /// When set, only these notes can start a drag.
  final Set<String>? draggableIds;

  /// Selected notes that reorder together inside this masonry. Other views
  /// can allow multi-card drops without changing their own ordering policy.
  final Set<String> reorderGroupIds;

  /// A short label shown on the floating drag preview.
  final String? dragFeedbackLabel;
  final MasonryReorderCallback? onReorder;

  /// Touch long presses that end without movement select this note; moving
  /// after the hold keeps the existing reorder behavior.
  final ValueChanged<String>? onStationaryLongPress;

  /// The page-level scroll controller, used for edge auto-scroll while
  /// dragging.
  final ScrollController? scrollController;

  /// Where a card carried in from outside is about to land, or null when
  /// nothing is hovering.
  ///
  /// The grid holds a slot open at this index and marks it, so a drop from
  /// another column can promise a place rather than an unspecified arrival.
  /// Pair it with [insertionIndexAt], which reads a pointer back into one of
  /// these indices. Reordering *within* the grid does not use this, a lifted
  /// tile is already in [notes] and reflows on its own.
  final int? incomingIndex;

  const AnimatedMasonry({
    super.key,
    required this.notes,
    required this.columns,
    required this.itemBuilder,
    this.itemBuildKey,
    this.spacing = 8,
    this.dragEnabled = true,
    this.draggableIds,
    this.reorderGroupIds = const {},
    this.dragFeedbackLabel,
    this.onReorder,
    this.onStationaryLongPress,
    this.scrollController,
    this.incomingIndex,
  });

  @override
  State<AnimatedMasonry> createState() => AnimatedMasonryState();
}

class _Slot {
  final double x;
  final double y;
  final double width;
  const _Slot(this.x, this.y, this.width);
}

class _Layout {
  final Map<String, _Slot> slots;
  final double columnWidth;
  final double totalHeight;

  /// The slot held open for an incoming card, or null when none is hovering.
  final Rect? incomingSlot;

  const _Layout(
    this.slots,
    this.columnWidth,
    this.totalHeight, [
    this.incomingSlot,
  ]);
}

class AnimatedMasonryState extends State<AnimatedMasonry>
    with TickerProviderStateMixin {
  static const double _estimatedHeight = 120;
  static const Duration _moveDuration = Duration(milliseconds: 240);
  static const int _buildBatchSize = 20;

  /// How tall a slot held open for an incoming card is. The card's own height
  /// is unknowable while it belongs to somewhere else, so this is a stand-in
  /// big enough to read as a card-shaped opening.
  static const double _incomingSlotHeight = 72;

  final Map<String, double> _heights = {};
  List<String> _orderIds = [];
  int _unscrolledCount = 0;
  bool _batchScheduled = false;
  Set<String> _visibleIds = const {};
  Rect? _viewportBounds;
  bool _viewportScheduled = false;
  String? _draggingId;
  Set<String> _draggingIds = const {};
  List<String>? _dragStartOrder;

  /// The tile that asked to paint last; see [MasonryRaiseTileNotification].
  String? _raisedId;

  /// Cards that left [AnimatedMasonry.notes] and are fading out where they
  /// last stood. They no longer take part in the layout, so the rest of the
  /// grid closes the gap while they go.
  final Map<String, ({Note note, _Slot slot})> _departing = {};

  /// Cards that joined [AnimatedMasonry.notes] since the last frame. Only a
  /// tile mounting in that frame fades in, so one mounted later by scrolling
  /// or progressive loading shows at once.
  final Set<String> _arriving = {};

  // Tile widgets, kept between our own rebuilds. A note card is expensive to
  // build (markdown, linkified spans, image resolution, an OpenContainer
  // each), while a reorder changes where cards go, not what they are, so the
  // same widget instances are handed back and the framework skips their
  // subtrees outright (`Element.updateChild` short-circuits on an identical
  // widget). Dragging is exactly this case: the grid setStates on every step
  // and nothing about the cards themselves has changed.
  //
  // A changed note or per-card build key drops just that card. Without a key,
  // every parent rebuild drops the cache because the builder may have changed.
  final Map<String, Widget> _tiles = {};
  final Map<String, Note> _tileNotes = {};
  final Map<String, Object?> _tileKeys = {};

  Widget _tileFor(Note note) {
    final cached = _tiles[note.id];
    final key = widget.itemBuildKey?.call(note);
    if (cached != null &&
        identical(_tileNotes[note.id], note) &&
        _tileKeys[note.id] == key) {
      return cached;
    }
    final built = widget.itemBuilder(context, note);
    _tiles[note.id] = built;
    _tileNotes[note.id] = note;
    _tileKeys[note.id] = key;
    return built;
  }

  /// Whether the user actually moved anything during this drag. Guards
  /// against committing order changes that came from elsewhere (e.g. a
  /// collaborator's update merged mid-drag).
  bool _dragChangedOrder = false;
  bool _dragMoved = false;

  // Skip the glide animation for one frame after geometry changes (initial
  // build, window resize, column count change) so tiles snap instead of
  // melting across the screen.
  double _lastWidth = -1;
  int _lastColumns = -1;
  bool _snapFrame = true;

  Offset? _lastGlobalDragPoint;
  late final Ticker _autoScrollTicker;
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    _orderIds = [for (final n in widget.notes) n.id];
    _unscrolledCount = math.min(_buildBatchSize, _orderIds.length);
    widget.scrollController?.addListener(_onScroll);
    _autoScrollTicker = createTicker(_onAutoScrollTick);
  }

  @override
  void dispose() {
    widget.scrollController?.removeListener(_onScroll);
    _autoScrollTicker.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(AnimatedMasonry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController?.removeListener(_onScroll);
      widget.scrollController?.addListener(_onScroll);
      _viewportBounds = null;
    }
    final ids = [for (final n in widget.notes) n.id];
    _trackPresence(oldWidget, ids);
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
    final live = {...ids, ..._departing.keys};
    _unscrolledCount = math.min(
      math.max(_unscrolledCount, math.min(_buildBatchSize, ids.length)),
      ids.length,
    );
    _heights.removeWhere((id, _) => !live.contains(id));
    // The usual way a raised tile ends is the note leaving the view, which is
    // exactly what it was swiped off the grid for.
    if (_raisedId != null && !ids.contains(_raisedId)) {
      _raisedId = null;
    }
    // With per-card keys, [_tileFor] decides which survivors changed. No key
    // means the builder may have changed arbitrarily, so drop them all.
    if (widget.itemBuildKey == null) {
      _tiles.clear();
      _tileNotes.clear();
      _tileKeys.clear();
    } else {
      _tiles.removeWhere((id, _) => !live.contains(id));
      _tileNotes.removeWhere((id, _) => !live.contains(id));
      _tileKeys.removeWhere((id, _) => !live.contains(id));
    }
    _invalidateLayout();
  }

  // The packed layout only changes when the order, the heights, or the
  // geometry do, not when a finger moves. Dragging asks for it on every
  // pointer sample, so hand back the last one instead of rebuilding the slot
  // map dozens of times a second.
  _Layout? _layout;
  double _layoutWidth = -1;

  void _invalidateLayout() => _layout = null;

  _Layout _computeLayout(double maxWidth) {
    final cached = _layout;
    if (cached != null && _layoutWidth == maxWidth) return cached;
    final layout = _packLayout(maxWidth, gapAt: widget.incomingIndex);
    _layout = layout;
    _layoutWidth = maxWidth;
    return layout;
  }

  Set<String> _cardsNearViewport(_Layout layout) {
    if (widget.scrollController == null) {
      return _orderIds.take(_unscrolledCount).toSet();
    }
    final viewport = _viewportBounds;
    if (viewport == null) return _orderIds.take(_buildBatchSize).toSet();
    final margin = viewport.height / 2;
    final top = viewport.top - margin;
    final bottom = viewport.bottom + margin;
    return {
      for (final id in _orderIds)
        if (layout.slots[id] case final _Slot slot)
          if (slot.y <= bottom &&
              slot.y + (_heights[id] ?? _estimatedHeight) >= top)
            id,
    };
  }

  void _onScroll() => _scheduleViewportUpdate();

  void _scheduleViewportUpdate() {
    if (_viewportScheduled || widget.scrollController == null) return;
    _viewportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportScheduled = false;
      if (!mounted || _layout == null) return;
      final viewport = _viewportRect();
      final box = context.findRenderObject() as RenderBox?;
      if (viewport == null || box == null || !box.attached || !box.hasSize) {
        return;
      }
      _viewportBounds = Rect.fromPoints(
        box.globalToLocal(viewport.topLeft),
        box.globalToLocal(viewport.bottomRight),
      );
      final next = _cardsNearViewport(_layout!);
      if (!setEquals(next, _visibleIds)) setState(() => _visibleIds = next);
    });
  }

  _Layout _packLayout(double maxWidth, {int? gapAt}) {
    final columns = widget.columns;
    final spacing = widget.spacing;
    final columnWidth = (maxWidth - spacing * (columns - 1)) / columns;
    final columnHeights = List<double>.filled(columns, 0);
    final slots = <String, _Slot>{};
    final notesById = {for (final note in widget.notes) note.id: note};
    Rect? incoming;

    int shortestColumn() {
      var col = 0;
      for (var c = 1; c < columns; c++) {
        if (columnHeights[c] < columnHeights[col] - 0.5) col = c;
      }
      return col;
    }

    // The opening goes where the card itself would go, so the tiles below it
    // move by exactly what the drop will cost them.
    void reserveIncoming() {
      final col = shortestColumn();
      incoming = Rect.fromLTWH(
        col * (columnWidth + spacing),
        columnHeights[col],
        columnWidth,
        _incomingSlotHeight,
      );
      columnHeights[col] += _incomingSlotHeight + spacing;
    }

    for (var i = 0; i < _orderIds.length; i++) {
      if (gapAt == i) reserveIncoming();
      final id = _orderIds[i];
      final span = (notesById[id]?.gridSpan ?? 1).clamp(1, columns);
      var col = 0;
      var y = double.infinity;
      for (var start = 0; start <= columns - span; start++) {
        final top = columnHeights.sublist(start, start + span).reduce(math.max);
        if (top < y - 0.5) {
          col = start;
          y = top;
        }
      }
      final width = columnWidth * span + spacing * (span - 1);
      slots[id] = _Slot(col * (columnWidth + spacing), y, width);
      final bottom = y + (_heights[id] ?? _estimatedHeight) + spacing;
      for (var c = col; c < col + span; c++) {
        columnHeights[c] = bottom;
      }
    }
    if (gapAt != null && gapAt >= _orderIds.length) reserveIncoming();

    final total = columnHeights.reduce(math.max);
    return _Layout(
      slots,
      columnWidth,
      total <= 0 ? 0 : total - spacing,
      incoming,
    );
  }

  /// Which index a card carried in from outside would land at.
  ///
  /// [globalTop] is the top edge of the card being carried, not the pointer:
  /// a [DragTarget] reports the corner of the feedback widget, and that is
  /// also what the user sees hovering over the column, so the slot lines up
  /// with the card they are holding. Tiles claim the half of themselves the
  /// card's edge has passed, which makes the answer stable while the pointer
  /// jitters inside one of them.
  int insertionIndexAt(Offset globalTop) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return _orderIds.length;
    final local = box.globalToLocal(globalTop);
    // Hit-tested against the grid as it would sit with nothing hovering:
    // measuring against a layout that already holds a slot open would let the
    // opening drive the answer that put it there.
    final layout = _packLayout(box.size.width);
    for (var i = 0; i < _orderIds.length; i++) {
      final id = _orderIds[i];
      final slot = layout.slots[id]!;
      final height = _heights[id] ?? _estimatedHeight;
      if (local.dy < slot.y + height / 2) return i;
    }
    return _orderIds.length;
  }

  /// Records which cards just arrived and which just left, before the order
  /// and caches forget the leavers. A card on screen that leaves keeps its
  /// last slot while it fades; one coming back mid-exit simply returns.
  void _trackPresence(AnimatedMasonry oldWidget, List<String> ids) {
    final incoming = ids.toSet();
    final previous = {for (final n in oldWidget.notes) n.id};
    _departing.removeWhere((id, _) => incoming.contains(id));
    for (final id in incoming) {
      if (!previous.contains(id)) {
        _arriving.add(id);
      }
    }

    // Mid-drag the drag owns every card's position; let leavers just go.
    final slots = _layout?.slots;
    if (_draggingId != null || slots == null) {
      return;
    }

    for (final note in oldWidget.notes) {
      final slot = slots[note.id];
      if (incoming.contains(note.id) ||
          slot == null ||
          !_visibleIds.contains(note.id)) {
        continue;
      }
      _departing[note.id] = (note: note, slot: slot);
    }
  }

  void _onDeparted(String id) {
    if (!mounted || !_departing.containsKey(id)) {
      return;
    }

    setState(() {
      _departing.remove(id);
      _heights.remove(id);
      _tiles.remove(id);
      _tileNotes.remove(id);
      _tileKeys.remove(id);
    });
  }

  void _onHeightMeasured(String id, double height) {
    if (!mounted) return;
    if (_departing.containsKey(id)) {
      return;
    }
    if ((_heights[id] ?? -1) == height) return;
    setState(() {
      _heights[id] = height;
      _invalidateLayout();
    });
  }

  // -------------------------------------------------------------------
  // Drag handling

  void _onDragStarted(String id) {
    HapticFeedback.mediumImpact();
    _dragChangedOrder = false;
    _dragMoved = false;
    _dragStartOrder = List<String>.unmodifiable(_orderIds);
    setState(() {
      _draggingId = id;
      _draggingIds = widget.reorderGroupIds.contains(id)
          ? {
              for (final noteId in _orderIds)
                if (widget.reorderGroupIds.contains(noteId)) noteId,
            }
          : {id};
    });
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
      if (_draggingIds.contains(id)) continue;
      final slot = layout.slots[id]!;
      final rect = Rect.fromLTWH(
        slot.x,
        slot.y,
        slot.width,
        _heights[id] ?? _estimatedHeight,
      );
      if (rect.contains(local)) {
        targetId = id;
        break;
      }
    }

    final atEnd =
        targetId == null &&
        local.dy > layout.totalHeight &&
        local.dx >= 0 &&
        local.dx <= box.size.width;
    if (targetId == null && !atEnd) return;

    final from = _orderIds.indexOf(draggingId);
    final targetIndex = targetId == null
        ? _orderIds.length
        : _orderIds.indexOf(targetId);
    final moving = [
      for (final id in _orderIds)
        if (_draggingIds.contains(id)) id,
    ];
    final remaining = [
      for (final id in _orderIds)
        if (!_draggingIds.contains(id)) id,
    ];
    final insertAt = targetId == null
        ? remaining.length
        : remaining.indexOf(targetId) + (targetIndex > from ? 1 : 0);
    final next = [...remaining]..insertAll(insertAt, moving);
    if (listEquals(next, _orderIds)) return;
    setState(() {
      _orderIds = next;
      _invalidateLayout();
    });
    _dragChangedOrder = true;
    HapticFeedback.selectionClick();
  }

  /// [tookIt] records that a [DragTarget] accepted the card. The consumer owns
  /// what that means: a grid ignores the incidental reorder on the way to a
  /// sidebar action, while a board verifies whether the card actually changed
  /// columns. Keeping that policy outside this layout avoids target-specific
  /// behavior in a generic masonry widget.
  void _onDragEnd({bool selectWhenStationary = false, bool tookIt = false}) {
    _stopAutoScroll();
    _lastGlobalDragPoint = null;
    final draggingId = _draggingId;
    if (draggingId == null) return;
    final stationary = !_dragMoved;
    setState(() {
      _draggingId = null;
      _draggingIds = const {};
    });
    final original = _dragStartOrder ?? [for (final n in widget.notes) n.id];
    final fromIndex = original.indexOf(draggingId);
    final toIndex = _orderIds.indexOf(draggingId);
    final sameItems =
        original.length == _orderIds.length &&
        setEquals(original.toSet(), _orderIds.toSet());
    var decision = MasonryReorderDecision.restore;
    if (_dragChangedOrder &&
        sameItems &&
        fromIndex >= 0 &&
        toIndex >= 0 &&
        !listEquals(original, _orderIds)) {
      decision =
          widget.onReorder?.call(
            MasonryReorder(
              draggedId: draggingId,
              fromIndex: fromIndex,
              toIndex: toIndex,
              orderedIds: _orderIds,
              acceptedByTarget: tookIt,
            ),
          ) ??
          MasonryReorderDecision.restore;
    }
    if (decision == MasonryReorderDecision.restore) {
      setState(() {
        _orderIds = [for (final note in widget.notes) note.id];
        _invalidateLayout();
      });
    }
    _dragChangedOrder = false;
    _dragStartOrder = null;
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
    if (widget.scrollController?.hasClients != true) return null;
    final context =
        widget.scrollController?.position.context.notificationContext;
    final box = context?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
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

  /// One card at its slot. Arriving, staying and leaving cards share this
  /// exact shape, so a card that leaves (or returns) keeps its element and
  /// every bit of state below it, a swiped-away card stays swiped away while
  /// it fades.
  Widget _positionedTile(
    Note note,
    _Slot slot,
    _Layout layout,
    _Presence presence,
  ) => AnimatedPositioned(
    key: ValueKey(note.id),
    duration: _snapFrame ? Duration.zero : _moveDuration,
    curve: Motion.standard,
    left: slot.x,
    top: slot.y,
    width: slot.width,
    child: _TilePresence(
      presence: presence,
      onDeparted: () => _onDeparted(note.id),
      child: MeasureSize(
        onChange: (size) => _onHeightMeasured(note.id, size.height),
        child: RepaintBoundary(child: _buildTile(note, layout)),
      ),
    ),
  );

  Widget _buildTile(Note note, _Layout layout) {
    final child = _tileFor(note);
    if (_draggingIds.contains(note.id) && note.id != _draggingId) {
      return Opacity(opacity: 0.30, child: child);
    }
    final canDrag =
        widget.draggableIds == null || widget.draggableIds!.contains(note.id);
    // Keep the desktop wrapper mounted when selection disables a card's drag.
    if (!widget.dragEnabled ||
        widget.onReorder == null ||
        (isTouchPrimaryPlatform && !canDrag)) {
      return child;
    }

    // Built through a Builder so the second copy of the card only comes into
    // existence when a drag actually lifts one. Eagerly building feedback for
    // every tile doubled the cost of every grid rebuild, and rebuilds happen
    // on each reorder step, which is exactly when the frame budget is tight.
    // It must be its own instance rather than the cached child: both are
    // mounted at once during a drag.
    final feedback = Builder(
      builder: (context) => _DragFeedback(
        width: layout.slots[note.id]!.width,
        label: widget.dragFeedbackLabel,
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
        onDragEnd: (details) => _onDragEnd(tookIt: details.wasAccepted),
        maxSimultaneousDrags: canDrag ? 1 : 0,
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
      onDragEnd: (details) =>
          _onDragEnd(selectWhenStationary: true, tookIt: details.wasAccepted),
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
        if (widget.scrollController == null &&
            _unscrolledCount < _orderIds.length &&
            !_batchScheduled) {
          _batchScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _batchScheduled = false;
            if (!mounted) return;
            setState(() {
              _unscrolledCount = math.min(
                _unscrolledCount + _buildBatchSize,
                _orderIds.length,
              );
            });
          });
        }
        _visibleIds = _cardsNearViewport(layout);
        _scheduleViewportUpdate();
        final snap = _snapFrame;
        // Re-arm the glide animation for the frames that follow this one.
        if (snap) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _snapFrame = false);
          });
        }
        // Painting order, which is the order of this list, is the packed
        // order — except for leaving cards, which go first so the ones
        // gliding into their gap pass over them, and a raised tile, which
        // goes last. Every tile is keyed, so moving one to the end of the
        // list moves what it paints over, not the element it is built from.
        final tiles = <Widget>[
          for (final gone in _departing.values)
            _positionedTile(gone.note, gone.slot, layout, _Presence.leaving),
        ];
        Widget? raised;
        for (final id in _orderIds) {
          if (!_visibleIds.contains(id)) continue;
          if (notesById[id] case final Note note) {
            final tile = _positionedTile(
              note,
              layout.slots[note.id]!,
              layout,
              _arriving.contains(note.id)
                  ? _Presence.arriving
                  : _Presence.present,
            );
            if (note.id == _raisedId) {
              raised = tile;
            } else {
              tiles.add(tile);
            }
          }
        }
        if (raised != null) tiles.add(raised);
        if (_arriving.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _arriving.clear();
          });
        }

        return NotificationListener<MasonryRaiseTileNotification>(
          onNotification: (notification) {
            final next = notification.raised
                ? notification.noteId
                : (_raisedId == notification.noteId ? null : _raisedId);
            if (next != _raisedId) setState(() => _raisedId = next);
            return true;
          },
          child: SizedBox(
            height: layout.totalHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // First, so tiles gliding out of the way pass over it.
                if (layout.incomingSlot case final Rect slot)
                  Positioned.fromRect(rect: slot, child: const _IncomingSlot()),
                ...tiles,
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Where a card is in its life on the grid.
enum _Presence { arriving, present, leaving }

/// Fades and scales a card in when it joins a shown grid and out when it
/// leaves one. Always in the tree, so toggling it never remounts the card.
///
/// Fail-open: a tile whose tickers are off (its route covered) skips the
/// entrance and exits at once, so no card can be left invisible or linger.
class _TilePresence extends StatefulWidget {
  final _Presence presence;
  final VoidCallback onDeparted;
  final Widget child;

  const _TilePresence({
    required this.presence,
    required this.onDeparted,
    required this.child,
  });

  @override
  State<_TilePresence> createState() => _TilePresenceState();
}

class _TilePresenceState extends State<_TilePresence>
    with SingleTickerProviderStateMixin {
  static const double _hiddenScale = 0.95;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Motion.base,
    reverseDuration: Motion.fast,
    value: 1,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Motion.emphasized,
    reverseCurve: Motion.standard,
  );
  late final Animation<double> _scale = _curve.drive(
    Tween(begin: _hiddenScale, end: 1),
  );
  bool _started = false;

  bool get _animates =>
      !Motion.reduced(context) && TickerMode.valuesOf(context).enabled;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Only the first call is the mount; later ones are a route covering or
    // uncovering the grid, which must not replay the entrance.
    if (_started) {
      return;
    }

    _started = true;
    if (widget.presence == _Presence.arriving && _animates) {
      _controller.forward(from: 0);
    }
  }

  @override
  void didUpdateWidget(_TilePresence oldWidget) {
    super.didUpdateWidget(oldWidget);
    final leaving = widget.presence == _Presence.leaving;
    if (leaving == (oldWidget.presence == _Presence.leaving)) {
      return;
    }

    if (!leaving) {
      _controller.forward();
      return;
    }

    if (!_animates) {
      _controller.value = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onDeparted());
      return;
    }

    // A reverse cancelled by the card coming back never completes.
    _controller.reverse().then((_) => widget.onDeparted());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: widget.presence == _Presence.leaving,
    child: FadeTransition(
      opacity: _curve,
      child: ScaleTransition(scale: _scale, child: widget.child),
    ),
  );
}

/// The opening a hovering card is about to drop into: an outline where the
/// card will be, rather than a hint that the column will take it somewhere.
class _IncomingSlot extends StatelessWidget {
  const _IncomingSlot();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(kRadius),
        border: Border.all(color: scheme.primary, width: 2),
      ),
    );
  }
}

/// The floating tile that follows the pointer: lifts with a quick scale and
/// shadow animation on pick-up.
class _DragFeedback extends StatelessWidget {
  final double width;
  final String? label;
  final Widget child;
  const _DragFeedback({required this.width, this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      // The lifted card is repositioned on every pointer sample. Without a
      // boundary of its own, each of those moves repaints the whole card *and*
      // its blurred shadow; with one, the rasterized layer is simply moved.
      child: Opacity(
        opacity: 0.84,
        child: RepaintBoundary(
          child: Material(
            type: MaterialType.transparency,
            child: Stack(
              children: [
                child,
                if (label != null)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Material(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(kRadius),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Text(
                          label!,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.onPrimary,
                              ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
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
