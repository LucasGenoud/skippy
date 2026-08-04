import 'dart:typed_data';

import '../api/api_client.dart';
import '../models/note.dart';

typedef NoteLookup = Note? Function(String id);
typedef NoteReplacement = void Function(Note note);

/// Coordinates attachment round-trips while the notes store retains ownership
/// of optimistic state, drafts, and its serial write queue.
class NoteAttachmentCoordinator {
  const NoteAttachmentCoordinator({
    required this.api,
    required this.noteById,
    required this.replace,
    required this.ensureMaterialized,
    required this.drainQueue,
  });

  final Api api;
  final NoteLookup noteById;
  final NoteReplacement replace;
  final Future<void> Function(String noteId) ensureMaterialized;
  final Future<void> Function() drainQueue;

  Future<void> upload(
    String noteId,
    Uint8List bytes,
    String mime,
    String filename,
  ) async {
    await ensureMaterialized(noteId);
    await drainQueue();
    final attachment = await api.uploadAttachment(
      noteId,
      bytes,
      mime,
      filename,
    );
    final note = noteById(noteId);
    if (note != null) {
      replace(note.copyWith(attachments: [...note.attachments, attachment]));
    }
  }

  bool removeLocal(String noteId, String attachmentId) {
    final note = noteById(noteId);
    if (note == null) return false;
    replace(
      note.copyWith(
        attachments: note.attachments
            .where((attachment) => attachment.id != attachmentId)
            .toList(),
      ),
    );
    return true;
  }
}
