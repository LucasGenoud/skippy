part of 'animated_checklist.dart';

/// The suggestions popup that offers earlier items while a row is typed.
extension _ChecklistSuggestionPopup on _AnimatedChecklistState {
  /// Items already on the list, which a suggestion would only duplicate.
  /// Only items still *active* (unchecked) count: a checked-off item is done,
  /// so offering it back is exactly what you want, re-adding last week's
  /// groceries is the whole point of the history.
  Set<String> _activeTexts({String? except}) => {
    for (final item in widget.items)
      if (!item.done && item.id != except && item.text.trim().isNotEmpty)
        item.text,
  };

  ({String rowId, LayerLink link, List<String> suggestions})? _popupTarget() {
    if (widget.readOnly) return null;
    if (_composer.focusNode.hasFocus) {
      final suggestions = widget.suggestionsFor(
        _composer.text,
        _activeTexts(except: _composingId),
      );
      if (suggestions.isEmpty) return null;
      return (
        rowId: _kComposerId,
        link: _composer.link,
        suggestions: suggestions,
      );
    }
    for (final entry in _handles.entries) {
      final handles = entry.value;
      if (handles.focusNode.hasFocus &&
          handles.typedSinceFocus &&
          handles.text.trim().isNotEmpty) {
        final suggestions = widget.suggestionsFor(
          handles.text,
          _activeTexts(except: entry.key),
        );
        if (suggestions.isEmpty) return null;
        return (rowId: entry.key, link: handles.link, suggestions: suggestions);
      }
    }
    return null;
  }

  void _applySuggestion(String rowId, String text) {
    // Picking something the list already has checked off unchecks it, rather
    // than adding a second copy of it.
    final checkedTwin = widget.items
        .where((item) => item.done && item.text == text)
        .firstOrNull;
    if (rowId == _kComposerId) {
      final composingId = _composingId;
      if (checkedTwin != null) {
        // Re-adding an item is writing it again, so it comes back to where it
        // is being written, the composer's own place at the end of the list,
        // rather than to wherever on a long list it was ticked off. The
        // half-written row it replaces goes in the same push, so the list
        // rearranges once.
        _releaseComposer();
        final without = composingId == null
            ? widget.items
            : removeItem(widget.items, composingId);
        widget.onReorderItems(reopenWhereWritten(without, checkedTwin.id));
      } else if (composingId != null) {
        _composer.controller.text = text;
        _composer.unacknowledged = text;
        widget.onItemTextChanged(composingId, text);
        _commitComposing();
      } else {
        widget.onAdd(text);
      }
      _composer.focusNode.requestFocus();
      _rebuild(() {});
      return;
    }
    final handles = _handles[rowId];
    if (checkedTwin != null) {
      // Written in this row, so it comes back directly under it, subtasks and
      // all, instead of returning to the place it was checked off in.
      widget.onReorderItems(
        reopenWhereWritten(widget.items, checkedTwin.id, after: rowId),
      );
      // The row the user was typing in keeps what it had before.
      final original = _byId[rowId]?.text ?? '';
      if (handles != null) {
        handles.controller.text = original;
        handles.controller.selection = TextSelection.collapsed(
          offset: original.length,
        );
        handles.typedSinceFocus = false;
        handles.unacknowledged = null;
        // Restoring an empty row leaves it empty: keep backspace working.
        _armEmptyMarker(handles);
      }
      _rebuild(() {});
      return;
    }
    if (handles != null) {
      handles.controller.text = text;
      handles.controller.selection = TextSelection.collapsed(
        offset: text.length,
      );
      handles.typedSinceFocus = false;
      handles.unacknowledged = text;
    }
    widget.onItemTextChanged(rowId, text);
    _rebuild(() {});
  }

  Widget _buildPopup(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: _popupRevision,
    builder: (context, _, _) {
      final target = _popupTarget();
      if (target == null) return const SizedBox.shrink();
      return ChecklistSuggestions(
        link: target.link,
        suggestions: target.suggestions,
        query: target.rowId == _kComposerId
            ? _composer.text.trim()
            : (_handles[target.rowId]?.text.trim() ?? ''),
        scrollController: _suggestionsScroll,
        onPick: (suggestion) => _applySuggestion(target.rowId, suggestion),
      );
    },
  );
}
