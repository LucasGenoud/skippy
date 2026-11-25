import 'dart:math' as math;

/// Shortest query worth correcting: below this a single edit matches almost
/// anything.
const int _kMinFuzzyLength = 3;

/// Query length from which two edits are forgiven instead of one.
const int _kTwoEditLength = 6;

/// Checklist typing suggestions from [history], best first.
///
/// Prefix matches come first, then substring matches, then near matches: an
/// item a word of which starts with something a letter or two away from the
/// query, so "mlik" still offers "Milk". [history] is most-used first and
/// keeps that order within each tier. An empty query offers everything.
List<String> rankSuggestions(
  List<String> history,
  String query, {
  Set<String> exclude = const {},
}) {
  final q = query.trim().toLowerCase();
  final excluded = {for (final e in exclude) e.trim().toLowerCase()};
  final allowed = _allowedEdits(q.length);
  final prefix = <String>[];
  final contains = <String>[];
  final near = <({String text, int distance})>[];

  for (final text in history) {
    final lower = text.toLowerCase();
    if (excluded.contains(lower)) {
      continue;
    }

    if (q.isEmpty || lower.startsWith(q)) {
      prefix.add(text);
      continue;
    }
    if (lower.contains(q)) {
      contains.add(text);
      continue;
    }
    if (allowed == 0) {
      continue;
    }

    final distance = _wordPrefixDistance(lower, q, allowed);
    if (distance <= allowed) {
      near.add((text: text, distance: distance));
    }
  }

  // Stable: equal distances keep history order.
  final ranked = [for (var i = 0; i < near.length; i++) (i: i, hit: near[i])]
    ..sort((a, b) {
      final byDistance = a.hit.distance.compareTo(b.hit.distance);
      return byDistance != 0 ? byDistance : a.i.compareTo(b.i);
    });
  return [...prefix, ...contains, for (final r in ranked) r.hit.text];
}

int _allowedEdits(int length) {
  if (length < _kMinFuzzyLength) {
    return 0;
  }
  return length >= _kTwoEditLength ? 2 : 1;
}

/// The fewest edits turning [query] into the start of any word in [text].
///
/// "almnd" against "almond milk" compares it with "almo", "almon",
/// "almond", ... and with "milk": the best is one edit.
int _wordPrefixDistance(String text, String query, int allowed) {
  var best = allowed + 1;
  for (var start = 0; start < text.length; start++) {
    final isWordStart = start == 0 || text[start - 1] == ' ';
    if (!isWordStart || text[start] == ' ') {
      continue;
    }

    final int minEnd = start + math.max(1, query.length - allowed);
    final int maxEnd = math.min(text.length, start + query.length + allowed);
    for (var end = minEnd; end <= maxEnd; end++) {
      best = math.min(best, _editDistance(query, text.substring(start, end)));
    }
  }
  return best;
}

/// Optimal string alignment distance: insertions, deletions, substitutions,
/// and swapping two neighbours each cost one.
int _editDistance(String a, String b) {
  final rows = List.generate(
    a.length + 1,
    (i) =>
        List<int>.generate(b.length + 1, (j) => i == 0 ? j : (j == 0 ? i : 0)),
  );
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      var d = math.min(
        math.min(rows[i - 1][j] + 1, rows[i][j - 1] + 1),
        rows[i - 1][j - 1] + cost,
      );
      final swapped =
          i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1];
      if (swapped) {
        d = math.min(d, rows[i - 2][j - 2] + 1);
      }
      rows[i][j] = d;
    }
  }
  return rows[a.length][b.length];
}
