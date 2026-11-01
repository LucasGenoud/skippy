part of 'notes_store.dart';

/// Workspaces and the collections inside them: which one is open, creating,
/// renaming and leaving them, their rosters, and filing notes between them.
extension NotesStoreWorkspaces on NotesStore {
  // Collections

  List<NoteCollection> get collections =>
      activeWorkspace?.collections ?? const [];
  NoteCollection? get activeCollection {
    final id = _collectionChoices[_activeWorkspaceId];
    for (final c in collections) {
      if (c.id == id) {
        return c;
      }
    }
    return collections.isEmpty ? null : collections.first;
  }

  void selectCollection(String id) {
    if (!collections.any((c) => c.id == id)) {
      return;
    }
    _collectionChoices[_activeWorkspaceId!] = id;
    _navigationChanged();
  }

  WorkspaceScope get collectionScope => WorkspaceScope(
    workspaceId: _activeWorkspaceId,
    isDefault: workspaceScope.isDefault,
    known: workspaceScope.known,
    collectionId: activeCollection?.id,
  );

  Future<void> duplicateWorkspace(
    String id,
    String name,
    WorkspaceCopyContent content, {
    bool reminders = false,
  }) async {
    flushForBackground();
    await _drainQueue();
    if (_connectionDown || _queue.isNotEmpty) {
      throw StateError(
        'Connect and finish syncing before duplicating a workspace',
      );
    }
    final copy = await api.duplicateWorkspace(
      id,
      name,
      content,
      reminders: reminders,
    );
    await refresh();
    setActiveWorkspace(copy.id);
  }

  void saveCollection(NoteCollection collection) {
    _collectionSorts.remove(collection.id);
    _workspaces = [
      for (final w in _workspaces)
        if (w.id == collection.workspaceId)
          w.copyWith(
            collections: [
              ...w.collections.where((c) => c.id != collection.id),
              collection,
            ]..sort((a, b) => a.position.compareTo(b.position)),
          )
        else
          w,
    ];
    _enqueue(
      PendingOp(
        PendingOpKind.collectionPut,
        id: collection.id,
        data: collection.toJson(),
      ),
    );
    notifyListeners();
  }

  void moveCollection(String id, int newIndex) {
    final workspace = activeWorkspace;
    if (workspace == null) return;
    final collection = workspace.collections
        .where((c) => c.id == id)
        .firstOrNull;
    if (collection == null) return;
    final others = [
      for (final c in workspace.collections)
        if (c.id != id) c.position,
    ];
    saveCollection(
      NoteCollection(
        id: collection.id,
        workspaceId: collection.workspaceId,
        name: collection.name,
        icon: collection.icon,
        color: collection.color,
        layout: collection.layout,
        sort: collection.sort,
        position: positionAt(others, newIndex, current: collection.position),
      ),
    );
  }

  void deleteCollection(String id) {
    final workspaceId = _workspaces
        .where((w) => w.collections.any((c) => c.id == id))
        .firstOrNull
        ?.id;
    if (workspaceId == null) {
      return;
    }
    _workspaces = [
      for (final w in _workspaces)
        if (w.id == workspaceId)
          w.copyWith(
            collections: w.collections.where((c) => c.id != id).toList(),
          )
        else
          w,
    ];
    _notes = [
      for (final n in _notes)
        if (n.collectionId == id)
          n.copyWith(trashed: true, stageId: null)
        else
          n,
    ];
    _stages.removeWhere((s) => s.collectionId == id);
    _enqueue(
      PendingOp(
        PendingOpKind.collectionDelete,
        id: id,
        data: {'workspaceId': workspaceId},
      ),
    );
    notifyListeners();
  }

  void moveToCollection(String noteId, String collectionId) {
    final note = noteById(noteId);
    if (note == null || !_hasCollection(note.workspaceId, collectionId)) {
      return;
    }
    _patch(noteId, note.copyWith(collectionId: collectionId, stageId: null), {
      'collection_id': collectionId,
      'stage_id': null,
    });
  }

  /// Files the note in [collectionId] as a live note: one waiting in the
  /// archive or Trash comes back out in the same patch, so the move and the
  /// restore cannot land apart. A drop on a collection asks for exactly this.
  void restoreToCollection(String noteId, String collectionId) {
    final note = noteById(noteId);
    if (note == null || !_hasCollection(note.workspaceId, collectionId)) {
      return;
    }
    if (!note.archived && !note.trashed) {
      moveToCollection(noteId, collectionId);
      return;
    }
    _patch(
      noteId,
      note.copyWith(
        collectionId: collectionId,
        stageId: null,
        archived: false,
        trashed: false,
      ),
      {
        'collection_id': collectionId,
        'stage_id': null,
        'archived': false,
        'trashed': false,
      },
    );
  }

