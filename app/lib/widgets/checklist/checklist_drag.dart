part of 'animated_checklist.dart';

/// Dragging a row by its handle: sideways to nest it, up and down to
/// reorder unchecked rows.
extension _ChecklistDrag on _AnimatedChecklistState {
  void _indentDragStart(ChecklistItem item) {
    _indentDx = 0;
    _indentStartDepth = item.depth;
  }

  /// Sideways travel indents or outdents, one level per [_kIndentStep], and
  /// the row follows the finger rather than waiting for the release. Measured
  /// from where the gesture started, so overshooting and coming back lands
  /// where the finger says it should.
  void _indentDragUpdate(ChecklistItem item, double dx) {
    _indentDx += dx;
    final wanted = _indentStartDepth + (_indentDx / _kIndentStep).round();
    final current = _byId[item.id]?.depth ?? item.depth;
    if (wanted == current) return;
    final delta = wanted > current ? 1 : -1;
    if (!canShiftDepth(widget.items, item.id, delta)) return;
    // One level per step, so a fast drag cannot skip a level it was not
    // allowed to cross.
    widget.onIndentItem!(item.id, delta);
    HapticFeedback.selectionClick();
  }

  // -------------------------------------------------------------------
  // Drag to reorder (handle-initiated, unchecked rows only)

  /// The rows that travel with a drag: the one grabbed, plus whatever is
  /// nested under it. A task moves with its subtasks or it is not a task.
  List<String> _blockFor(String id) {
    final start = _uncheckedOrder.indexOf(id);
    if (start < 0) return [id];
    final depth = _byId[id]?.depth ?? 0;
    final block = [id];
    for (var i = start + 1; i < _uncheckedOrder.length; i++) {
      final next = _byId[_uncheckedOrder[i]];
      if (next == null || next.depth <= depth) break;
      block.add(next.id);
    }
    return block;
  }

  double _blockHeight() =>
      _draggingBlock.fold<double>(0, (acc, id) => acc + _rowHeight(id));

  void _dragStart(String id, double startTop) {
    _rebuild(() {
      _draggingId = id;
      _draggingBlock = _blockFor(id);
      _dragY = startTop;
    });
  }

  void _dragUpdate(double dy) {
    final draggingId = _draggingId;
    if (draggingId == null) return;
    final blockHeight = _blockHeight();
    final maxY =
        _uncheckedOrder.fold<double>(0, (acc, id) => acc + _rowHeight(id)) -
        blockHeight;
    _dragY = (_dragY + dy).clamp(0.0, maxY < 0 ? 0.0 : maxY);

    // Find the insertion index for the block's leading row, measuring against
    // the rows it is not carrying.
    final center = _dragY + _rowHeight(draggingId) / 2;
    var acc = 0.0;
    var index = 0;
    for (final id in _uncheckedOrder) {
      if (_draggingBlock.contains(id)) continue;
      if (center > acc + _rowHeight(id) / 2) {
        index++;
        acc += _rowHeight(id);
      } else {
        break;
      }
    }
    final rest = [
      for (final id in _uncheckedOrder)
        if (!_draggingBlock.contains(id)) id,
    ];
    _rebuild(() {
      _uncheckedOrder = [
        ...rest.sublist(0, index.clamp(0, rest.length)),
        ..._draggingBlock,
        ...rest.sublist(index.clamp(0, rest.length)),
      ];
    });
  }

  void _dragEnd() {
    if (_draggingId == null) return;
    _rebuild(() {
      _draggingId = null;
      _draggingBlock = const [];
    });
    // The row being written is not in [_uncheckedOrder], but it is still part
    // of the list and must not be dropped from it.
    final composing = _composingId == null ? null : _byId[_composingId];
    final reordered = [
      for (final id in _uncheckedOrder)
        if (_byId[id] case final ChecklistItem item) item,
      ?composing,
      ..._checked,
    ];
    final current = [for (final item in widget.items) item.id];
    final proposed = [for (final item in reordered) item.id];
    if (current.join('|') != proposed.join('|')) {
      widget.onReorderItems(reordered);
    }
  }
}
