import '../models/note.dart';

class WorkspaceDepartureResult {
  const WorkspaceDepartureResult({
    required this.notes,
    required this.directlySharedIds,
  });

  final List<Note> notes;
  final Set<String> directlySharedIds;
}

/// Remove one workspace from a user's local shelf while retaining notes that
/// also carry a direct share for that user. Retained notes lose workspace-only
/// labels and board placement, matching the next server snapshot.
WorkspaceDepartureResult reconcileWorkspaceDeparture({
  required List<Note> notes,
  required List<Label> labels,
  required String workspaceId,
  required String userId,
}) {
  final directlySharedIds = {
    for (final note in notes)
      if (note.workspaceId == workspaceId &&
          note.collaborators.any((collaborator) => collaborator.id == userId))
        note.id,
  };
  final leavingLabelIds = {
    for (final label in labels)
      if (label.workspaceId == workspaceId) label.id,
  };
  final reconciled = <Note>[];
  for (final note in notes) {
    if (note.workspaceId != workspaceId) {
      reconciled.add(note);
    } else if (directlySharedIds.contains(note.id)) {
      reconciled.add(
        note.copyWith(
          labelIds: note.labelIds.difference(leavingLabelIds),
          stageId: null,
        ),
      );
    }
  }
  return WorkspaceDepartureResult(
    notes: reconciled,
    directlySharedIds: directlySharedIds,
  );
}
