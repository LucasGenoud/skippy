part of 'editor_screen.dart';

/// Checklist editing: rows are added, nested, checked, removed and given
/// reminders here, each change going through [_setItems].
extension _EditorChecklist on _EditorScreenState {
  List<ChecklistItem> get _items => _note?.items ?? const [];

  void _setItems(List<ChecklistItem> items, {bool discrete = true}) {
    _ensureNote();
    // Discrete ops (check, add, remove, reorder) show on the grid instantly;
    // row typing rides the same keystroke throttle as the text fields.
    _store.updateNoteContent(_noteId!, items: items, urgent: discrete);
    _afterChange(discrete: discrete);
    // Row typing doesn't rebuild the editor: the row's own controller already
    // shows the character, and rebuilding here means rebuilding every other
    // row (each a TextField) plus the attachments and bottom bar on every
    // keystroke, the thing that makes a long checklist feel laggy. The
    // store's throttled notify refreshes us within 200ms instead.
    if (discrete) _rebuild(() {});
  }

  String _addItem(String text) {
    // A new row at the end continues the list where it left off: writing
    // under a subtask keeps writing subtasks, rather than jumping back out to
    // the top level after every line.
    final item = ChecklistItem(
      id: _EditorScreenState._uuid.v4(),
      text: text.trim(),
      depth: _items.isEmpty ? 0 : _items.last.depth,
    );
    _setItems([..._items, item]);
    return item.id;
  }

  /// Nest a row, or bring it back out, with whatever is under it.
  void _indentItem(String itemId, int delta) =>
      _setItems(shiftDepth(_items, itemId, delta));

  void _updateItemText(String itemId, String text) {
    _setItems([
      for (final item in _items)
        item.id == itemId ? item.copyWith(text: text) : item,
    ], discrete: false);
  }

  void _toggleItem(String itemId) {
    _ensureNote();
    _store.toggleChecklistItem(_noteId!, itemId);
    _afterChange(discrete: true);
    _rebuild(() {});
  }

  void _removeItem(String itemId) {
    // Subtasks are promoted rather than deleted: the remove button is one tap
    // with nothing behind it, and taking a whole subtree with it would be a
    // bad surprise.
    _setItems(removeItem(_items, itemId));
  }

  void _clearCheckedItems() => _setItems(
    normalizeDepths([
      for (final item in _items)
        if (!item.done) item,
    ]),
  );

  /// Set, change, or remove the reminder on one checklist row.
  ///
  /// Deliberately time-only: the location branch is keyed per note in the
  /// settings document and capped by the platform's geofence budget, so it
  /// stays a note-level idea.
  Future<void> _editItemReminder(String itemId) async {
    if (_reminderPickerOpen) return;
    _reminderPickerOpen = true;
    try {
      // A row can only exist once the note does, so there is nothing to
      // materialize here the way the note-level reminder has to.
      final noteId = _noteId;
      if (noteId == null) return;
      await editItemReminder(context, noteId: noteId, itemId: itemId);
    } finally {
      _reminderPickerOpen = false;
    }
  }

  /// Enter in a row: continue the list with an empty row right below it.
  String _insertItemAfter(String afterId) {
    final items = [..._items];
    final index = items.indexWhere((i) => i.id == afterId);
    // Enter continues at the same level: the new row is a sibling of the one
    // it came from, not a subtask of it.
    final item = ChecklistItem(
      id: _EditorScreenState._uuid.v4(),
      text: '',
      depth: index < 0 ? 0 : items[index].depth,
    );
    items.insert(index < 0 ? items.length : index + 1, item);
    _setItems(items);
    return item.id;
  }
}
