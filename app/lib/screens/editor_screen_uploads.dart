part of 'editor_screen.dart';

/// Attaching files: the picker, the paperclip, drag-drop and paste all go
/// through [_uploadAll], which enforces the size cap and reports failures.
extension _EditorUploads on _EditorScreenState {
  /// Shared upload path for the image picker, the paperclip, and drag-drop:
  /// enforces the size cap, drives the progress bar, and reports failures
  /// with [failureMessage].
  Future<void> _uploadAll(
    List<DroppedFile> files, {
    required String failureMessage,
  }) async {
    final accepted = withinUploadLimit(files);
    if (accepted.isEmpty) return;
    _ensureNote();
    final id = _noteId!;
    _rebuild(() => _uploading = true);
    try {
      for (final f in accepted) {
        _rebuild(() => _pendingUploads.add(f));
        try {
          await _store.uploadFile(id, f.bytes, f.mime, f.name);
        } finally {
          if (mounted) _rebuild(() => _pendingUploads.remove(f));
        }
      }
    } catch (_) {
      showAppSnack(
        failureMessage,
        icon: Icons.error_outline,
        kind: SnackKind.danger,
      );
    } finally {
      if (mounted) _rebuild(() => _uploading = false);
    }
  }

  Future<void> _pickImage() async {
    // Adding a picture is a deliberate step away from typing, and the picker
    // it opens is a native screen: leaving a field focused across that
    // round-trip is what leaves the keyboard stuck up over the note (and,
    // after closing it, over the grid).
    dismissKeyboard();
    _ensureNote();
    try {
      final picked = await pickNoteImages(context);
      await _uploadAll(picked, failureMessage: "Couldn't upload the image");
    } catch (_) {
      showAppSnack(
        "Couldn't upload the image",
        icon: Icons.error_outline,
        kind: SnackKind.danger,
      );
    }
  }

  /// Attach any files (documents, archives, audio…). Images render inline;
  /// everything else becomes a download tile.
  Future<void> _pickFile() async {
    // Same native round-trip as [_pickImage].
    dismissKeyboard();
    _ensureNote();
    try {
      await _uploadAll(
        await pickAnyFiles(),
        failureMessage: "Couldn't upload the file",
      );
    } catch (_) {
      showAppSnack(
        "Couldn't upload the file",
        icon: Icons.error_outline,
        kind: SnackKind.danger,
      );
    }
  }

  /// Files dragged in from the OS attach to this note (web only).
  Future<void> _addDroppedFiles(List<DroppedFile> files) async {
    if (_note?.trashed ?? false) return;
    await _uploadAll(
      files,
      failureMessage: "Couldn't upload the dropped files",
    );
  }

  /// Files on the clipboard attach to this note: a pasted screenshot renders
  /// inline like any other image, a pasted file becomes a download tile.
  Future<void> _addPastedFiles(List<DroppedFile> files) async {
    if (_note?.trashed ?? false) return;
    await _uploadAll(files, failureMessage: "Couldn't upload the pasted files");
  }
}
