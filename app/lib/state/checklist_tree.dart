/// Pure rules for the shape of a nested checklist.
///
/// A checklist is a flat list whose rows carry a [ChecklistItem.depth], so
/// every rule about parents and children is arithmetic over a sequence rather
/// than a tree walk. Keeping them here, away from the widget, is what makes
/// "checking a task checks its subtasks" and "a subtask cannot outlive its
/// task" testable without pumping a frame.
library;

import '../models/note.dart';

/// The deepest [items] `[index]` may legally sit, given what is above it: one
/// level below its predecessor, never past [kMaxItemDepth], and always 0 for
/// the first row, which has nothing to be a subtask of.
int maxDepthAt(List<ChecklistItem> items, int index) {
  if (index <= 0) return 0;
  final above = items[index - 1].depth;
  return above + 1 > kMaxItemDepth ? kMaxItemDepth : above + 1;
}

/// [items] with every depth pulled into a shape that can be drawn, mirroring
/// the backend's `normalize_item_depths`. A row deeper than its predecessor
/// allows comes up to the deepest level that still has a parent rather than
/// being dropped: it is a row the user wrote, only its indentation is wrong.
List<ChecklistItem> normalizeDepths(List<ChecklistItem> items) {
  final result = <ChecklistItem>[];
  for (var i = 0; i < items.length; i++) {
    final ceiling = i == 0 ? 0 : maxDepthAt(result, i);
    final item = items[i];
    result.add(item.depth > ceiling ? item.copyWith(depth: ceiling) : item);
  }
  return result;
}

/// One past the last row belonging to the subtree rooted at [index]: every
/// following row deeper than it, stopping at the first that is not.
int subtreeEnd(List<ChecklistItem> items, int index) {
  final depth = items[index].depth;
  var end = index + 1;
  while (end < items.length && items[end].depth > depth) {
    end++;
  }
  return end;
}

/// Whether the row at [index] has anything nested under it.
bool hasSubtasks(List<ChecklistItem> items, int index) =>
    subtreeEnd(items, index) > index + 1;

/// The top-level row the one at [index] belongs to (itself, when it is one).
int rootIndexOf(List<ChecklistItem> items, int index) {
  var i = index;
  while (i > 0 && items[i].depth > 0) {
    i--;
  }
  return i;
}

/// Whether the row at [index] belongs in the collapsed "checked" section.
///
/// Only whole subtrees go down there: the row has to be done *and* so does the
/// task holding it. A subtask ticked off under a task that is still open stays
/// where it is, struck through, so it never loses the thing it belongs to, and
/// a row that is not done cannot be filed away at all, whatever is above it in
/// the list. Since checking a task checks everything under it, a done task
/// always takes its whole subtree along.
bool isFinished(List<ChecklistItem> items, int index) =>
    items[index].done && items[rootIndexOf(items, index)].done;

/// Set a row's checkbox, carrying its subtasks with it.
///
/// Both directions: closing a task closes what is under it, and reopening it
/// reopens them, so the gesture is reversible by repeating it. Ticking a
/// subtask never touches its parent, a task is not finished because one part
/// of it is.
List<ChecklistItem> setDoneCascading(
  List<ChecklistItem> items,
  String itemId,
  bool done,
) {
  final index = items.indexWhere((item) => item.id == itemId);
  if (index < 0) return items;
  final end = subtreeEnd(items, index);
  return [
    for (var i = 0; i < items.length; i++)
      if (i >= index && i < end) items[i].copyWith(done: done) else items[i],
  ];
}

/// The row shown directly above [index], which is not always the one before
/// it in the list: a finished task and its subtasks are drawn down in the
/// checked section, so for a row still in play they are not there at all.
/// Null when the row is the first of its section.
int? viewPredecessor(List<ChecklistItem> items, int index) {
  final finished = isFinished(items, index);
  for (var i = index - 1; i >= 0; i--) {
    if (isFinished(items, i) == finished) return i;
  }
  return null;
}

/// The deepest [index] may sit, judged by what is drawn above it rather than
/// by what precedes it in the list.
///
/// This is the interactive counterpart of [maxDepthAt], which stays the
/// storage rule. Indenting is something a person does to what they can see:
/// nesting a row under a task that has been checked off and filed away would
/// take the row down there with it, which is not what dragging a row sideways
/// asks for.
int maxDepthInView(List<ChecklistItem> items, int index) {
  final above = viewPredecessor(items, index);
  if (above == null) return 0;
  final ceiling = items[above].depth + 1;
  return ceiling > kMaxItemDepth ? kMaxItemDepth : ceiling;
}

/// [items] with the subtree at [index] lifted over any finished rows that sit
/// between it and the row it is drawn under.
///
/// Invisible on screen, since those rows are drawn elsewhere: it only makes
/// the list agree with the picture, so that indenting the row nests it under
/// the task it appears to follow instead of the one that was checked off.
List<ChecklistItem> _closeGapAbove(List<ChecklistItem> items, int index) {
  final above = viewPredecessor(items, index);
  if (above == null || above == index - 1) return items;
  final end = subtreeEnd(items, index);
  final block = items.sublist(index, end);
  final rest = [...items]..removeRange(index, end);
  return [...rest.sublist(0, above + 1), ...block, ...rest.sublist(above + 1)];
}