  bool _hasCollection(String workspaceId, String collectionId) =>
      workspaceById(
        workspaceId,
      )?.collections.any((c) => c.id == collectionId) ??
      false;

  // Workspaces

  List<SavedView> get savedViews =>
      List.unmodifiable(activeWorkspace?.savedViews ?? const <SavedView>[]);

  SavedView? savedViewById(String id) {
    for (final view in savedViews) {
      if (view.id == id) {
        return view;
      }
    }
    return null;
  }

  SavedView addSavedView({
    required String name,
    required String query,
    String? icon,
    String? color,
  }) {
    final view = SavedView(
      id: NotesStore._uuid.v4(),
      name: name.trim(),
      query: query.trim(),
      icon: icon,
      color: color,
      position: positionBetween(savedViews.lastOrNull?.position, null),
    );
    _putSavedView(view);
    return view;
  }

  void updateSavedView(
    String id, {
    required String name,
    required String query,
    String? icon,
    String? color,
  }) {
    final view = savedViewById(id);
    if (view == null) {
      return;
    }
    _putSavedView(
      view.copyWith(
        name: name.trim(),
        query: query.trim(),
        icon: icon,
        color: color,
      ),
    );
  }

  void _putSavedView(SavedView view) {
    final index = _workspaces.indexWhere((w) => w.id == _activeWorkspaceId);
    if (index < 0) {
      return;
    }
    final workspace = _workspaces[index];
    _workspaces[index] = workspace.copyWith(
      savedViews: [
        for (final old in workspace.savedViews)
          if (old.id != view.id) old,
        view,
      ]..sort((a, b) => a.position.compareTo(b.position)),
    );
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.savedViewPut,
        id: view.id,
        data: {'workspaceId': workspace.id, 'view': view.toJson()},
      ),
    );
  }

  void removeSavedView(String id) {
    final index = _workspaces.indexWhere((w) => w.id == _activeWorkspaceId);
    if (index < 0 || savedViewById(id) == null) {
      return;
    }
    final workspace = _workspaces[index];
    _workspaces[index] = workspace.copyWith(
      savedViews: workspace.savedViews.where((v) => v.id != id).toList(),
    );
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.savedViewDelete,
        id: id,
        data: {'workspaceId': workspace.id},
      ),
    );
  }

  void reorderSavedViews(int oldIndex, int newIndex) {
    final next = [...savedViews];
    if (oldIndex < 0 || oldIndex >= next.length) {
      return;
    }
    final view = next.removeAt(oldIndex);
    final others = [for (final v in next) v.position];
    _putSavedView(
      view.copyWith(
        position: positionAt(others, newIndex, current: view.position),
        icon: view.icon,
        color: view.color,
      ),
    );
  }

  /// Create a workspace and switch to it. Optimistic like note creation: the
  /// switch happens now and the write drains through the queue.
  Workspace createWorkspace(String name) {
    final id = NotesStore._uuid.v4();
    final workspace = Workspace(
      id: id,
      collections: [NoteCollection.general(id)],
      name: name.trim(),
      owner: currentUserId == null
          ? null
          : UserRef(id: currentUserId!, name: ''),
    );
    _workspaces = [..._workspaces, workspace];
    _activeWorkspaceId = workspace.id;
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.workspaceCreate,
        id: workspace.id,
        data: {'name': workspace.name},
      ),
    );
    return workspace;
  }

  void renameWorkspace(String id, String name) {
    final i = _workspaces.indexWhere((w) => w.id == id);
    if (i == -1) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _workspaces[i] = _workspaces[i].copyWith(name: trimmed);
    notifyListeners();
    _enqueue(
      PendingOp(PendingOpKind.workspaceRename, id: id, data: {'name': trimmed}),
    );
  }

  /// Enable the workspace's two primary entry points. The owner controls this
  /// shared setting; keeping one enabled prevents a workspace with no main
  /// place to show or create notes.
  void updateWorkspaceViews({
    required String id,
    required bool notesEnabled,
    required bool boardEnabled,
  }) {
    if (!notesEnabled && !boardEnabled) return;
    final i = _workspaces.indexWhere((w) => w.id == id);
    if (i == -1 || !_workspaces[i].isOwnedBy(currentUserId)) return;
    _workspaces[i] = _workspaces[i].copyWith(
      notesEnabled: notesEnabled,
      boardEnabled: boardEnabled,
    );
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.workspaceViews,
        id: id,
        data: {'notesEnabled': notesEnabled, 'boardEnabled': boardEnabled},
      ),
    );
  }

  /// Set a workspace's AI switches. Like its views, only the owner changes
  /// them, and every member gets the AI they allow.
  void updateWorkspaceAi(String id, AiSwitches switches) {
    final i = _workspaces.indexWhere((w) => w.id == id);
    if (i == -1 || !_workspaces[i].isOwnedBy(currentUserId)) return;
    final workspace = _workspaces[i];
    _workspaces[i] = workspace.copyWith(
      ai: workspace.ai.copyWith(switches: switches),
    );
    notifyListeners();
    _enqueue(
      PendingOp(PendingOpKind.workspaceAi, id: id, data: switches.toJson()),
    );
  }

  /// The AI in workspace [id]. A note reached through a direct share, from a
  /// workspace this user is not in, gets none: that owner's setup is not
  /// visible from here.
  WorkspaceAi aiIn(String? id) => workspaceById(id)?.ai ?? const WorkspaceAi();

  /// Whether [id] can be deleted: you own it and it isn't your default one.
  bool canDeleteWorkspace(String id) {
    final workspace = workspaceById(id);
    return workspace != null &&
        !workspace.isDefault &&
        workspace.isOwnedBy(currentUserId);
  }

  /// Permanently delete a workspace and every note it contains. Cancel local
  /// debounced saves and drafts for those notes so no write can be enqueued
  /// after the workspace-delete operation.
  void deleteWorkspace(String id) {
    if (!canDeleteWorkspace(id)) return;
    for (final note in _notes.where((note) => note.workspaceId == id)) {
      _saveDebounce.remove(note.id)?.cancel();
      _drafts.remove(note.id);
    }
    _notes.removeWhere((note) => note.workspaceId == id);
    _labels.removeWhere((label) => label.workspaceId == id);
    _stages.removeWhere((stage) => stage.workspaceId == id);
    _workspaces.removeWhere((workspace) => workspace.id == id);
    _lastWorkspaceViews.remove(id);
    _reconcileActiveWorkspace();
    notifyListeners();
    _enqueue(PendingOp(PendingOpKind.workspaceDelete, id: id));
  }

  /// Leave a workspace someone else owns. Workspace-owned notes disappear
  /// from this user's shelf unless the note also carries an explicit direct
  /// share for them; the server leaves every note in the workspace.
  void leaveWorkspace(String id) {
    final me = currentUserId;
    final workspace = workspaceById(id);
    if (me == null || workspace == null || workspace.isOwnedBy(me)) return;
    final departure = reconcileWorkspaceDeparture(
      notes: _notes,
      labels: _labels,
      workspaceId: id,
      userId: me,
    );
    _notes = departure.notes;
    _labels.removeWhere((label) => label.workspaceId == id);
    _stages.removeWhere((stage) => stage.workspaceId == id);
    _workspaces.removeWhere((w) => w.id == id);
    _lastWorkspaceViews.remove(id);
    _reconcileActiveWorkspace();
    notifyListeners();
    _enqueue(
      PendingOp(PendingOpKind.leaveWorkspace, id: id, data: {'userId': me}),
    );
  }

  /// Await-based (not queued): the dialog wants immediate success/failure.
  /// Throws [ApiException] with a friendly `serverMessage` on rejection.
  Future<void> addWorkspaceMember(String workspaceId, String email) async {
    // The workspace has to exist on the server before anyone can be added.
    await _drainQueue();
    final updated = await api.addWorkspaceMember(workspaceId, email);
    final i = _workspaces.indexWhere((w) => w.id == workspaceId);
    if (i != -1) {
      _workspaces[i] = _workspaces[i].copyWith(members: updated.members);
      notifyListeners();
    }
  }

  void removeWorkspaceMember(String workspaceId, String userId) {
    if (userId == currentUserId) {
      leaveWorkspace(workspaceId);
      return;
    }
    final i = _workspaces.indexWhere((w) => w.id == workspaceId);
    if (i == -1) return;
    _workspaces[i] = _workspaces[i].copyWith(
      members: _workspaces[i].members.where((m) => m.id != userId).toList(),
    );
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.leaveWorkspace,
        id: workspaceId,
        data: {'userId': userId},
      ),
    );
  }

  /// File a note in another workspace. Owner-only, matching the server: a move
  /// changes who can see the note. Labels from the old workspace are dropped,
  /// since a label belongs to one workspace's taxonomy.
  void moveNoteToWorkspace(String noteId, String workspaceId) {
    final note = noteById(noteId);
    if (note == null ||
        note.workspaceId == workspaceId ||
        !note.isOwnedBy(currentUserId) ||
        workspaceById(workspaceId) == null) {
      return;
    }
    final kept = {
      for (final id in note.labelIds)
        if (labelById(id)?.workspaceId == workspaceId) id,
    };
    final collections = workspaceById(workspaceId)!.collections;
    if (collections.isEmpty) {
      return;
    }
    final collectionId = collections.first.id;
    _patch(
      noteId,
      note.copyWith(
        workspaceId: workspaceId,
        collectionId: collectionId,
        labelIds: kept,
        stageId: null,
      ),
      {
        'workspace_id': workspaceId,
        'collection_id': collectionId,
        'stage_id': null,
      },
    );
  }
}
