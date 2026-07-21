import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:flutter/services.dart';

import '../models/note.dart';
import '../util/platform.dart';
import 'measure_size.dart';

/// Keep-style checklist editor:
///
/// * every row is absolutely positioned and glides when anything changes, so
///   checking an item visibly slides it down into the "checked" section
///   (where it stays visible, struck through);
/// * rows have a drag handle for reordering (immediate drag, no long-press);
/// * typing in a row opens a suggestion popup anchored under the caret row,
///   fed by the user's checked-item history, with the matched prefix bolded.
class AnimatedChecklist extends StatefulWidget {
  final List<ChecklistItem> items;
  final bool readOnly;
  final bool autofocusNew;
  final String highlightQuery;
  final List<String> Function(String query, Set<String> exclude) suggestionsFor;
  final void Function(String itemId) onToggle;
  final void Function(String itemId, String text) onItemTextChanged;
  final void Function(String itemId) onRemove;

  /// Creates a new item at the end of the list and returns its id, so the
  /// add field can hand focus straight to the real row it just spawned.
  final String Function(String text) onAdd;
  final void Function(List<ChecklistItem> newItems) onReorderItems;

  /// Enter in a row inserts a fresh empty row right below it (Keep behavior);
  /// returns the new item's id so it can be focused.
  final String Function(String afterItemId)? onInsertAfter;

  const AnimatedChecklist({
    super.key,
    required this.items,
    required this.suggestionsFor,
    required this.onToggle,
    required this.onItemTextChanged,
    required this.onRemove,
    required this.onAdd,
    required this.onReorderItems,
    this.onInsertAfter,
    this.readOnly = false,
    this.autofocusNew = false,
    this.highlightQuery = '',
  });

  @override
  State<AnimatedChecklist> createState() => _AnimatedChecklistState();
}

class _RowHandles {
  final TextEditingController controller;
  final FocusNode focusNode;
  final LayerLink link = LayerLink();

  /// Suggestions only appear once the user actually types in a row, not on
  /// mere focus (except for the new-item row).
  bool typedSinceFocus = false;

  _RowHandles(String text)
    : controller = TextEditingController(text: text),
      focusNode = FocusNode();

  void dispose() {
    controller.dispose();
    focusNode.dispose();
  }
}

const _kNewRowId = '__new__';
const _kHeaderId = '__header__';

class _AnimatedChecklistState extends State<AnimatedChecklist> {
  /// Every item row (and the new-item row) is exactly this tall, so the list
  /// stays perfectly even and hover state can never move the layout.
  static const double _rowHeight = 48;
  static const double _estimatedRowHeight = _rowHeight;
  static const Duration _moveDuration = Duration(milliseconds: 230);

  final Map<String, _RowHandles> _handles = {};
  late final _RowHandles _newRow = _RowHandles('');
  final Map<String, double> _heights = {};
  final OverlayPortalController _popup = OverlayPortalController();

  List<String> _uncheckedOrder = [];
  String? _draggingId;
  String? _hoveredId;
  String? _pendingFocusId;

  /// A row just materialized by typing in the add field: it keeps its "typed"
  /// state when focus lands so its suggestion popup shows without a keystroke.
  String? _typeCreatedId;
  double _dragY = 0;
  bool _snapFrame = true;
  bool _showChecked = true;

