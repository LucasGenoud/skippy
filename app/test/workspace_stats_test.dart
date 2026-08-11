import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/util/workspace_stats.dart';

/// Fixed "now", so the 12-month activity window never shifts under the tests.
final now = DateTime(2026, 8, 11, 10);

Note note(
  String id, {
  NoteKind kind = NoteKind.text,
  List<ChecklistItem> items = const [],
  bool pinned = false,
  bool archived = false,
  bool trashed = false,
  DateTime? reminderAt,
  Set<String> labelIds = const {},
  String? stageId,
  UserRef? owner,
  List<Attachment> attachments = const [],
  DateTime? createdAt,
  DateTime? updatedAt,
}) => Note(
  id: id,
  kind: kind,
  items: items,
  pinned: pinned,
  archived: archived,
  trashed: trashed,
  reminderAt: reminderAt,
  labelIds: labelIds,
  stageId: stageId,
  owner: owner,
  attachments: attachments,
  createdAt: createdAt ?? now,
  updatedAt: updatedAt ?? createdAt ?? now,
);

ChecklistItem item(String text, {bool done = false}) =>
    ChecklistItem(id: text, text: text, done: done);

Label label(String id, {String? name}) =>
    Label(id: id, name: name ?? id, workspaceId: 'w');

Stage stage(String id, double position) =>
    Stage(id: id, name: id, workspaceId: 'w', position: position);

WorkspaceStats stats({
  List<Note> notes = const [],
  List<Label> labels = const [],
  List<Stage> stages = const [],
}) => computeWorkspaceStats(
  notes: notes,
  labels: labels,
  stages: stages,
  now: now,
);

