import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/board_layout.dart';
import 'package:skippy/state/note_collection.dart';

Note note(
  String id, {
  String? stageId,
  double stagePosition = 0,
  bool pinned = false,
  bool archived = false,
  bool trashed = false,
  String workspaceId = 'w1',
  String title = '',
  Set<String> labelIds = const {},
}) {
  final now = DateTime(2026, 7, 27);
  return Note(
    id: id,
    workspaceId: workspaceId,
    title: title,
    stageId: stageId,
    stagePosition: stagePosition,
    pinned: pinned,
    archived: archived,
    trashed: trashed,
    labelIds: labelIds,
    createdAt: now,
    updatedAt: now,
  );
}

Stage stage(String id, double position) =>
    Stage(id: id, name: id, workspaceId: 'w1', position: position);

void main() {
  group('buildBoard', () {
    test('columns follow stage position, unassigned first', () {
      final board = buildBoard(
        notes: const [],
        stages: [stage('done', 3072), stage('todo', 1024), stage('doing', 2048)],
      );
      expect(
        board.columns.map((c) => c.title),
        ['Unassigned', 'todo', 'doing', 'done'],
      );
    });

    test('groups notes by stage and orders them by stage position', () {
      final board = buildBoard(
        notes: [
          note('c', stageId: 'todo', stagePosition: 3072),
          note('a', stageId: 'todo', stagePosition: 1024),
          note('b', stageId: 'todo', stagePosition: 2048),
          note('loose'),
        ],
        stages: [stage('todo', 1024)],
      );
      expect(board.columns[0].notes.map((n) => n.id), ['loose']);
      expect(board.columns[1].notes.map((n) => n.id), ['a', 'b', 'c']);
    });

    test('pinned cards ride at the top of their column', () {
      final board = buildBoard(
        notes: [
          note('plain', stageId: 'todo', stagePosition: 1024),
          note('pinned', stageId: 'todo', stagePosition: 4096, pinned: true),
        ],
        stages: [stage('todo', 1024)],
      );
      expect(board.columns[1].notes.map((n) => n.id), ['pinned', 'plain']);
    });

    test('archived and trashed notes leave the board', () {
      final board = buildBoard(
        notes: [
          note('live', stageId: 'todo'),
          note('archived', stageId: 'todo', archived: true),
          note('trashed', stageId: 'todo', trashed: true),
        ],
        stages: [stage('todo', 1024)],
      );
      expect(board.columns[1].notes.map((n) => n.id), ['live']);
    });

    /// A stage the client hasn't caught up on, deleted by a teammate, or left
    /// behind by a workspace move, must not swallow the card.
    test('a note in an unknown stage falls back to unassigned', () {
      final board = buildBoard(
        notes: [note('orphan', stageId: 'deleted-elsewhere')],
        stages: [stage('todo', 1024)],
      );
      expect(board.columns[0].notes.map((n) => n.id), ['orphan']);
      expect(board.columns[1].notes, isEmpty);
    });

    test('only the open workspace is on the board', () {
      final board = buildBoard(
        notes: [
          note('mine', workspaceId: 'w1'),
          note('elsewhere', workspaceId: 'w2'),
        ],
        stages: [stage('todo', 1024)],
        scope: const WorkspaceScope(
          workspaceId: 'w1',
          isDefault: false,
          known: {'w1', 'w2'},
        ),
      );
      expect(board.columns[0].notes.map((n) => n.id), ['mine']);
    });

    test('search filters cards inside their columns', () {
      final board = buildBoard(
        notes: [
          note('hit', stageId: 'todo', title: 'buy milk'),
          note('miss', stageId: 'todo', title: 'call bank'),
        ],
        stages: [stage('todo', 1024)],
        query: 'MILK',
      );
      expect(board.columns[1].notes.map((n) => n.id), ['hit']);
    });

    group('unassigned cap', () {
      List<Note> manyNotes(int count) => [
        for (var i = 0; i < count; i++)
          note('n$i', stagePosition: i.toDouble()),
      ];

      test('holds back the overflow and reports it', () {
        final board = buildBoard(
          notes: manyNotes(kUnassignedPreviewLimit + 5),
          stages: const [],
        );
        final column = board.columns.first;
        expect(column.notes.length, kUnassignedPreviewLimit);
        expect(column.totalCount, kUnassignedPreviewLimit + 5);
        expect(column.hiddenCount, 5);
      });

      test('shows everything on request', () {
        final board = buildBoard(
          notes: manyNotes(kUnassignedPreviewLimit + 5),
          stages: const [],
          showAllUnassigned: true,
        );
        expect(board.columns.first.hiddenCount, 0);
      });

      test('leaves stage columns uncapped', () {
        final board = buildBoard(
          notes: [
            for (var i = 0; i < kUnassignedPreviewLimit + 5; i++)
              note('n$i', stageId: 'todo', stagePosition: i.toDouble()),
          ],
          stages: [stage('todo', 1024)],
        );
        expect(board.columns[1].notes.length, kUnassignedPreviewLimit + 5);
      });
    });

    test('a workspace with no stages has only the unassigned column', () {
      final board = buildBoard(notes: [note('a')], stages: const []);
      expect(board.hasNoStages, isTrue);
      expect(board.columns.length, 1);
    });

    group('board reorder positions', () {
      test('places a card at the head, tail, and between', () {
        final a = note('a', stagePosition: 1024);
        final b = note('b', stagePosition: 2048);
        final moved = note('moved', stagePosition: 4096);
        expect(
          boardPositionForInsertion(moved: moved, ordered: [moved]),
          1024.0,
        );
        expect(
          boardPositionForInsertion(moved: moved, ordered: [moved, a, b]),
          lessThan(a.stagePosition),
        );
        expect(
          boardPositionForInsertion(moved: moved, ordered: [a, b, moved]),
          greaterThan(b.stagePosition),
        );
        expect(
          boardPositionForInsertion(moved: moved, ordered: [a, moved, b]),
          1536.0,
        );
      });

      test('uses only the dragged card pinning group as neighbours', () {
        final pinned = note('p', stagePosition: 4096, pinned: true);
        final a = note('a', stagePosition: 1024);
        final b = note('b', stagePosition: 2048);

        expect(
          boardPositionForReorder(
            moved: b,
            before: [pinned, a, b],
            after: [pinned, b, a],
          ),
          lessThan(a.stagePosition),
        );
      });

      test('an incoming card uses the same pin-aware ordering policy', () {
        final incoming = note('incoming', stagePosition: 8192);
        final pinned = note('p', stagePosition: 4096, pinned: true);
        final plain = note('a', stagePosition: 1024);

        expect(
          boardPositionForInsertion(
            moved: incoming,
            ordered: [incoming, pinned, plain],
          ),
          lessThan(plain.stagePosition),
        );
      });

      test('crossing the pin boundary without moving a peer is a no-op', () {
        final pinned = note('p', stagePosition: 4096, pinned: true);
        final plain = note('a', stagePosition: 1024);

        expect(
          boardPositionForReorder(
            moved: plain,
            before: [pinned, plain],
            after: [plain, pinned],
          ),
          isNull,
        );
      });

      test('rejects an incomplete reordered group', () {
        final a = note('a', stagePosition: 1024);
        final b = note('b', stagePosition: 2048);
        expect(
          boardPositionForReorder(moved: b, before: [a, b], after: [b]),
          isNull,
        );
      });
    });

    /// Stages and labels are independent systems: a card's column is its stage
    /// and nothing else, whatever labels it happens to carry.
    test('labels have no bearing on which column a card lands in', () {
      final board = buildBoard(
        notes: [
          note('a', stageId: 'todo', labelIds: const {'work', 'urgent'}),
          note('b', labelIds: const {'todo'}),
        ],
        stages: [stage('todo', 1024)],
      );
      expect(board.columns[0].notes.map((n) => n.id), ['b']);
      expect(board.columns[1].notes.map((n) => n.id), ['a']);
    });
  });
}
