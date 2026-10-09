import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/note_collection.dart';
import 'package:skippy/state/notes_cache_doc.dart';
import 'package:skippy/state/pending_operation.dart';
import 'package:skippy/state/sync_issue.dart';

void main() {
  test('a snapshot survives a JSON round trip', () {
    final now = DateTime.utc(2026, 10, 2);
    final doc = NotesCacheDoc(
      notes: [Note(id: 'n', title: 'Hello', createdAt: now, updatedAt: now)],
      labels: const [Label(id: 'l', name: 'Work')],
      stages: const [Stage(id: 's', name: 'Todo', collectionId: 'c')],
      checklistHistory: const {
        'n': ['milk'],
      },
      queue: const [
        PendingOp(PendingOpKind.patch, id: 'n', data: {'title': 'Hello'}),
      ],
      syncIssues: const [
        SyncIssue(PendingOp(PendingOpKind.delete, id: 'x'), 'gone', 404, null),
      ],
      serverUpdatedAt: const {'n': '2026-10-02T00:00:00.000Z'},
    );

    final json = jsonDecode(jsonEncode(doc.toJson())) as Map<String, dynamic>;
    final read = NotesCacheDoc.fromJson(json);

    expect(read.notes.single.title, 'Hello');
    expect(read.labels.single.name, 'Work');
    expect(read.stages.single.collectionId, 'c');
    expect(read.checklistHistory['n'], ['milk']);
    expect(read.queue.single.data, {'title': 'Hello'});
    expect(read.syncIssues.single.statusCode, 404);
    expect(read.serverUpdatedAt, {'n': '2026-10-02T00:00:00.000Z'});
  });

  test('an empty document reads as empty', () {
    final read = NotesCacheDoc.fromJson(const {});

    expect(read.notes, isEmpty);
    expect(read.queue, isEmpty);
  });

  test('navigation survives a JSON round trip', () {
    const doc = NavigationCacheDoc(
      activeWorkspaceId: 'w',
      collectionChoices: {'w': 'c'},
      workspaceViews: {'w': ViewSelection(NoteView.label, 'l')},
    );

    final json = jsonDecode(jsonEncode(doc.toJson())) as Map<String, dynamic>;
    final read = NavigationCacheDoc.fromJson(json);

    expect(read.activeWorkspaceId, 'w');
    expect(read.collectionChoices, {'w': 'c'});
    expect(read.workspaceViews['w']!.view, NoteView.label);
    expect(read.workspaceViews['w']!.labelId, 'l');
  });

  test('an unusable remembered view is dropped', () {
    final read = NavigationCacheDoc.fromJson({
      'workspace_views': {
        'w': {'view': 'label'},
        'v': {'view': 'no-such-view'},
      },
    });

    // A label view without a label, or an unknown view, is dropped.
    expect(read.workspaceViews, isEmpty);
  });
}
