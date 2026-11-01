part of 'notes_store.dart';

/// A workspace's labels: the shared taxonomy every member sees and applies.
extension NotesStoreLabels on NotesStore {
  Label createLabel(String name, {String? color, String? icon}) {
    final workspaceId = _activeWorkspaceId ?? '';
    final label = Label(
      id: NotesStore._uuid.v4(),
      workspaceId: workspaceId,
      name: name.trim(),
      color: color,
      icon: icon,
      position: _nextLabelPosition(workspaceId),
    );
    _labels = [..._labels, label]..sort(NotesStore._byLabelPosition);
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.labelCreate,
        id: label.id,
        data: {
          'name': label.name,
          'workspaceId': label.workspaceId,
          'color': color,
          'icon': icon,
          'position': label.position,
        },
      ),
    );
    return label;
  }

  /// A new label goes to the end of the sidebar list, matching the server.
  double _nextLabelPosition(String workspaceId) {
    var max = 0.0;
    for (final label in _labels) {
      if (label.workspaceId == workspaceId && label.position > max) {
        max = label.position;
      }
    }
    return max + kPositionGap;
  }

  /// Rename and/or restyle a label. Passing null for [color]/[icon] clears it
  /// (resets to the theme default), these are set to exactly what's given, not
  /// merged, so the editor's "no colour"/"no icon" choice sticks. [position]
  /// moves the label in the sidebar; omitting it leaves the order alone.
  void updateLabel(
    String id, {
    String? name,
    String? color,
    String? icon,
    double? position,
  }) {
    final i = _labels.indexWhere((l) => l.id == id);
    if (i == -1) return;
    final newName = (name ?? _labels[i].name).trim();
    _labels[i] = Label(
      id: id,
      workspaceId: _labels[i].workspaceId,
      name: newName,
      color: color,
      icon: icon,
      position: position ?? _labels[i].position,
    );
    _labels.sort(NotesStore._byLabelPosition);
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.labelUpdate,
        id: id,
        data: {
          'name': newName,
          'color': color,
          'icon': icon,
          'position': position,
        },
      ),
    );
  }

  /// Drag-reorder a label. [newIndex] is the final resting index, same
  /// convention as [moveStage].
  void moveLabel(String id, int newIndex) {
    final ordered = labels;
    final label = ordered.where((l) => l.id == id).firstOrNull;
    if (label == null) return;
    final others = [
      for (final l in ordered)
        if (l.id != id) l.position,
    ];
    updateLabel(
      id,
      name: label.name,
      color: label.color,
      icon: label.icon,
      position: positionAt(others, newIndex, current: label.position),
    );
  }

  void deleteLabel(String id) {
    _labels.removeWhere((l) => l.id == id);
    for (var i = 0; i < _notes.length; i++) {
      if (_notes[i].labelIds.contains(id)) {
        _notes[i] = _notes[i].copyWith(
          labelIds: {..._notes[i].labelIds}..remove(id),
        );
      }
    }
    notifyListeners();
    _enqueue(PendingOp(PendingOpKind.labelDelete, id: id));
  }
}