  @override
  void initState() {
    super.initState();
    _uncheckedOrder = _uncheckedIdsFromItems();
    _newRow.focusNode.addListener(_onAnyFocusChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _popup.show();
    });
  }

  @override
  void dispose() {
    for (final h in _handles.values) {
      h.dispose();
    }
    _newRow.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(AnimatedChecklist oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_draggingId == null) {
      _uncheckedOrder = _uncheckedIdsFromItems();
    } else {
      final unchecked = _uncheckedIdsFromItems().toSet();
      _uncheckedOrder = [
        for (final id in _uncheckedOrder)
          if (unchecked.contains(id)) id,
        for (final id in unchecked)
          if (!_uncheckedOrder.contains(id)) id,
      ];
    }
    final ids = {for (final item in widget.items) item.id};
    final stale = _handles.keys.where((id) => !ids.contains(id)).toList();
    for (final id in stale) {
      _handles.remove(id)?.dispose();
    }
    _heights.removeWhere(
      (id, _) => !ids.contains(id) && id != _kNewRowId && id != _kHeaderId,
    );
  }

  List<String> _uncheckedIdsFromItems() => [
    for (final item in widget.items)
      if (!item.done) item.id,
  ];

  List<ChecklistItem> get _checkedItems => [
    for (final item in widget.items)
      if (item.done) item,
  ];

  ChecklistItem? _itemById(String id) {
    for (final item in widget.items) {
      if (item.id == id) return item;
    }
    return null;
  }

  void _onAnyFocusChange() {
    if (!mounted) return;
    setState(() {});
  }

  _RowHandles _handleFor(ChecklistItem item) {
    final handles = _handles.putIfAbsent(item.id, () {
      final h = _RowHandles(item.text);
      h.focusNode.addListener(() {
        if (h.focusNode.hasFocus) {
          h.typedSinceFocus = item.id == _typeCreatedId;
          if (item.id == _typeCreatedId) _typeCreatedId = null;
        }
        _onAnyFocusChange();
      });
      return h;
    });
    // Backspace on an already-empty row deletes it and moves the caret up.
    handles.focusNode.onKeyEvent = (node, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.backspace &&
          handles.controller.text.isEmpty &&
          !widget.readOnly) {
        _focusNeighborThenRemove(item.id);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    // Reflect external (collaborator/undo) edits without fighting the caret.
    if (!handles.focusNode.hasFocus && handles.controller.text != item.text) {
      handles.controller.text = item.text;
    }
    return handles;
  }

  void _focusNeighborThenRemove(String itemId) {
    final index = _uncheckedOrder.indexOf(itemId);
    _pendingFocusId = index > 0 ? _uncheckedOrder[index - 1] : _kNewRowId;
    widget.onRemove(itemId);
    setState(() {});
  }

  void _applyPendingFocus() {
    final id = _pendingFocusId;
    if (id == null) return;
    final handles = id == _kNewRowId ? _newRow : _handles[id];
    if (handles != null) {
      _pendingFocusId = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        handles.focusNode.requestFocus();
        // Land the caret at the end so continuing to type appends.
        final len = handles.controller.text.length;
        handles.controller.selection = TextSelection.collapsed(offset: len);
      });
    } else {
      // The row's handles are created later in this build pass; retry.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  double _h(String id) => _heights[id] ?? _estimatedRowHeight;

  void _measured(String id, double height) {
    if (!mounted || (_heights[id] ?? -1) == height) return;
    setState(() => _heights[id] = height);
  }

  // -------------------------------------------------------------------
  // Layout

  ({Map<String, double> tops, double total}) _layout() {
    final tops = <String, double>{};
    var y = 0.0;
    for (final id in _uncheckedOrder) {
      tops[id] = y;
      y += _h(id);
    }
    if (!widget.readOnly) {
      tops[_kNewRowId] = y;
      y += _h(_kNewRowId);
    }
    final checked = _checkedItems;
    if (checked.isNotEmpty) {
      tops[_kHeaderId] = y;
      y += _h(_kHeaderId);
      if (_showChecked) {
        for (final item in checked) {
          tops[item.id] = y;
          y += _h(item.id);
        }
      }
    }
    return (tops: tops, total: y);
  }

  // -------------------------------------------------------------------
  // Drag to reorder (handle-initiated, unchecked rows only)

  void _dragStart(String id, double startTop) {
    setState(() {
      _draggingId = id;
      _dragY = startTop;
    });
  }

  void _dragUpdate(double dy) {
    final draggingId = _draggingId;
    if (draggingId == null) return;
    final maxY =
        _uncheckedOrder.fold<double>(0, (acc, id) => acc + _h(id)) -
        _h(draggingId);
    _dragY = (_dragY + dy).clamp(0.0, maxY < 0 ? 0.0 : maxY);

    // Find the insertion index for the dragged row's center.
    final center = _dragY + _h(draggingId) / 2;
    var acc = 0.0;
    var index = 0;
    for (final id in _uncheckedOrder) {
      if (id == draggingId) continue;
      if (center > acc + _h(id) / 2) {
        index++;
        acc += _h(id);
      } else {
        break;
      }
    }
    final from = _uncheckedOrder.indexOf(draggingId);
    setState(() {
      if (from != index) {
        _uncheckedOrder.removeAt(from);
        _uncheckedOrder.insert(index, draggingId);
      }
    });
  }

  void _dragEnd() {
    if (_draggingId == null) return;
    setState(() => _draggingId = null);
    final reordered = [
      for (final id in _uncheckedOrder)
        if (_itemById(id) case final ChecklistItem item) item,
      ..._checkedItems,
    ];
    final current = [for (final item in widget.items) item.id];
    final proposed = [for (final item in reordered) item.id];
    if (current.join('|') != proposed.join('|')) {
      widget.onReorderItems(reordered);
    }
  }

  // -------------------------------------------------------------------
  // Suggestions popup

  ({String rowId, LayerLink link, List<String> suggestions})? _popupTarget() {
    if (widget.readOnly) return null;
    // Only items still *active* (unchecked) block a suggestion. A checked-off
    // item is done, so offering it back is exactly what you want — re-adding
    // last week's groceries is the whole point of the history.
    final activeTexts = {
      for (final item in widget.items)
        if (!item.done && item.text.trim().isNotEmpty) item.text,
    };
    if (_newRow.focusNode.hasFocus) {
      final suggestions = widget.suggestionsFor(
        _newRow.controller.text,
        activeTexts,
      );
      if (suggestions.isEmpty) return null;
      return (rowId: _kNewRowId, link: _newRow.link, suggestions: suggestions);
    }
    for (final entry in _handles.entries) {
      final h = entry.value;
      if (h.focusNode.hasFocus &&
          h.typedSinceFocus &&
          h.controller.text.trim().isNotEmpty) {
        final exclude = {...activeTexts}..remove(_itemById(entry.key)?.text);
        final suggestions = widget.suggestionsFor(h.controller.text, exclude);
        if (suggestions.isEmpty) return null;
        return (rowId: entry.key, link: h.link, suggestions: suggestions);
      }
    }
    return null;
  }

  void _applySuggestion(String rowId, String text) {
    // If a checked item with this exact text already exists, uncheck it
    // instead of creating a duplicate.
    final existingChecked = widget.items
        .where((item) => item.done && item.text == text)
        .toList();
    if (existingChecked.isNotEmpty) {
      widget.onToggle(existingChecked.first.id);
      if (rowId == _kNewRowId) {
        _newRow.controller.clear();
        _newRow.focusNode.requestFocus();
      } else {
        // If the user was typing in an existing row and picked a suggestion
        // that matches a checked item, restore the row's original text.
        final original = _itemById(rowId)?.text ?? '';
        final handles = _handles[rowId];
        if (handles != null) {
          handles.controller.text = original;
          handles.controller.selection = TextSelection.collapsed(
            offset: original.length,
          );
          handles.typedSinceFocus = false;
        }
      }
      setState(() {});
      return;
    }

    if (rowId == _kNewRowId) {
      widget.onAdd(text);
      _newRow.controller.clear();
      _newRow.focusNode.requestFocus();
    } else {
      final handles = _handles[rowId];
      if (handles != null) {
        handles.controller.text = text;
        handles.controller.selection = TextSelection.collapsed(
          offset: text.length,
        );
        handles.typedSinceFocus = false;
      }
      widget.onItemTextChanged(rowId, text);
    }
    setState(() {});
  }

  Widget _buildPopup(BuildContext context) {
    final target = _popupTarget();
    if (target == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final query = target.rowId == _kNewRowId
        ? _newRow.controller.text.trim()
        : (_handles[target.rowId]?.controller.text.trim() ?? '');

    return CompositedTransformFollower(
      link: target.link,
      targetAnchor: Alignment.bottomLeft,
      followerAnchor: Alignment.topLeft,
      offset: const Offset(56, 0),
      showWhenUnlinked: false,
      child: Align(
        alignment: Alignment.topLeft,
        child: TextFieldTapRegion(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300, maxHeight: 288),
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(kRadius),
              color: scheme.surfaceContainerHigh,
              clipBehavior: Clip.antiAlias,
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [
                  for (final suggestion in target.suggestions)
                    InkWell(
                      onTap: () => _applySuggestion(target.rowId, suggestion),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 9,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.history,
                              size: 17,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _boldMatch(context, suggestion, query),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// "Chi" typed over "Chili peppers" renders **Chi**li peppers.
  Widget _boldMatch(BuildContext context, String text, String query) {
    final style = Theme.of(context).textTheme.bodyMedium;
    final q = query.toLowerCase();
    final index = q.isEmpty ? -1 : text.toLowerCase().indexOf(q);
    if (index < 0) {
      return Text(
        text,
        style: style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: text.substring(0, index)),
          TextSpan(
            text: text.substring(index, index + q.length),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          TextSpan(text: text.substring(index + q.length)),
        ],
      ),
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  // -------------------------------------------------------------------
  // Rows

  Widget _itemRow(ChecklistItem item, {required bool dragging}) {
    final handles = _handleFor(item);
    final scheme = Theme.of(context).colorScheme;
    final query = widget.highlightQuery.trim().toLowerCase();
    final matches = query.isNotEmpty && item.text.toLowerCase().contains(query);
    final focused = handles.focusNode.hasFocus;
    final hovered = _hoveredId == item.id;
    // Touch has no hover: keep affordances visible. Desktop reveals them on
    // hover/focus, keeping the list visually calm like Keep.
    final showControls =
        !widget.readOnly &&
        (isTouchPrimaryPlatform || hovered || focused || dragging);

    final row = MouseRegion(
      onEnter: (_) => setState(() => _hoveredId = item.id),
      onExit: (_) => setState(() {
        if (_hoveredId == item.id) _hoveredId = null;
      }),
      child: Container(
        decoration: BoxDecoration(
          color: dragging
              ? scheme.surfaceContainerHigh
              : matches
              ? scheme.tertiaryContainer.withValues(alpha: 0.55)
              : hovered && !widget.readOnly
              ? scheme.onSurface.withValues(alpha: 0.04)
              : null,
          borderRadius: BorderRadius.circular(kRadius),
          boxShadow: [
            if (dragging)
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
          ],
        ),
        // Every row keeps the exact same height and widget shape whether
        // hovered or not: controls fade in with Opacity instead of being
        // added to the tree, so hovering never shifts the layout.
        child: SizedBox(
          height: _rowHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Opacity(
                opacity: !item.done && showControls ? 1 : 0,
                child: IgnorePointer(
                  ignoring: item.done || widget.readOnly,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragStart: (_) {
                        final layout = _layout();
                        _dragStart(item.id, layout.tops[item.id] ?? 0);
                      },
                      onVerticalDragUpdate: (details) =>
                          _dragUpdate(details.delta.dy),
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
                  ),
                ),
              ),
              _PopCheckbox(
                value: item.done,
                onChanged: widget.readOnly
                    ? null
                    : (_) => widget.onToggle(item.id),
                sideColor: scheme.onSurfaceVariant,
              ),
              Expanded(
                child: CompositedTransformTarget(
                  link: handles.link,
                  child: TextField(
                    controller: handles.controller,
                    focusNode: handles.focusNode,
                    readOnly: widget.readOnly,
                    enabled: !widget.readOnly,
                    maxLines: 1,
                    textInputAction: TextInputAction.next,
                    style: TextStyle(
                      decoration: item.done ? TextDecoration.lineThrough : null,
                      color: item.done ? scheme.onSurfaceVariant : null,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onChanged: (text) {
                      handles.typedSinceFocus = true;
                      widget.onItemTextChanged(item.id, text);
                      setState(() {});
                    },
                    onSubmitted: (_) {
                      // Enter continues the list: new row right below this
                      // one.
                      if (widget.onInsertAfter != null && !item.done) {
                        _pendingFocusId = widget.onInsertAfter!(item.id);
                        setState(() {});
                      } else {
                        _newRow.focusNode.requestFocus();
                      }
                    },
                  ),
                ),
              ),
              Opacity(
                opacity: showControls ? 1 : 0,
                child: IgnorePointer(
                  ignoring: !showControls,
                  child: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: scheme.onSurfaceVariant,
                    tooltip: 'Remove item',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 40,
                      height: 40,
                    ),
                    onPressed: () => widget.onRemove(item.id),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return RepaintBoundary(child: row);
  }

  Widget _newItemRow() {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: _rowHeight,
      child: Row(
        children: [
          const SizedBox(width: 24),
          // Aligned with the checkbox column above.
          SizedBox(
            width: 40,
            child: Icon(Icons.add, size: 20, color: scheme.onSurfaceVariant),
          ),
          Expanded(
            child: CompositedTransformTarget(
              link: _newRow.link,
              child: TextField(
                controller: _newRow.controller,
                focusNode: _newRow.focusNode,
                autofocus: widget.autofocusNew,
                decoration: const InputDecoration(
                  hintText: 'List item',
                  border: InputBorder.none,
                  isDense: true,
                ),
                onChanged: (text) {
                  if (text.trim().isEmpty) {
                    setState(() {});
                    return;
                  }
                  // The first keystroke turns the add field into a real item,
                  // so typing always lands on an actual element (nothing is
                  // lost if focus leaves) and it shows on the grid instantly.
                  // Focus hands off to that row to continue the word there.
                  final newId = widget.onAdd(text);
                  _newRow.controller.clear();
                  _typeCreatedId = newId;
                  _pendingFocusId = newId;
                  setState(() {});
                },
                onSubmitted: (text) {
                  if (text.trim().isEmpty) return;
                  final newId = widget.onAdd(text);
                  _newRow.controller.clear();
                  _pendingFocusId = newId;
                  setState(() {});
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _checkedHeader(int count) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => setState(() => _showChecked = !_showChecked),
      borderRadius: BorderRadius.circular(kRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            const SizedBox(width: 4),
            AnimatedRotation(
              turns: _showChecked ? 0.25 : 0,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: Icon(
                Icons.chevron_right,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$count checked ${count == 1 ? 'item' : 'items'}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _applyPendingFocus();
    final layout = _layout();
    final snap = _snapFrame;
    if (snap) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _snapFrame = false);
      });
    }
    final checked = _checkedItems;

    Widget positioned(String id, Widget child) {
      final dragging = id == _draggingId;
      final top = dragging ? _dragY : (layout.tops[id] ?? 0);
      // One widget shape for dragged and resting rows: swapping widget types
      // mid-gesture would rebuild the row's element tree and cancel the very
      // drag recognizer driving it. The dragged row just animates with
      // Duration.zero so it tracks the pointer exactly.
      return AnimatedPositioned(
        key: ValueKey(id),
        duration: snap || dragging ? Duration.zero : _moveDuration,
        curve: Curves.easeOutCubic,
        left: 0,
        right: 0,
        top: top,
        child: MeasureSize(
          onChange: (size) => _measured(id, size.height),
          child: child,
        ),
      );
    }

    return OverlayPortal(
      controller: _popup,
      overlayChildBuilder: _buildPopup,
      child: SizedBox(
        height: layout.total,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (final id in _uncheckedOrder)
              if (_itemById(id) case final ChecklistItem item)
                positioned(id, _itemRow(item, dragging: id == _draggingId)),
            if (!widget.readOnly) positioned(_kNewRowId, _newItemRow()),
            if (checked.isNotEmpty)
              positioned(_kHeaderId, _checkedHeader(checked.length)),
            if (checked.isNotEmpty && _showChecked)
              for (final item in checked)
                positioned(item.id, _itemRow(item, dragging: false)),
          ],
        ),
      ),
    );
  }
}

/// A Material [Checkbox] that gives a springy scale "pop" every time it's
/// tapped — on top of Checkbox's own tick-draw and ripple. The pop is fired
/// from the tap handler itself (not from a value diff), so it plays reliably
/// even as the checked row immediately slides down to the completed section.
class _PopCheckbox extends StatefulWidget {
  final bool value;
  final ValueChanged<bool?>? onChanged;
  final Color sideColor;

  const _PopCheckbox({
    required this.value,
    required this.onChanged,
    required this.sideColor,
  });

  @override
  State<_PopCheckbox> createState() => _PopCheckboxState();
}

class _PopCheckboxState extends State<_PopCheckbox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );
  // Quickly balloons to 1.6x then bounces back with an elastic settle, so the
  // tap reads clearly even while the ticked row is sliding to "Completed".
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 1.0,
        end: 1.6,
      ).chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 30,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.6,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.elasticOut)),
      weight: 70,
    ),
  ]).animate(_controller);

  final math.Random _rng = math.Random();
  List<_Particle> _particles = const [];

  void _handleChanged(bool? value) {
    // A tiny celebration burst — only when ticking something OFF the list,
    // not when unchecking it back.
    _particles = value == true ? _spawnParticles() : const [];
    _controller.forward(from: 0);
    widget.onChanged?.call(value);
  }

  List<_Particle> _spawnParticles() {
    final scheme = Theme.of(context).colorScheme;
    const count = 10;
    return [
      for (var i = 0; i < count; i++)
        _Particle(
          // Evenly fanned around the box, with a little jitter so no two
          // bursts look identical.
          angle: (i / count) * 2 * math.pi + _rng.nextDouble() * 0.6,
          distance: 14 + _rng.nextDouble() * 10,
          size: 1.5 + _rng.nextDouble() * 1.5,
          color: i.isEven ? scheme.primary : scheme.tertiary,
        ),
    ];
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        // Painted first so the dots eject from *behind* the checkbox.
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _ParticlePainter(
                progress: _controller,
                particles: _particles,
              ),
            ),
          ),
        ),
        ScaleTransition(
          scale: _scale,
          child: Checkbox(
            value: widget.value,
            onChanged: widget.onChanged == null ? null : _handleChanged,
            visualDensity: VisualDensity.compact,
            side: BorderSide(color: widget.sideColor, width: 1.5),
          ),
        ),
      ],
    );
  }
}

/// One confetti dot of the check celebration: a fixed direction/reach/size
/// rolled at spawn; its position and fade are derived from the shared
/// animation progress at paint time.
class _Particle {
  final double angle;
  final double distance;
  final double size;
  final Color color;

  const _Particle({
    required this.angle,
    required this.distance,
    required this.size,
    required this.color,
  });
}

class _ParticlePainter extends CustomPainter {
  final Animation<double> progress;
  final List<_Particle> particles;

  _ParticlePainter({required this.progress, required this.particles})
    : super(repaint: progress);

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    if (particles.isEmpty || t <= 0 || t >= 1) return;
    final center = size.center(Offset.zero);
    // Dots race out fast then coast; they fade through the back half so the
    // whole thing is over in a blink.
    final travel = Curves.easeOutCubic.transform(t);
    final fade = 1 - Curves.easeIn.transform(t);
    for (final p in particles) {
      final pos =
          center +
          Offset(math.cos(p.angle), math.sin(p.angle)) * (p.distance * travel);
      final paint = Paint()..color = p.color.withValues(alpha: fade);
      canvas.drawCircle(pos, p.size * (1 - 0.4 * t), paint);
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) =>
      old.particles != particles || old.progress != progress;
}
