import 'package:flutter/material.dart';

import '../util/linkify.dart';

/// Read-only text that renders URLs as blue, underlined links while preserving
/// the enclosing widget's tap and long-press behavior. Used for note-card
/// bodies.
class LinkedText extends StatelessWidget {
  final String text;
  final String query;
  final TextStyle? style;
  final TextStyle? highlight;
  final int? maxLines;
  final TextOverflow overflow;

  const LinkedText({
    super.key,
    required this.text,
    this.query = '',
    this.style,
    this.highlight,
    this.maxLines,
    this.overflow = TextOverflow.clip,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final linkStyle = (style ?? const TextStyle()).copyWith(
      color: scheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: scheme.primary,
    );

    final spans = buildLinkedSpans(
      text: text,
      query: query,
      linkStyle: linkStyle,
      highlight: highlight,
    );
    return Text.rich(
      TextSpan(children: spans),
      style: style,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}
