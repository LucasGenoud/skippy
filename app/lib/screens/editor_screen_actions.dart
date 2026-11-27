part of 'editor_screen.dart';

/// What the editor does *to* the open note: pin, colour, archive, move,
/// duplicate, copy, AI rewrite and conversion. Kept apart from the editing
/// state they act on, which stays in [_EditorScreenState].
extension _EditorNoteActions on _EditorScreenState {
  void _togglePin() {
    _ensureNote();
    _store.togglePin(_noteId!);
  }

  void _setColor(String color) {
    _ensureNote();
    _store.setColor(_noteId!, color);
  }

  void _setPattern(NotePattern pattern) {
    _ensureNote();
    _store.setPattern(_noteId!, pattern);
  }

  Future<void> _editLabels() async {
    _ensureNote();
    await LabelsSheet.show(context, _noteId!);
  }

  void _archiveAndClose() {
    final note = _note;
    if (note == null || !NoteAvailability(_store, note).canArchive) return;
    Navigator.of(context).pop();
    toggleArchive(_store, note);
  }

  void _deleteAndClose() {
    final note = _note;
    Navigator.of(context).pop();
    if (note != null) {
      trashNote(_store, note.id);
    }
  }

  /// One picker for column, collection and workspace, opened on [initial].
  Future<void> _moveNote(NoteMoveTarget initial) async {
    final note = _note;
    if (note == null) return;
    await MoveNoteSheet.show(
      context,
      note.id,
      targets: _moveTargets(NoteAvailability(_store, note)),
      initial: initial,
    );
  }

  /// Columns only make sense for a note opened from its board.
  List<NoteMoveTarget> _moveTargets(NoteAvailability can) => [
    if (widget.openedFromBoard && can.canMoveToStage) NoteMoveTarget.stage,
    if (can.canMoveToCollection) NoteMoveTarget.collection,
    if (can.canMoveToWorkspace) NoteMoveTarget.workspace,
  ];

  /// Duplicate the open note and keep editing the copy, so the next thing
  /// typed lands in the new note rather than in the one that was copied.
  void _duplicateNote() {
    final note = _note;
    if (note == null || note.isEmpty) return;
    final copy = _store.duplicate(note.id);
    if (copy == null) return;
    // The original is left behind by this editor, so give it the same ending
    // it would get from closing: a still-unsaved draft has to be materialized
    // here, nothing else will come back for it.
    _store.finalizeNote(note.id, retainEmpty: true);
    _store.endEditing(note.id);
    _restoring = true;
    _noteId = copy.id;
    _store.beginEditing(copy.id, newNote: true);
    _titleController.text = copy.title;
    if (!copy.isChecklist) _contentController.text = copy.content;
    _restoring = false;
    // Undo belongs to the note being edited; the copy starts its own session
    // so an undo can't reach back into the original's edits.
    _history = EditorHistory(_currentSnapshot());
    _rebuild(() {});
    showAppSnack(
      'Duplicated. You are now editing “${copy.title}”',
      icon: Icons.copy_all_outlined,
    );
  }

  Future<void> _copyNoteToClipboard() async {
    final note = _note;
    if (note == null || note.isEmpty) return;
    await copyNotesText([note]);
  }

  /// Put this note on the device home screen.
  ///
  /// Only Android can place a widget for the user (`requestPinAppWidget`);
  /// iOS gives apps no such API at all, so there the honest thing is to explain
  /// where the control lives rather than pretend to do it.
  Future<void> _addToHomeScreen() async {
    // A draft has no id to hand a widget, and an unsaved edit would leave the
    // widget showing yesterday's text. Both are fixed by materializing first.
    _ensureNote();
    final note = _note;
    if (note == null) return;
    _store.updateNoteContent(
      note.id,
      title: _titleController.text,
      content: _contentController.text,
    );

    final widgets = HomeWidgets();
    if (await widgets.canPin()) {
      // The launcher opens the widget's configuration screen next; this is the
      // note it should offer first.
      await widgets.setPreselectedNote(note.id);
      await widgets.requestPin();
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) =>
          AddToHomeScreenHelp(noteTitle: widgetDisplayTitle(note)),
    );
  }

  Future<void> _rewriteWithAi(NoteRewriteTask task) async {
    final note = _note;
    if (note == null ||
        !NoteAvailability(_store, note).canRewrite ||
        _store.isRewritingNote(note.id)) {
      return;
    }
    // Put the currently visible controllers into the store before waiting for
    // the server-side rewrite; [NotesStore.rewriteNote] then flushes that
    // pending patch before it asks the LLM to transform the note.
    _store.updateNoteContent(
      note.id,
      title: _titleController.text,
      content: note.isChecklist ? null : _contentController.text,
      items: note.isChecklist ? _items : null,
    );
    if (!await rewriteWithAi(_store, note.id, task) || !mounted) return;
    final updated = _note;
    if (updated != null) {
      _restoring = true;
      _titleController.text = updated.title;
      if (!updated.isChecklist) _contentController.text = updated.content;
      _restoring = false;
    }
    _afterChange(discrete: true);
    _rebuild(() {});
  }

  Future<void> _summarizeUrl(String url) async {
    if (_summaryAborts.containsKey(url)) {
      return;
    }
    final abort = Completer<void>();
    _rebuild(() => _summaryAborts[url] = abort);
    try {
      final summary = (await _store.api.summarizeUrl(
        url,
        noteId: _noteId!,
        length: _settings.linkSummaryLength,
        abort: abort.future,
      )).trim();
      // Stopped while the answer was already on its way.
      if (abort.isCompleted) {
        return;
      }
      if (!mounted || summary.isEmpty) return;
      final current = _contentController.text.trimRight();
      final content = current.isEmpty ? summary : '$current\n\n$summary';
      _restoring = true;
      _contentController.value = TextEditingValue(
        text: content,
        selection: TextSelection.collapsed(offset: content.length),
      );
      _restoring = false;
      _store.updateNoteContent(_noteId!, content: content);
      _afterChange(discrete: true);
      showAppSnack('Page summary added', icon: Icons.auto_awesome_outlined);
    } catch (_) {
      if (mounted && !abort.isCompleted) {
        showAppSnack(
          "Couldn't summarize page",
          icon: Icons.error_outline,
          kind: SnackKind.danger,
        );
      }
    } finally {
      // Only this request's own entry: a stop and a fresh request for the
      // same page may already have replaced it.
      if (_summaryAborts[url] == abort) {
        _summaryAborts.remove(url);
      }
      if (mounted) _rebuild(() {});
    }
  }

  /// Drops the request and discards whatever it would have added.
  void _stopSummarizing(String url) {
    final abort = _summaryAborts[url];
    if (abort == null) {
      return;
    }
    _rebuild(() => _summaryAborts.remove(url));
    abort.complete();
  }

  void _convertKind(NoteKind target) {
    _ensureNote();
    // Flush any un-debounced content first so nothing is lost in conversion.
    _store.updateNoteContent(
      _noteId!,
      title: _titleController.text,
      content: _kind != NoteKind.checklist ? _contentController.text : null,
    );
    _store.convertKind(_noteId!, target);
    final note = _note;
    if (note != null && !note.isChecklist) {
      _restoring = true;
      _contentController.text = note.content;
      _restoring = false;
    }
    _afterChange(discrete: true);
    _rebuild(() => _previewMarkdown = false);
  }
}
