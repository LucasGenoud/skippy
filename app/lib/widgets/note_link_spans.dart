import 'package:flutter/material.dart';

import '../state/note_links.dart';
import '../util/linkify.dart';

/// How a `[[id|Title]]` link is drawn.
enum NoteLinkDisplay {
  /// Read-only text: the token is replaced by the note's title.
  title,

  /// Editable source: the token stays in the text so offsets keep matching,
  /// but everything except the title is drawn at zero size.
  source,
}

/// Collapses the id and brackets of a link in an editable field. A near-zero
/// size rather than zero, which some text engines refuse.
const TextStyle kHiddenLinkStyle = TextStyle(
  fontSize: 0.01,
  letterSpacing: 0,
  color: Colors.transparent,
);

/// How a note link reads: the accent, without the underline a web URL gets.
TextStyle noteLinkStyle(ColorScheme scheme, TextStyle? base) =>
    (base ?? const TextStyle()).copyWith(
      color: scheme.primary,
      fontWeight: FontWeight.w600,
    );

/// [buildLinkedSpans] plus note links, drawn as [display] says.
/// [titleFor] supplies a linked note's current title in [NoteLinkDisplay.title].
List<InlineSpan> noteLinkedSpans({
  required String text,
  required String query,
  required TextStyle? linkStyle,
  required TextStyle? noteStyle,
  required TextStyle? highlight,
  required NoteLinkDisplay display,
  String? Function(String id)? titleFor,
}) {
  final links = findNoteLinks(text);
  if (links.isEmpty) {
    return buildLinkedSpans(
      text: text,
      query: query,
      linkStyle: linkStyle,
      highlight: highlight,
    );
  }

  List<InlineSpan> plain(String part) => buildLinkedSpans(
    text: part,
    query: query,
    linkStyle: linkStyle,
    highlight: highlight,
  );

  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final link in links) {
    if (link.start > cursor) {
      spans.addAll(plain(text.substring(cursor, link.start)));
    }
    switch (display) {
      case NoteLinkDisplay.title:
        spans.add(
          TextSpan(
            text: titleFor?.call(link.noteId) ?? link.title,
            style: noteStyle,
          ),
        );
      case NoteLinkDisplay.source:
        spans
          ..add(
            TextSpan(
              text: text.substring(link.start, link.titleStart),
              style: kHiddenLinkStyle,
            ),
          )
          ..add(TextSpan(text: link.title, style: noteStyle))
          ..add(
            TextSpan(
              text: text.substring(link.titleEnd, link.end),
              style: kHiddenLinkStyle,
            ),
          );
    }
    cursor = link.end;
  }
  if (cursor < text.length) {
    spans.addAll(plain(text.substring(cursor)));
  }
  return spans;
}
