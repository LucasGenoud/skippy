part of 'notes_store.dart';

extension CollectionOperations on NotesStore {
  String get composeCollectionId =>
      collectionById(_activeCollectionId)?.id ?? 'inbox';
  List<NoteCollection> get collections =>
      activeWorkspace?.collections ?? const [NoteCollection.inbox];
  NoteCollection? collectionById(String? id) {
    for (final c in collections) {
      if (c.id == id) {
        return c;
      }
    }
    return null;
  }

  ViewSelection collectionSelection(String id) => ViewSelection.collection(
    id,
    layout: collectionById(id)?.layout == 'board'
        ? NoteView.board
        : NoteView.notes,
  );
  void selectCollection(String? id) {
    _activeCollectionId = collectionById(id)?.id;
    notifyListeners();
  }

  List<Note> get notesInCollection => notesInActiveWorkspace
      .where((n) => workspaceScope.collectionOf(n) == composeCollectionId)
      .toList();
  void putCollection(NoteCollection collection) {
    final index = _workspaces.indexWhere((w) => w.id == _activeWorkspaceId);
    if (index < 0) {
      return;
    }
    final workspace = _workspaces[index];
    _workspaces[index] = workspace.copyWith(
      collections: [
        for (final c in workspace.collections)
          if (c.id != collection.id) c,
        collection,
      ]..sort((a, b) => a.position.compareTo(b.position)),
    );
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.collectionPut,
        id: collection.id,
        data: {'workspaceId': workspace.id, 'collection': collection.toJson()},
      ),
    );
  }

  NoteCollection createCollection(String name, String layout) {
    final collection = NoteCollection(
      id: NotesStore._uuid.v4(),
      name: name.trim(),
      layout: layout,
      position: collections.length * 1024.0,
    );
    putCollection(collection);
    return collection;
  }

  void deleteCollection(String id) {
    if (id == 'inbox') {
      return;
    }
    final index = _workspaces.indexWhere((w) => w.id == _activeWorkspaceId);
    if (index < 0) {
      return;
    }
    final workspace = _workspaces[index];
    _workspaces[index] = workspace.copyWith(
      collections: workspace.collections.where((c) => c.id != id).toList(),
    );
    for (var i = 0; i < _notes.length; i++) {
      if (_notes[i].workspaceId == workspace.id &&
          _notes[i].collectionId == id) {
        _notes[i] = _notes[i].copyWith(collectionId: 'inbox', stageId: null);
      }
    }
    _stages.removeWhere(
      (s) => s.workspaceId == workspace.id && s.collectionId == id,
    );
    if (_activeCollectionId == id) {
      _activeCollectionId = 'inbox';
    }
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.collectionDelete,
        id: id,
        data: {'workspaceId': workspace.id},
      ),
    );
  }

  void moveToCollection(String noteId, String collectionId) {
    moveNotesToCollection([noteId], collectionId);
  }

  /// Moves several notes with one optimistic rebuild while retaining one
  /// durable patch per note for retry and conflict handling.
  void moveNotesToCollection(Iterable<String> noteIds, String collectionId) {
    final target = collectionById(collectionId);
    if (target == null) return;
    final seen = <String>{};
    for (final noteId in noteIds) {
      if (!seen.add(noteId)) continue;
      final note = noteById(noteId);
      if (note == null ||
          note.workspaceId != _activeWorkspaceId ||
          note.collectionId == target.id) {
        continue;
      }
      _patch(noteId, note.copyWith(collectionId: target.id, stageId: null), {
        'collection_id': target.id,
        'stage_id': null,
      });
    }
  }
}

Map<String, dynamic> _creationScope(Note note) => {
  'workspace_id': note.workspaceId,
  'collection_id': note.collectionId,
  'stage_id': note.stageId,
};
