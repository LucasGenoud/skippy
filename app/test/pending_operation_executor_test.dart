import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/pending_operation.dart';
import 'package:skippy/state/pending_operation_executor.dart';

import 'fake_api.dart';

void main() {
  final now = DateTime(2026);

  test('create reads the latest note and a removed draft is a no-op', () async {
    final api = FakeApi();
    Note? current = Note(
      id: 'n1',
      title: 'Latest title',
      createdAt: now,
      updatedAt: now,
    );
    final executor = PendingOperationExecutor(
      api: api,
      noteById: (_) => current,
    );

    await executor.run(const PendingOp(PendingOpKind.create, id: 'n1'));
    expect(api.notes['n1']?.title, 'Latest title');

    current = null;
    await executor.run(const PendingOp(PendingOpKind.create, id: 'removed'));
    expect(api.log.where((entry) => entry.startsWith('createNote:')), [
      'createNote:n1',
    ]);
  });

  test('workspace metadata operations preserve their scoped fields', () async {
    final api = FakeApi();
    final executor = PendingOperationExecutor(api: api, noteById: (_) => null);

    await executor.run(
      const PendingOp(
        PendingOpKind.labelCreate,
        id: 'l1',
        data: {
          'name': 'Important',
          'workspaceId': 'w-default',
          'color': '#ff0000',
          'icon': 'star',
          'position': 42,
        },
      ),
    );
    await executor.run(
      const PendingOp(
        PendingOpKind.stageCreate,
        id: 's1',
        data: {
          'name': 'Doing',
          'workspaceId': 'w-default',
          'color': '#00ff00',
          'position': 84,
        },
      ),
    );

    expect(api.labels['l1']?.workspaceId, 'w-default');
    expect(api.labels['l1']?.position, 42);
    expect(api.stages['s1']?.workspaceId, 'w-default');
    expect(api.stages['s1']?.position, 84);
  });

  test(
    'sharing and workspace access operations route through the API seam',
    () async {
      final api = FakeApi();
      api.notes['n1'] = Note(
        id: 'n1',
        workspaceId: 'w-default',
        createdAt: now,
        updatedAt: now,
        collaborators: const [UserRef(id: 'u2', name: 'Two')],
      );
      final executor = PendingOperationExecutor(
        api: api,
        noteById: (id) => api.notes[id],
      );

      await executor.run(
        const PendingOp(
          PendingOpKind.workspaceViews,
          id: 'w-default',
          data: {'notesEnabled': false, 'boardEnabled': true},
        ),
      );
      await executor.run(
        const PendingOp(
          PendingOpKind.leaveWorkspace,
          id: 'w-default',
          data: {'userId': 'u2'},
        ),
      );
      await executor.run(
        const PendingOp(
          PendingOpKind.removeCollaborator,
          id: 'n1',
          data: {'userId': 'u2'},
        ),
      );
      await executor.run(
        const PendingOp(PendingOpKind.deleteAttachment, id: 'a1'),
      );
      await executor.run(const PendingOp(PendingOpKind.transcribe, id: 'n1'));

      expect(
        api.log,
        containsAllInOrder([
          'updateWorkspaceViews:w-default:false:true',
          'removeWorkspaceMember:w-default:u2',
          'removeCollaborator:n1:u2',
          'deleteAttachment:a1',
          'transcribe:n1',
        ]),
      );
      expect(api.notes['n1']?.collaborators, isEmpty);
    },
  );
}
