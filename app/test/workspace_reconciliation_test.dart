import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/workspace_reconciliation.dart';

void main() {
  test('leaving retains only direct shares and strips workspace metadata', () {
    final now = DateTime(2026);
    Note note(String id, {List<UserRef> collaborators = const []}) => Note(
      id: id,
      workspaceId: 'work',
      createdAt: now,
      updatedAt: now,
      labelIds: const {'work-label', 'foreign-label'},
      stageId: 'doing',
      collaborators: collaborators,
    );
    final result = reconcileWorkspaceDeparture(
      notes: [
        note('workspace-only'),
        note(
          'direct',
          collaborators: const [UserRef(id: 'me', name: 'Me')],
        ),
        Note(
          id: 'elsewhere',
          workspaceId: 'home',
          createdAt: now,
          updatedAt: now,
        ),
      ],
      labels: const [
        Label(id: 'work-label', workspaceId: 'work', name: 'Work', position: 0),
      ],
      workspaceId: 'work',
      userId: 'me',
    );

    expect(result.directlySharedIds, {'direct'});
    expect(result.notes.map((note) => note.id), ['direct', 'elsewhere']);
    final retained = result.notes.first;
    expect(retained.workspaceId, 'work');
    expect(retained.labelIds, {'foreign-label'});
    expect(retained.stageId, isNull);
  });
}
