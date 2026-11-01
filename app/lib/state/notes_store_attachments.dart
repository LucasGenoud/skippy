part of 'notes_store.dart';

/// Files on notes: uploads, removal, signed URLs, and the audio notes built
/// on top of them.
extension NotesStoreAttachments on NotesStore {
  /// Await-based: the editor shows progress and needs the server-issued id.
  /// Accepts any file type; the server decides how it may be served.
  Future<void> uploadFile(
    String noteId,
    Uint8List bytes,
    String mime,
    String filename,
  ) async {
    await _materializeForAttachment(noteId);
    await _drainQueue();
    final attachment = await api.uploadAttachment(
      noteId,
      bytes,
      mime,
      filename,
    );
    final note = noteById(noteId);
    if (note != null) {
      _replace(note.copyWith(attachments: [...note.attachments, attachment]));
    }
  }

  Future<void> _materializeForAttachment(String noteId) async {
    if (_drafts.contains(noteId)) {
      // Force-create even while textually empty; the file is the content.
      _drafts.remove(noteId);
      final note = noteById(noteId);
      if (note != null) {
        final created = await api.createNote(note);
        _serverUpdatedAt[noteId] = created.updatedAt.toUtc().toIso8601String();
      }
    }
  }

  /// Drag-and-drop onto the grid: one new note holding all [files].
  /// Returns the note id, or null when nothing uploaded (the empty draft is
  /// discarded rather than left as a phantom note).
  Future<String?> createNoteWithFiles(
    List<DroppedFile> files, {
    Set<String> labelIds = const {},
  }) async {
    final note = createDraft(labelIds: labelIds);
    var uploaded = 0;
    for (final file in files) {
      try {
        await uploadFile(note.id, file.bytes, file.mime, file.name);
        uploaded++;
      } catch (_) {
        // Skip the failed file; the rest may still make it.
      }
    }
    if (uploaded == 0) {
      deleteForever(note.id);
      return null;
    }
    return note.id;
  }

  /// Content shared into the app (a link, some text) → one text note.
  /// Materializes immediately via [updateNoteContent] (which pushes the draft
  /// to the server). Returns the note id, or null when there was nothing to
  /// save (the empty draft is discarded rather than left as a phantom note).
  Future<String?> createTextNote(String content, {String title = ''}) async {
    final body = content.trim();
    final heading = title.trim();
    if (body.isEmpty && heading.isEmpty) return null;
    final note = createDraft();
    updateNoteContent(note.id, title: heading, content: body);
    return note.id;
  }

  void removeAttachment(String noteId, String attachmentId) {
    final note = noteById(noteId);
    if (note == null) return;
    _replace(
      note.copyWith(
        attachments: note.attachments
            .where((attachment) => attachment.id != attachmentId)
            .toList(),
      ),
    );
    _enqueue(PendingOp(PendingOpKind.deleteAttachment, id: attachmentId));
  }

  /// Resolved, ready-to-load URL for an attachment (uses the server's signed,
  /// time-limited URL so image/audio element loads stay authorized).
  String fileUrl(Attachment attachment) => api.attachmentUrl(attachment);

  // ---------------------------------------------------------------------
  // Audio notes

  /// Recording finished → create an audio note holding the clip. When Whisper
  /// is available, the note is shown as transcribing immediately; otherwise it
  /// remains a fully playable audio note with an empty editable transcript.
  /// Returns the note id, or null when the upload failed (the empty draft is
  /// discarded).
  Future<String?> createAudioNote(
    Uint8List bytes,
    String mime, {
    Set<String> labelIds = const {},
    bool transcriptionAvailable = false,
  }) async {
    final note = createDraft(kind: NoteKind.audio, labelIds: labelIds);
    if (transcriptionAvailable) {
      // Surface the transcribing animation before the round-trip completes.
      _replace(note.copyWith(transcriptStatus: 'pending'));
    }
    final ext = switch (mime.split(';').first.trim()) {
      'audio/webm' => 'webm',
      'audio/ogg' => 'ogg',
      'audio/mp4' => 'm4a',
      'audio/mpeg' => 'mp3',
      'audio/wav' || 'audio/x-wav' => 'wav',
      _ => 'audio',
    };
    try {
      await uploadFile(note.id, bytes, mime, 'recording.$ext');
    } catch (_) {
      deleteForever(note.id);
      return null;
    }
    return note.id;
  }

  /// Retry a failed (or stale) transcription. Optimistically flips the note
  /// back to transcribing while the server re-runs Whisper.
  void retranscribe(String id) {
    final note = noteById(id);
    if (note == null) return;
    _replace(note.copyWith(transcriptStatus: 'pending'));
    _enqueue(PendingOp(PendingOpKind.transcribe, id: id));
  }

  /// Stop the server's automatic link summaries for [id]. Not queued: the job
  /// lives only in the server's memory, so there is nothing to replay later.
  Future<void> cancelLinkSummaries(String id) async {
    final note = noteById(id);
    if (note == null || !note.summarizingLinks) {
      return;
    }

    _replace(note.copyWith(summarizingLinks: false));
    try {
      await api.cancelLinkSummaries(id);
    } catch (_) {
      // The server's view of the job is the truth; fetch it back.
      unawaited(refresh());
    }
  }
}