void main() {
  test('an empty workspace counts nothing and says so', () {
    final s = stats();
    expect(s.isEmpty, isTrue);
    expect(s.activeNotes, 0);
    expect(s.firstCreated, isNull);
    expect(s.lastEdited, isNull);
    expect(s.checklistProgress, isNull);
    // The activity axis still spans the whole window.
    expect(s.monthlyCreated.length, kActivityMonths);
    expect(s.busiestMonth, 0);
  });

  test('headline counts split active, archived, and trashed', () {
    final s = stats(
      notes: [
        note('a'),
        note('b', pinned: true),
        note('c', archived: true),
        note('d', trashed: true),
        note('e', reminderAt: now),
      ],
    );
    expect(s.activeNotes, 3);
    expect(s.archived, 1);
    expect(s.trashed, 1);
    expect(s.pinned, 1);
    expect(s.withReminders, 1);
    // Archived notes still exist; trashed ones are out of the population.
    expect(s.liveNotes, 4);
    expect(s.isEmpty, isFalse);
  });

  test('trashed notes are excluded from every breakdown', () {
    final s = stats(
      notes: [
        note('keep', labelIds: {'l1'}, stageId: 's1'),
        note(
          'gone',
          kind: NoteKind.markdown,
          trashed: true,
          labelIds: {'l1'},
          stageId: 's1',
          items: [item('x', done: true)],
          attachments: const [
            Attachment(id: 'f', mime: 'image/png', size: 100),
          ],
        ),
      ],
      labels: [label('l1')],
      stages: [stage('s1', 0)],
    );
    expect(s.byKind.length, 1, reason: 'the trashed markdown note counted');
    expect(s.byKind.single.value, NoteKind.text);
    expect(s.topLabels.single.count, 1);
    expect(s.byStage.single.count, 1);
    expect(s.attachmentCount, 0);
    expect(s.checklistItems, 0);
  });

  test('kinds are ranked by how many notes carry them', () {
    final s = stats(
      notes: [
        note('a', kind: NoteKind.markdown),
        note('b', kind: NoteKind.checklist, items: [item('x')]),
        note('c', kind: NoteKind.checklist, items: [item('y')]),
        note('d', kind: NoteKind.checklist, items: [item('z')]),
        note('e', kind: NoteKind.markdown),
      ],
    );
    expect(s.byKind.first.value, NoteKind.checklist);
    expect(s.byKind.first.count, 3);
    expect(s.byKind.last.value, NoteKind.markdown);
    // Kinds nobody used are left out rather than shown as zero.
    expect(s.byKind.length, 2);
  });

  test('checklist totals count items, not lists, and spot finished ones', () {
    final s = stats(
      notes: [
        note(
          'groceries',
          kind: NoteKind.checklist,
          items: [item('milk', done: true), item('eggs')],
        ),
        note(
          'packing',
          kind: NoteKind.checklist,
          items: [item('socks', done: true), item('charger', done: true)],
        ),
        // An empty list is not a finished one.
        note('blank', kind: NoteKind.checklist),
        note('prose'),
      ],
    );
    expect(s.checklistItems, 4);
    expect(s.checklistDone, 3);
    expect(s.completedLists, 1);
    expect(s.checklistProgress, 0.75);
  });

  test('labels rank by use, unused ones are counted, and the list is capped', () {
    final labels = [for (var i = 0; i < 8; i++) label('l$i')];
    final s = stats(
      notes: [
        for (var i = 0; i < 6; i++)
          // l5 on every note, l4 on five of them, and so on down to l0 on one.
          note('n$i', labelIds: {for (var j = 0; j <= i; j++) 'l${5 - j}'}),
      ],
      labels: labels,
    );
    expect(s.labelCount, 8);
    expect(s.unusedLabels, 2, reason: 'l6 and l7 are on nothing');
    expect(s.topLabels.length, kTopLabels);
    expect(s.topLabels.first.value.id, 'l5');
    expect(s.topLabels.first.count, 6);
    // Descending, and the sixth-busiest label (l0, on one note) did not make
    // the cut.
    expect(s.topLabels.map((t) => t.count).toList(), [6, 5, 4, 3, 2]);
    expect(s.topLabels.map((t) => t.value.id), isNot(contains('l0')));
  });

  test('board columns keep their order and unassigned notes go last', () {
    final s = stats(
      notes: [
        note('a', stageId: 'doing'),
        note('b', stageId: 'todo'),
        note('c', stageId: 'todo'),
        note('d'),
      ],
      stages: [stage('todo', 0), stage('doing', 1), stage('done', 2)],
    );
    expect(s.byStage.map((b) => b.value?.id).toList(), [
      'todo',
      'doing',
      'done',
      null,
    ]);
    expect(s.byStage.map((b) => b.count).toList(), [2, 1, 0, 1]);
  });

  test('with no unassigned notes the bucket is left out entirely', () {
    final s = stats(
      notes: [note('a', stageId: 'todo')],
      stages: [stage('todo', 0)],
    );
    expect(s.byStage.length, 1);
    expect(s.byStage.single.value?.id, 'todo');
  });

  test('authors are only broken down once more than one person has written', () {
    const ada = UserRef(id: 'u1', name: 'Ada');
    const bob = UserRef(id: 'u2', name: 'Bob');
    final solo = stats(notes: [note('a', owner: ada), note('b', owner: ada)]);
    expect(solo.byAuthor, isEmpty);

    final shared = stats(
      notes: [note('a', owner: ada), note('b', owner: bob), note('c', owner: bob)],
    );
    expect(shared.byAuthor.first.value.name, 'Bob');
    expect(shared.byAuthor.first.count, 2);
    expect(shared.byAuthor.last.value.name, 'Ada');
  });

  test('attachments are counted, sized, and split by kind', () {
    final s = stats(
      notes: [
        note(
          'a',
          attachments: const [
            Attachment(id: '1', mime: 'image/png', size: 2000),
            Attachment(id: '2', mime: 'application/pdf', size: 500),
          ],
        ),
        note(
          'b',
          attachments: const [
            Attachment(id: '3', mime: 'audio/mp4', size: 1500),
          ],
        ),
      ],
    );
    expect(s.attachmentCount, 3);
    expect(s.attachmentBytes, 4000);
    expect(s.imageCount, 1);
    expect(s.audioCount, 1);
    expect(s.fileCount, 1);
  });

  test('activity buckets by month and spans a year boundary', () {
    final s = stats(
      notes: [
        note('now1', createdAt: DateTime(2026, 8, 2)),
        note('now2', createdAt: DateTime(2026, 8, 9)),
        // December of the previous year is inside a 12-month window ending in
        // August, so the bucket keys must not collapse to the month number.
        note('dec', createdAt: DateTime(2025, 12, 24)),
        // The oldest month still in range.
        note('sep', createdAt: DateTime(2025, 9, 3)),
        // Older than the window: counted everywhere else, but off the chart.
        note('old', createdAt: DateTime(2024, 5, 1)),
      ],
    );
    expect(s.monthlyCreated.length, kActivityMonths);
    expect(s.monthlyCreated.first.month, DateTime(2025, 9));
    expect(s.monthlyCreated.last.month, DateTime(2026, 8));
    expect(s.monthlyCreated.last.created, 2);
    final december = s.monthlyCreated.firstWhere(
      (m) => m.month == DateTime(2025, 12),
    );
    expect(december.created, 1);
    expect(s.monthlyCreated.first.created, 1);
    expect(s.busiestMonth, 2);
    // The out-of-window note still moves the "first note" stamp.
    expect(s.firstCreated, DateTime(2024, 5, 1));
    expect(s.monthlyCreated.fold<int>(0, (a, m) => a + m.created), 4);
  });

  test('first and last stamps track the extremes, not the list order', () {
    final s = stats(
      notes: [
        note('mid', createdAt: DateTime(2026, 3, 1), updatedAt: DateTime(2026, 3, 2)),
        note('old', createdAt: DateTime(2026, 1, 1), updatedAt: DateTime(2026, 1, 5)),
        note('new', createdAt: DateTime(2026, 5, 1), updatedAt: DateTime(2026, 7, 9)),
      ],
    );
    expect(s.firstCreated, DateTime(2026, 1, 1));
    expect(s.lastEdited, DateTime(2026, 7, 9));
  });

  test('byte sizes read the way a file manager reports them', () {
    expect(formatBytes(0), '0 bytes');
    expect(formatBytes(1), '1 byte');
    expect(formatBytes(999), '999 bytes');
    expect(formatBytes(1000), '1.0 kB');
    expect(formatBytes(812000), '812 kB');
    expect(formatBytes(2400000), '2.4 MB');
    expect(formatBytes(15000000), '15 MB');
    expect(formatBytes(3200000000), '3.2 GB');
  });
}
