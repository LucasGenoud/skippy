import 'package:flutter/foundation.dart';

import '../models/note.dart';

/// One undo/redo step: the note's editable content at a point in time.
class EditorSnapshot {
  final NoteKind kind;
  final String title;
  final String content;
  final List<ChecklistItem> items;

  const EditorSnapshot({
    required this.kind,
    required this.title,
    required this.content,
    required this.items,
  });

  bool sameAs(EditorSnapshot other) =>
      kind == other.kind &&
      title == other.title &&
      content == other.content &&
      listEquals(items, other.items);
}

/// The editor's session-local undo/redo history.
///
/// Typing groups into bursts (edits close together in time collapse into one
/// step); discrete ops (check, add, remove, reorder, convert) always start a
/// new step. The stack is capped so a long session can't grow unbounded.
class EditorHistory {
  static const _burstGap = Duration(milliseconds: 800);
  static const _maxSteps = 100;

  final List<EditorSnapshot> _undoStack = [];
  final List<EditorSnapshot> _redoStack = [];

  /// The last recorded state; new edits are diffed against it.
  EditorSnapshot _mirror;
  DateTime _lastEdit = DateTime.fromMillisecondsSinceEpoch(0);

  EditorHistory(EditorSnapshot initial) : _mirror = initial;

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  /// Record history after a mutation. No-op when nothing changed since the
  /// last recorded state.
  void record(EditorSnapshot current, {bool discrete = false}) {
    if (current.sameAs(_mirror)) return;
    final now = DateTime.now();
    if (discrete || now.difference(_lastEdit) > _burstGap) {
      _undoStack.add(_mirror);
      if (_undoStack.length > _maxSteps) _undoStack.removeAt(0);
      _redoStack.clear();
    }
    _lastEdit = now;
    _mirror = current;
  }

  /// Pop the previous state, saving [current] for redo. Null when there is
  /// nothing to undo.
  EditorSnapshot? undo(EditorSnapshot current) {
    if (_undoStack.isEmpty) return null;
    _redoStack.add(current);
    return _undoStack.removeLast();
  }

  /// Pop the next state, saving [current] for undo. Null when there is
  /// nothing to redo.
  EditorSnapshot? redo(EditorSnapshot current) {
    if (_redoStack.isEmpty) return null;
    _undoStack.add(current);
    return _redoStack.removeLast();
  }

  /// Re-baseline after a snapshot is applied: the next edit starts a fresh
  /// burst instead of merging into the restored step.
  void resetTo(EditorSnapshot snapshot) {
    _mirror = snapshot;
    _lastEdit = DateTime.fromMillisecondsSinceEpoch(0);
  }
}
