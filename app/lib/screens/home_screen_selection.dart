part of 'home_screen.dart';

/// Bulk actions on the notes picked in selection mode: label, colour, pin,
/// share, archive, move to a column, restore and trash.
extension _HomeSelection on _HomeScreenState {
  void _cancelSelection() {
    _rebuild(() {
      _selectionMode = false;
      _selectedNoteIds.clear();
    });
    _selectionModeNotifier.value = false;
  }

  void _toggleNoteSelection(String id, bool selected) {
    _rebuild(() {
      if (selected) {
        _selectionMode = true;
        _selectedNoteIds.add(id);
      } else {
        _selectedNoteIds.remove(id);
      }
      // An empty selection has nothing to act on: deselecting the last note
      // leaves the mode instead of stranding the user in an inert action bar.
      _selectionMode = _selectedNoteIds.isNotEmpty;
    });
    _selectionModeNotifier.value = _selectionMode;
  }

  void _toggleSelectAll(Iterable<Note> visibleNotes) {
    final ids = {for (final note in visibleNotes) note.id};
    _rebuild(() {
      if (ids.isNotEmpty && ids.every(_selectedNoteIds.contains)) {
        _selectedNoteIds.removeAll(ids);
      } else {
        _selectedNoteIds.addAll(ids);
      }
      _selectionMode = _selectedNoteIds.isNotEmpty;
    });
    _selectionModeNotifier.value = _selectionMode;
  }

  List<Note> _selectedNotes(NotesStore store) => [
    for (final id in _selectedNoteIds)
      if (store.noteById(id) case final Note note) note,
  ];

  Future<void> _addLabelToSelected(NotesStore store) =>
      LabelsSheet.showForNotes(
        context,
        _selectedNotes(store).map((note) => note.id),
      );

  /// Bulk-file the selection into a column, then leave selection mode, the
  /// selection was a means to the move, not a state to stay in.
  Future<void> _moveSelectedToStage(NotesStore store) async {
    await MoveToStageSheet.showForNotes(
      context,
      _selectedNotes(store).map((note) => note.id),
    );
    if (mounted) _cancelSelection();
  }

  Future<void> _setColorForSelected(NotesStore store) => ColorPickerSheet.show(
    context,
    selected: () {
      final colors = {for (final note in _selectedNotes(store)) note.color};
      return colors.length == 1 ? colors.single : 'default';
    },
    onSelect: (color) {
      for (final note in _selectedNotes(store)) {
        store.setColor(note.id, color);
      }
    },
    selectedPattern: () {
      final patterns = {for (final note in _selectedNotes(store)) note.pattern};
      return patterns.length == 1 ? patterns.single : NotePattern.none;
    },
    onSelectPattern: (pattern) {
      for (final note in _selectedNotes(store)) {
        store.setPattern(note.id, pattern);
      }
    },
  );

  void _setPinnedForSelected(NotesStore store, bool pinned) {
    final notes = _selectedNotes(store);
    for (final note in notes) {
      if (note.pinned != pinned) store.togglePin(note.id);
    }
  }

  Future<void> _shareSelected(NotesStore store) => BulkShareDialog.show(
    context,
    _selectedNotes(store).map((note) => note.id),
  );

  void _setArchivedForSelected(NotesStore store, bool archived) {
    final notes = _selectedNotes(
      store,
    ).where((note) => note.archived != archived).toList();
    for (final note in notes) {
      store.setArchived(note.id, archived);
    }
    _cancelSelection();
  }

  Future<void> _restoreSelected(NotesStore store) async {
    final notes = _selectedNotes(store).where((note) => note.trashed).toList();
    for (final note in notes) {
      if (!mounted) {
        return;
      }
      await CollectionPicker.restore(context, note.id);
    }
    _cancelSelection();
  }

  void _trashSelected(NotesStore store) {
    final notes = _selectedNotes(
      store,
    ).where((note) => store.canTrash(note.id)).toList();
    final skipped = _selectedNoteIds.length - notes.length;
    for (final note in notes) {
      store.moveToTrash(note.id);
    }
    _cancelSelection();
    if (notes.isNotEmpty) {
      showAppSnack(
        '${notes.length} ${notes.length == 1 ? 'note' : 'notes'} moved to Trash${skipped > 0 ? '; shared notes were skipped' : ''}',
        icon: Icons.delete_outline,
        kind: SnackKind.danger,
        actionLabel: 'Undo',
        onAction: () {
          for (final note in notes) {
            store.restoreFromTrash(note.id);
          }
        },
      );
    } else if (skipped > 0) {
      showAppSnack(
        'Only note owners can move notes to Trash',
        icon: Icons.error_outline,
        kind: SnackKind.warning,
      );
    }
  }
}
