import 'package:flutter/material.dart';

import '../util/motion.dart';
import '../util/platform.dart';

/// A short, non-scrolling list of rows that can be reordered by dragging a
/// handle. Hand-rolled with [Draggable]/[DragTarget] rather than
/// [ReorderableListView] on purpose: nesting that widget inside a
/// non-fullscreen [FormDialog] (an [AlertDialog], whose content sizes to its
/// own intrinsic height rather than a fixed viewport) throws a semantics
/// assertion (`!semantics.parentDataDirty`) — a known fragility of mixing a
/// reorderable sliver with another Scrollable/Overlay in that context. This
/// mirrors the drag-and-drop the sidebar already uses (see `app_drawer.dart`)
/// instead of introducing a second drag mechanism.
class DragReorderList<T> extends StatelessWidget {
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

  /// Called with the dragged item's id and its landing index, already
  /// adjusted for its own removal — the same convention
  /// `ReorderableListView.onReorderItem` uses, so it can be handed straight
  /// to a `NotesStore.moveStage`/`moveLabel`-shaped method.
  final void Function(String id, int newIndex) onReorder;

  const DragReorderList({
    super.key,
    required this.items,
    required this.idOf,
    required this.rowBuilder,
    required this.onReorder,
  });

  void _handleDrop(String draggedId, int targetIndex) {
    final currentIndex = items.indexWhere((item) => idOf(item) == draggedId);
    if (currentIndex == -1 || currentIndex == targetIndex) return;
    final adjusted = targetIndex > currentIndex ? targetIndex - 1 : targetIndex;
    onReorder(draggedId, adjusted);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final entry in items.asMap().entries)
          _DragReorderRow<T>(
            key: ValueKey(idOf(entry.value)),
            item: entry.value,
            index: entry.key,
            id: idOf(entry.value),
            rowBuilder: rowBuilder,
            onDrop: _handleDrop,
          ),
      ],
    );
  }
}

class _DragReorderRow<T> extends StatefulWidget {
  final T item;
  final int index;
  final String id;
  final Widget Function(BuildContext, T, int, Widget) rowBuilder;
  final void Function(String draggedId, int targetIndex) onDrop;

  const _DragReorderRow({
    super.key,
    required this.item,
    required this.index,
    required this.id,
    required this.rowBuilder,
    required this.onDrop,
  });

  @override
  State<_DragReorderRow<T>> createState() => _DragReorderRowState<T>();
}

class _DragReorderRowState<T> extends State<_DragReorderRow<T>> {
  bool _isTarget = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final handle = Icon(Icons.drag_indicator, color: scheme.onSurfaceVariant);
    final ghostHandle = Opacity(opacity: 0.3, child: handle);
    final draggableHandle = isTouchPrimaryPlatform
        ? LongPressDraggable<String>(
            data: widget.id,
            delay: const Duration(milliseconds: 220),
            feedback: _feedback(context),
            childWhenDragging: ghostHandle,
            child: handle,
          )
        : Draggable<String>(
            data: widget.id,
            feedback: _feedback(context),
            childWhenDragging: ghostHandle,
            child: handle,
          );

    final row = widget.rowBuilder(context, widget.item, widget.index, draggableHandle);

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != widget.id,
      onAcceptWithDetails: (details) =>
          widget.onDrop(details.data, widget.index),
      onMove: (_) {
        if (!_isTarget) setState(() => _isTarget = true);
      },
      onLeave: (_) => setState(() => _isTarget = false),
      builder: (context, candidates, rejected) => AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.standard,
        decoration: BoxDecoration(
          color: _isTarget
              ? scheme.primaryContainer.withValues(alpha: 0.35)
              : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: row,
      ),
    );
  }

  Widget _feedback(BuildContext context) => Material(
    elevation: 4,
    borderRadius: BorderRadius.circular(8),
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: widget.rowBuilder(
        context,
        widget.item,
        widget.index,
        const SizedBox(width: 24),
      ),
    ),
  );
}