/// How far the deepest row of a subtree sits below its root.
int _subtreeSpan(List<ChecklistItem> items, int index) {
  final end = subtreeEnd(items, index);
  var deepest = items[index].depth;
  for (var i = index + 1; i < end; i++) {
    if (items[i].depth > deepest) deepest = items[i].depth;
  }
  return deepest - items[index].depth;
}

/// Whether the row can move one level in [delta]'s direction, subtasks and
/// all.
///
/// Judged against the row above it *on screen*: the first row of what is
/// still to do cannot be indented, however many finished tasks sit above it
/// in the list. Indenting is also refused when it would push a subtask past
/// the last level, rather than silently flattening two rows onto one.
bool canShiftDepth(List<ChecklistItem> items, String itemId, int delta) {
  final index = items.indexWhere((item) => item.id == itemId);
  if (index < 0 || delta == 0) return false;
  final item = items[index];
  final target = item.depth + delta;
  if (target < 0 || target > maxDepthInView(items, index)) return false;
  return target + _subtreeSpan(items, index) <= kMaxItemDepth;
}

/// Move a row one level in or out, taking its subtasks with it so the shape
/// under it is preserved. A move that is not allowed returns [items] as-is.
List<ChecklistItem> shiftDepth(
  List<ChecklistItem> items,
  String itemId,
  int delta,
) {
  if (!canShiftDepth(items, itemId, delta)) return items;
  // Close the gap first, so the row ends up nested under the task it is drawn
  // under rather than under a finished one that only precedes it in the list.
  final closed = _closeGapAbove(
    items,
    items.indexWhere((item) => item.id == itemId),
  );
  final index = closed.indexWhere((item) => item.id == itemId);
  final end = subtreeEnd(closed, index);
  return [
    for (var i = 0; i < closed.length; i++)
      if (i >= index && i < end)
        closed[i].copyWith(depth: closed[i].depth + delta)
      else
        closed[i],
  ];
}

/// Remove one row, promoting whatever was nested under it.
///
/// Deliberately not a subtree delete: the remove button is one tap with no
/// confirmation behind it, and losing four subtasks to it would be a bad
/// surprise. The subtasks come up a level and keep their own shape.
List<ChecklistItem> removeItem(List<ChecklistItem> items, String itemId) {
  final index = items.indexWhere((item) => item.id == itemId);
  if (index < 0) return items;
  final end = subtreeEnd(items, index);
  return normalizeDepths([
    for (var i = 0; i < items.length; i++)
      if (i != index)
        if (i > index && i < end)
          items[i].copyWith(depth: items[i].depth - 1)
        else
          items[i],
  ]);
}

/// Move the subtree rooted at [itemId] so that it starts at [to], counted
/// over the list with that subtree taken out. Depths are normalized after the
/// move, so a subtask dropped where nothing can parent it comes up a level
/// instead of dangling.
List<ChecklistItem> moveSubtree(
  List<ChecklistItem> items,
  String itemId,
  int to,
) {
  final index = items.indexWhere((item) => item.id == itemId);
  if (index < 0) return items;
  final end = subtreeEnd(items, index);
  final block = items.sublist(index, end);
  final rest = [...items]..removeRange(index, end);
  final target = to.clamp(0, rest.length);
  return normalizeDepths([
    ...rest.sublist(0, target),
    ...block,
    ...rest.sublist(target),
  ]);
}

/// Reopen [itemId] and bring it back to where it is being written, instead of
/// to the place it was checked off in.
///
/// Re-adding an item from the history popup is writing it again: it belongs
/// under the row it was written under ([after]), or at the end of the list
/// where the composer sits when there is none, rather than pages up wherever
/// it happened to be ticked off weeks ago. It lands at the depth that
/// position continues, the same rule a freshly typed row follows, and
/// whatever was nested under it comes back with it, keeping its own shape.
List<ChecklistItem> reopenWhereWritten(
  List<ChecklistItem> items,
  String itemId, {
  String? after,
}) {
  final index = items.indexWhere((item) => item.id == itemId);
  if (index < 0) return items;
  final reopened = setDoneCascading(items, itemId, false);
  final end = subtreeEnd(reopened, index);
  final block = reopened.sublist(index, end);
  final rest = [...reopened]..removeRange(index, end);
  // Under the whole of [after], subtasks included: a row written under a task
  // goes after that task, not between it and its parts.
  final anchor = after == null ? -1 : rest.indexWhere((i) => i.id == after);
  final to = anchor < 0 ? rest.length : subtreeEnd(rest, anchor);
  final depth = anchor >= 0
      ? rest[anchor].depth
      : (rest.isEmpty ? 0 : rest.last.depth);
  final shift = depth - block.first.depth;
  return normalizeDepths([
    ...rest.sublist(0, to),
    for (final item in block)
      item.copyWith(depth: (item.depth + shift).clamp(0, kMaxItemDepth)),
    ...rest.sublist(to),
  ]);
}
