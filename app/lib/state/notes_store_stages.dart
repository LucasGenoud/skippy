part of 'notes_store.dart';

/// A collection's board columns, and moving cards between them.
extension NotesStoreStages on NotesStore {
  // Deliberately parallel to labels rather than sharing code with them: the
  // two are independent systems, and keeping them as two obvious blocks costs
  // less than one abstraction both have to be read through.

  Stage createStage(String name, {String? color}) {
    final workspaceId = _activeWorkspaceId ?? '';
    final stage = Stage(
      id: NotesStore._uuid.v4(),
      workspaceId: workspaceId,
      collectionId: activeCollection?.id,
      name: name.trim(),
      color: color,
      position: _nextStagePosition(workspaceId),
    );
    _stages = [..._stages, stage]
      ..sort((a, b) => a.position.compareTo(b.position));
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.stageCreate,
        id: stage.id,
        data: {
          'name': stage.name,
          'workspaceId': workspaceId,
          'collectionId': activeCollection?.id,
          'color': color,
          'position': stage.position,
        },
      ),
    );
    return stage;
  }

  /// A new column goes to the right of the board, matching the server.
  double _nextStagePosition(String workspaceId) {
    var max = 0.0;
    for (final stage in _stages) {
      if (stage.workspaceId == workspaceId && stage.position > max) {
        max = stage.position;
      }
    }
    return max + kPositionGap;
  }

  /// Rename and/or recolour a column. Passing null for [color] clears it, the
  /// same "set, not merge" rule [updateLabel] uses. [position] moves the
  /// column; omitting it leaves the board's order alone.
  void updateStage(String id, {String? name, String? color, double? position}) {
    final i = _stages.indexWhere((s) => s.id == id);
    if (i == -1) return;
    final newName = (name ?? _stages[i].name).trim();
    _stages[i] = Stage(
      id: id,
      workspaceId: _stages[i].workspaceId,
      collectionId: _stages[i].collectionId,
      name: newName,
      color: color,
      position: position ?? _stages[i].position,
    );
    _stages.sort((a, b) => a.position.compareTo(b.position));
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.stageUpdate,
        id: id,
        data: {'name': newName, 'color': color, 'position': position},
      ),
    );
  }

  /// Drag-reorder a column. [newIndex] is the final resting index (the slot
  /// the item lands in, counted *after* its own removal), the convention
  /// `ReorderableListView.onReorderItem` reports, so that callback can call
  /// this directly. Recomputes a sparse position between the new neighbours
  /// rather than renumbering the board (see [positionAt]).
  void moveStage(String id, int newIndex) {
    final ordered = stages;
    final stage = ordered.where((s) => s.id == id).firstOrNull;
    if (stage == null) return;
    final others = [
      for (final s in ordered)
        if (s.id != id) s.position,
    ];
    updateStage(
      id,
      name: stage.name,
      color: stage.color,
      position: positionAt(others, newIndex, current: stage.position),
    );
  }

  /// Delete a column. Its notes are not destroyed, they go back to unassigned,
  /// locally and on the server.
  void deleteStage(String id) {
    _stages.removeWhere((s) => s.id == id);
    for (var i = 0; i < _notes.length; i++) {
      if (_notes[i].stageId == id) {
        _notes[i] = _notes[i].copyWith(stageId: null);
      }
    }
    notifyListeners();
    _enqueue(PendingOp(PendingOpKind.stageDelete, id: id));
  }

  /// Move a note to [stageId] (null for unassigned). Without a [position] the
  /// card goes to the end of that column, which is what the column picker
  /// wants; a drop passes the slot it landed in (see [positionBetween]).
  ///
  /// One patch carries both fields, so a move is a single queued write rather
  /// than a stage change chased by a reorder. That also makes reordering
  /// *within* a column the same operation as moving between two: it is a move
  /// to the stage the card is already in. Labels are untouched, a card
  /// changing column says nothing about its taxonomy.
  void setNoteStage(String noteId, String? stageId, {double? position}) {
    final note = noteById(noteId);
    if (note == null) return;
    // A no-op reposition still has to be filtered out, or every drop that
    // lands where the card already was would queue a write.
    if (note.stageId == stageId && position == null) return;
    final target = position ?? _endOfStage(stageId, note.workspaceId);
    if (note.stageId == stageId && note.stagePosition == target) return;
    _patch(noteId, note.copyWith(stageId: stageId, stagePosition: target), {
      'stage_id': stageId,
      'stage_position': target,
    });
  }

  /// One slot past the last card of [stageId] in [workspaceId].
  double _endOfStage(String? stageId, String workspaceId) {
    var max = 0.0;
    for (final note in _notes) {
      if (note.workspaceId != workspaceId || note.stageId != stageId) continue;
      if (note.stagePosition > max) max = note.stagePosition;
    }
    return max + kPositionGap;
  }
}
