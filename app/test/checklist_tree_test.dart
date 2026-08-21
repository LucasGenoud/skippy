import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/checklist_tree.dart';

/// A list written as "depth:text", so the shape is legible in the test.
List<ChecklistItem> list(List<String> rows) => [
  for (var i = 0; i < rows.length; i++)
    ChecklistItem(
      id: 'i$i',
      // The "*" marks a checked row and is not part of its text, so a shape
      // written here reads back through [shape] unchanged.
      text: rows[i].split(':').last.replaceFirst('*', ''),
      depth: int.parse(rows[i].split(':').first),
      done: rows[i].contains('*'),
    ),
];

List<String> shape(List<ChecklistItem> items) => [
  for (final item in items) '${item.depth}:${item.done ? '*' : ''}${item.text}',
];

void main() {
  group('normalizing', () {
    test('keeps a legal shape and repairs an impossible one', () {
      final legal = list(['0:Trip', '1:Pack', '2:Socks', '1:Book', '0:Water']);
      expect(shape(normalizeDepths(legal)), shape(legal));

      // The first row has nothing to be a subtask of, and no row may be more
      // than one level below the one above it.
      expect(shape(normalizeDepths(list(['2:Trip', '2:Pack']))), [
        '0:Trip',
        '1:Pack',
      ]);
      expect(shape(normalizeDepths(list(['0:Trip', '2:Socks']))), [
        '0:Trip',
        '1:Socks',
      ]);
      expect(normalizeDepths(const []), isEmpty);
    });
  });

  group('subtrees', () {
    final trip = list(['0:Trip', '1:Pack', '2:Socks', '1:Book', '0:Water']);

    test('span every row below the root, and stop at the next peer', () {
      expect(subtreeEnd(trip, 0), 4);
      expect(subtreeEnd(trip, 1), 3);
      expect(subtreeEnd(trip, 2), 3);
      expect(subtreeEnd(trip, 4), 5);
      expect(hasSubtasks(trip, 0), isTrue);
      expect(hasSubtasks(trip, 2), isFalse);
      expect(rootIndexOf(trip, 2), 0);
      expect(rootIndexOf(trip, 4), 4);
    });
  });

  group('checking off', () {
    test('a task takes its subtasks with it, both ways', () {
      final trip = list(['0:Trip', '1:Pack', '2:Socks', '0:Water']);
      final done = setDoneCascading(trip, 'i0', true);
      expect(shape(done), ['0:*Trip', '1:*Pack', '2:*Socks', '0:Water']);
      expect(shape(setDoneCascading(done, 'i0', false)), shape(trip));
    });

    test('a subtask never finishes the task holding it', () {
      final trip = list(['0:Trip', '1:Pack', '2:Socks']);
      expect(shape(setDoneCascading(trip, 'i1', true)), [
        '0:Trip',
        '1:*Pack',
        '2:*Socks',
      ]);
    });

    test('an unfinished row is never filed away', () {
      // Whatever put it there, a row still to do belongs where it can be
      // seen: it is done and its task is done, or it stays in the list.
      final stray = list(['0:*Trip', '1:Pack']);
      expect(isFinished(stray, 1), isFalse);
    });

    test('only whole tasks move to the checked section', () {
      // A subtask ticked off under an open task stays where it is; nothing
      // moves until the task itself is done.
      final partly = list(['0:Trip', '1:*Pack', '0:Water']);
      expect(
        [for (var i = 0; i < 3; i++) isFinished(partly, i)],
        [false, false, false],
      );

      final finished = list(['0:*Trip', '1:*Pack', '0:Water']);
      expect(
        [for (var i = 0; i < 3; i++) isFinished(finished, i)],
        [true, true, false],
      );
    });
  });

  group('indenting', () {
    test('needs a row above it, and stops at the last level', () {
      final trip = list(['0:Trip', '1:Pack', '2:Socks']);
      // The first row can never be a subtask.
      expect(canShiftDepth(trip, 'i0', 1), isFalse);
      // Nor can a row go deeper than one level below its predecessor…
      expect(canShiftDepth(trip, 'i2', 1), isFalse);
      // …or past the last of the three levels.
      expect(canShiftDepth(list(['0:A', '1:B', '1:C']), 'i2', 1), isTrue);
      expect(canShiftDepth(trip, 'i0', -1), isFalse);
      expect(canShiftDepth(trip, 'i1', -1), isTrue);
    });

    test('carries the subtasks along', () {
      final trip = list(['0:Trip', '1:Pack', '2:Socks', '0:Water']);
      expect(shape(shiftDepth(trip, 'i1', -1)), [
        '0:Trip',
        '0:Pack',
        '1:Socks',
        '0:Water',
      ]);
      // Indenting a task that already reaches the last level is refused
      // rather than flattening its deepest subtask onto its parent.
      expect(shape(shiftDepth(trip, 'i0', 1)), shape(trip));
      final shallow = list(['0:Trip', '0:Pack', '1:Socks']);
      expect(shape(shiftDepth(shallow, 'i1', 1)), [
        '0:Trip',
        '1:Pack',
        '2:Socks',
      ]);
    });
  });

  group('removing', () {
    test('promotes what was under the row rather than deleting it', () {
      // One tap with no confirmation behind it must not take four subtasks.
      final trip = list(['0:Trip', '1:Pack', '2:Socks', '1:Book', '0:Water']);
      expect(shape(removeItem(trip, 'i0')), [
        '0:Pack',
        '1:Socks',
        '0:Book',
        '0:Water',
      ]);
      expect(shape(removeItem(trip, 'i1')), [
        '0:Trip',
        '1:Socks',
        '1:Book',
        '0:Water',
      ]);
      expect(shape(removeItem(trip, 'nope')), shape(trip));
    });
  });

  group('indenting past what is filed away', () {
    test('a row cannot be nested under a task that is done', () {
      // Checking the task above sends it to the checked section, so on
      // screen there is nothing left for this row to nest under. Indenting
      // it used to make it a subtask of the finished task and take it down
      // there too.
      final rows = list(['0:*Trip', '0:Water']);
      expect(canShiftDepth(rows, 'i1', 1), isFalse);
      expect(shape(shiftDepth(rows, 'i1', 1)), ['0:*Trip', '0:Water']);
    });

    test('it nests under the row it is actually shown under', () {
      // The finished task sits between them in the array but not on screen,
      // so this indents under "Shop", where the user sees it.
      final rows = list(['0:Shop', '0:*Trip', '0:Water']);
      expect(canShiftDepth(rows, 'i2', 1), isTrue);
      // The row moves up past what was filed away, which changes nothing on
      // screen and everything about who its parent is.
      expect(shape(shiftDepth(rows, 'i2', 1)), [
        '0:Shop',
        '1:Water',
        '0:*Trip',
      ]);
    });

    test('a finished row still indents inside the checked section', () {
      final rows = list(['0:*Trip', '0:*Pack', '0:Water']);
      expect(shape(shiftDepth(rows, 'i1', 1)), [
        '0:*Trip',
        '1:*Pack',
        '0:Water',
      ]);
    });
  });

  group('moving', () {
    test('takes the subtree and lands somewhere drawable', () {
      final trip = list(['0:Trip', '1:Pack', '2:Socks', '0:Water']);
      // The task and everything under it move as one block.
      expect(shape(moveSubtree(trip, 'i0', 1)), [
        '0:Water',
        '0:Trip',
        '1:Pack',
        '2:Socks',
      ]);
      // A subtask dragged to the top has nothing to be a subtask of, so it
      // comes up a level instead of dangling.
      expect(shape(moveSubtree(trip, 'i1', 0)), [
        '0:Pack',
        '1:Socks',
        '0:Trip',
        '0:Water',
      ]);
    });
  });
}
