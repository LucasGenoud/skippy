import 'package:flutter/widgets.dart';

/// Splits [text] into spans with every (case-insensitive) occurrence of [query]
/// styled with [highlight]. Used to mark search matches in note cards.
/// Returns a single plain span when there's no query or no match, so callers
/// can always feed the result to [Text.rich].
List<InlineSpan> highlightSpans(
  String text,
  String query, {
  required TextStyle? highlight,
}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return [TextSpan(text: text)];

  final spans = <InlineSpan>[];
  final lower = text.toLowerCase();
  var start = 0;
  while (start < text.length) {
    final idx = lower.indexOf(q, start);
    if (idx < 0) {
      spans.add(TextSpan(text: text.substring(start)));
      break;
    }
    if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
    spans.add(
      TextSpan(text: text.substring(idx, idx + q.length), style: highlight),
    );
    start = idx + q.length;
  }
  return spans;
}
