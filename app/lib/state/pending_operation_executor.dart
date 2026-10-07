import '../models/collection.dart';
import '../api/api_client.dart';
import '../models/note.dart';
import '../models/saved_view.dart';
import '../models/workspace.dart';
import 'pending_operation.dart';

typedef PendingNoteLookup = Note? Function(String id);

/// Translates durable queue entries into calls on the API seam.
///
/// Queue ordering, retries, and optimistic state stay in the notes store. Keeping
/// this transport mapping separate makes the persisted operation contract
/// testable without constructing the full application store.
class PendingOperationExecutor {
  PendingOperationExecutor({
    required this.api,
    required this.noteById,
    Map<String, String>? serverUpdatedAt,
  }) : _serverUpdatedAt = serverUpdatedAt ?? {};

  final Api api;
  final PendingNoteLookup noteById;

  /// Note id to the `updated_at` the server last reported. A content patch
  /// sends it as `if_unmodified_since`, so an edit made offline cannot
  /// silently overwrite one made elsewhere since.
  final Map<String, String> _serverUpdatedAt;

  static const _contentFields = {'kind', 'title', 'content', 'items'};

  /// Execute one queued write. Creates re-read the freshest note so edits made
  /// after enqueuing still go up, while filing follows queue order; a create for a note deleted in the meantime
  /// is a no-op (a trailing delete/404 tidies the server side).
  Future<void> run(PendingOp op) {
    switch (op.kind) {
      case PendingOpKind.collectionPut:
        return api.putCollection(NoteCollection.fromJson(op.data));
      case PendingOpKind.collectionDelete:
        return api.deleteCollection(op.data['workspaceId'] as String, op.id!);
      case PendingOpKind.create:
        return _create(op);
      case PendingOpKind.patch:
        return _patch(op);
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
          collectionId: op.data['collectionId'] as String?,
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
      case PendingOpKind.workspaceAi:
        return api.updateWorkspaceAi(op.id!, AiSwitches.fromJson(op.data));
      case PendingOpKind.savedViewPut:
        return api.putSavedView(
          op.data['workspaceId'] as String,
          SavedView.fromJson((op.data['view'] as Map).cast<String, dynamic>())!,
        );
      case PendingOpKind.savedViewDelete:
        return api.deleteSavedView(op.data['workspaceId'] as String, op.id!);
      case PendingOpKind.workspaceDelete:
        return api.deleteWorkspace(op.id!);
      case PendingOpKind.leaveWorkspace:
        return api.removeWorkspaceMember(op.id!, op.data['userId'] as String);
      case PendingOpKind.removeCollaborator:
        return api.removeCollaborator(op.id!, op.data['userId'] as String);
      case PendingOpKind.itemReminder:
        final at = op.data['at'] as String?;
        return api.setItemReminder(
          op.id!,
          op.data['itemId'] as String,
          // A null time is the clear, which is why the whole resource is
          // written rather than patched.
          at: at == null ? null : DateTime.parse(at),
          repeat: ReminderRepeat.fromWire(op.data['repeat'] as String?),
        );
      case PendingOpKind.deleteAttachment:
        return api.deleteAttachment(op.id!);
      case PendingOpKind.transcribe:
        return api.transcribeNote(op.id!);
      case PendingOpKind.unknown:
        return Future<void>.value();
    }
  }

  Future<void> _create(PendingOp op) async {
    final note = noteById(op.id!);
    if (note == null) {
      return;
    }
    final created = await api.createNote(
      Note.fromJson({...note.toJson(), ...op.data}),
    );
    _serverUpdatedAt[op.id!] = created.updatedAt.toUtc().toIso8601String();
  }

  Future<void> _patch(PendingOp op) async {
    final fields = Map<String, dynamic>.of(op.data);
    final expected = _serverUpdatedAt[op.id!];
    if (expected != null && fields.keys.any(_contentFields.contains)) {
      fields['if_unmodified_since'] = expected;
    }
    final updated = await api.patchNote(op.id!, fields);
    _serverUpdatedAt[op.id!] = updated.updatedAt.toUtc().toIso8601String();
  }
}
