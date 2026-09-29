import 'package:flutter/material.dart';

import 'note_link_spans.dart';

/// Read-only text that renders URLs as blue, underlined links and note links
/// as their titles, while preserving the enclosing widget's tap and long-press
/// behavior. Used for note-card bodies.
class LinkedText extends StatelessWidget {
  final String text;
  final String query;
  final TextStyle? style;
  final TextStyle? highlight;
  final int? maxLines;
  final TextOverflow overflow;

  /// A linked note's current title; the title stored in the link otherwise.
  final String? Function(String id)? noteTitleFor;

  const LinkedText({
    super.key,
    required this.text,
    this.query = '',
    this.style,
    this.highlight,
    this.maxLines,
    this.overflow = TextOverflow.clip,
    this.noteTitleFor,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final linkStyle = (style ?? const TextStyle()).copyWith(
      color: scheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: scheme.primary,
    );

    final spans = noteLinkedSpans(
      text: text,
      query: query,
      linkStyle: linkStyle,
      noteStyle: noteLinkStyle(scheme, style),
      highlight: highlight,
      display: NoteLinkDisplay.title,
      titleFor: noteTitleFor,
    );
    return Text.rich(
      TextSpan(children: spans),
      style: style,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}
