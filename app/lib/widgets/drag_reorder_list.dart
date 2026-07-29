import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../util/motion.dart';

/// A short, non-scrolling list of fixed-height rows reordered by dragging a
/// handle, with the rest of the list parting live under the pointer.
///
/// This mirrors the checklist editor's reorder (see `animated_checklist.dart`)
/// rather than using [ReorderableListView]: nesting that widget inside a
/// non-fullscreen [FormDialog] (an [AlertDialog], whose content sizes to its
/// own intrinsic height) throws a semantics assertion. A plain
/// [Draggable]/[DragTarget] pair was the first replacement, but it only
/// reorders when the pointer happens to land inside another row's box, which
/// drops legitimate drags.
class DragReorderList<T> extends StatefulWidget {
  final List<T> items;
  final String Function(T item) idOf;

  /// Builds one row. [handle] is the draggable grip — place it wherever the
  /// row wants it (typically leading, beside an icon).
  final Widget Function(
    BuildContext context,
    T item,
    int index,
    Widget handle,
  )
  rowBuilder;

  /// Called with the dragged item's id and its final resting index — the
  /// shape `NotesStore.moveStage`/`moveLabel` expect.
  final void Function(String id, int newIndex) onReorder;

  /// Every row occupies this height; rows slide between multiples of it.
  final double rowHeight;

  const DragReorderList({
    super.key,
    required this.items,
    required this.idOf,
    required this.rowBuilder,
    required this.onReorder,
    this.rowHeight = 56,
  });

  @override
  State<DragReorderList<T>> createState() => _DragReorderListState<T>();
}

class _DragReorderListState<T> extends State<DragReorderList<T>> {
  /// The live order during a drag; between drags it tracks [widget.items].
  late List<String> _order;
  String? _draggingId;
  double _dragY = 0;

  List<String> get _incoming => [for (final i in widget.items) widget.idOf(i)];

  @override
  void initState() {
    super.initState();
    _order = _incoming;
  }

  @override
  void didUpdateWidget(covariant DragReorderList<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Mid-drag the local order is the source of truth; adopting the store's
    // (still un-committed) order would fight the gesture.
    if (_draggingId != null) return;
    final incoming = _incoming;
    if (!listEquals(incoming, _order)) setState(() => _order = incoming);
  }

  void _dragStart(String id) {
    setState(() {
      _draggingId = id;
      _dragY = _order.indexOf(id) * widget.rowHeight;
    });
  }

  void _dragUpdate(double dy) {
    final id = _draggingId;
    if (id == null) return;
    final maxY = (_order.length - 1) * widget.rowHeight;
    setState(() {
      _dragY = (_dragY + dy).clamp(0.0, maxY < 0 ? 0.0 : maxY);
      // Snapping on the dragged row's own top (not its centre) means the row
      // swaps once it has travelled half a slot, which is what the gap under
      // the pointer looks like it is asking for.
      final target = (_dragY / widget.rowHeight).round().clamp(
        0,
        _order.length - 1,
      );
      final from = _order.indexOf(id);
      if (from != target) {
        _order.removeAt(from);
        _order.insert(target, id);
      }
    });
  }

  void _dragEnd() {
    final id = _draggingId;
    if (id == null) return;
    final newIndex = _order.indexOf(id);
    setState(() => _draggingId = null);
    if (!listEquals(_incoming, _order)) widget.onReorder(id, newIndex);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final byId = {for (final item in widget.items) widget.idOf(item): item};

    return SizedBox(
      height: _order.length * widget.rowHeight,
      child: Stack(
        children: [
          for (final entry in _order.asMap().entries)
            if (byId[entry.value] case final T item)
              AnimatedPositioned(
                key: ValueKey(entry.value),
                // The dragged row must track the pointer exactly; the others
                // glide to their new slots.
                duration: entry.value == _draggingId
                    ? Duration.zero
                    : Motion.fast,
                curve: Motion.standard,
                left: 0,
                right: 0,
                top: entry.value == _draggingId
                    ? _dragY
                    : entry.key * widget.rowHeight,
                height: widget.rowHeight,
                // Material (rather than a DecoratedBox) so the lifted row's
                // fill sits below the row's own ink splashes instead of
                // hiding them.
                child: Material(
                  animationDuration: Motion.fast,
                  color: entry.value == _draggingId
                      ? scheme.surfaceContainerHigh
                      : Colors.transparent,
                  elevation: entry.value == _draggingId ? 3 : 0,
                  borderRadius: BorderRadius.circular(8),
                  child: widget.rowBuilder(
                    context,
                    item,
                    entry.key,
                    _handle(entry.value, scheme),
                  ),
                ),
              ),
        ],
      ),
    );
  }

  Widget _handle(String id, ColorScheme scheme) => MouseRegion(
    cursor: SystemMouseCursors.grab,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (_) => _dragStart(id),
      onVerticalDragUpdate: (details) => _dragUpdate(details.delta.dy),
      onVerticalDragEnd: (_) => _dragEnd(),
      onVerticalDragCancel: _dragEnd,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Icon(
          Icons.drag_indicator,
          size: 20,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
      ),
    ),
  );
}
