import '../api/api_client.dart';
import '../models/note.dart';
import 'pending_operation.dart';

typedef PendingNoteLookup = Note? Function(String id);

/// Translates durable queue entries into calls on the API seam.
///
/// Queue ordering, retries, and optimistic state stay in the notes store. Keeping
/// this transport mapping separate makes the persisted operation contract
/// testable without constructing the full application store.
class PendingOperationExecutor {
  const PendingOperationExecutor({required this.api, required this.noteById});

  final Api api;
  final PendingNoteLookup noteById;

  /// Execute one queued write. Creates re-read the freshest note so edits made
  /// after enqueuing still go up; a create for a note deleted in the meantime
  /// is a no-op (a trailing delete/404 tidies the server side).
  Future<void> run(PendingOp op) {
    switch (op.kind) {
      case PendingOpKind.create:
        final note = noteById(op.id!);
        return note == null ? Future.value() : api.createNote(note);
      case PendingOpKind.patch:
        return api.patchNote(op.id!, op.data);
      case PendingOpKind.delete:
        return api.deleteNote(op.id!);
      case PendingOpKind.reorder:
        return api.reorderNotes((op.data['ids'] as List).cast<String>());
      case PendingOpKind.labelCreate:
        return api.createLabel(
          op.id!,
          op.data['name'] as String,
          workspaceId: op.data['workspaceId'] as String? ?? '',
          color: op.data['color'] as String?,
          icon: op.data['icon'] as String?,
          position: (op.data['position'] as num?)?.toDouble(),
        );
      case PendingOpKind.labelUpdate:
        return api.updateLabel(
          op.id!,
          op.data['name'] as String,
          color: op.data['color'] as String?,
          icon: op.data['icon'] as String?,
          position: (op.data['position'] as num?)?.toDouble(),
        );
      case PendingOpKind.labelDelete:
        return api.deleteLabel(op.id!);
      case PendingOpKind.stageCreate:
        return api.createStage(
          op.id!,
          op.data['name'] as String,
          workspaceId: op.data['workspaceId'] as String? ?? '',
          color: op.data['color'] as String?,
          position: (op.data['position'] as num?)?.toDouble(),
        );
      case PendingOpKind.stageUpdate:
        return api.updateStage(
          op.id!,
          op.data['name'] as String,
          color: op.data['color'] as String?,
          position: (op.data['position'] as num?)?.toDouble(),
        );
      case PendingOpKind.stageDelete:
        return api.deleteStage(op.id!);
      case PendingOpKind.workspaceCreate:
        return api.createWorkspace(op.id!, op.data['name'] as String);
      case PendingOpKind.workspaceRename:
        return api.renameWorkspace(op.id!, op.data['name'] as String);
      case PendingOpKind.workspaceViews:
        return api.updateWorkspaceViews(
          op.id!,
          notesEnabled: op.data['notesEnabled'] as bool? ?? true,
          boardEnabled: op.data['boardEnabled'] as bool? ?? true,
        );
      case PendingOpKind.workspaceDelete:
        return api.deleteWorkspace(op.id!);
      case PendingOpKind.leaveWorkspace:
        return api.removeWorkspaceMember(op.id!, op.data['userId'] as String);
      case PendingOpKind.removeCollaborator:
        return api.removeCollaborator(op.id!, op.data['userId'] as String);
      case PendingOpKind.deleteAttachment:
        return api.deleteAttachment(op.id!);
      case PendingOpKind.transcribe:
        return api.transcribeNote(op.id!);
      case PendingOpKind.unknown:
        return Future<void>.value();
    }
  }
}
