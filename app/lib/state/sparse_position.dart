/// Ordered things (cards, columns, labels, collections, smart views) store a
/// sparse `position` rather than an index, so a move rewrites only the item
/// that moved:
///
/// ```text
///   1024     2048     3072          drop C between A and B
///    A        B        C       ->   A 1024, C 1536, B 2048
/// ```
library;

/// Spacing between neighbours placed at either end of a list.
const kPositionGap = 1024.0;

/// A position between [above] and [below], either of which may be absent at
/// an end of the list. [alone] is the answer when both are.
double positionBetween(
  double? above,
  double? below, {
  double alone = kPositionGap,
}) {
  if (above == null && below == null) {
    return alone;
  }
  if (above == null) {
    return below! - kPositionGap;
  }
  if (below == null) {
    return above + kPositionGap;
  }
  return (above + below) / 2;
}

/// The position for an item dropped at [index] among [others]: the positions
/// of the rest of the list, in order, without the moved item. That is the
/// index `ReorderableListView.onReorderItem` reports. [current] is kept when
/// there is nothing else to order against.
double positionAt(List<double> others, int index, {required double current}) {
  final slot = index.clamp(0, others.length);
  return positionBetween(
    slot > 0 ? others[slot - 1] : null,
    slot < others.length ? others[slot] : null,
    alone: current,
  );
}
