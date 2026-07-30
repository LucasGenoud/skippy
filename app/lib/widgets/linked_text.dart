import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../util/linkify.dart';

/// Read-only text that renders URLs as tappable links (blue + underline) and
/// still tints search matches. A **long-press** on a link opens it, leaving a
/// normal tap to bubble up to any enclosing gesture (on a note card, the tap
/// opens the note). Used for note-card bodies.
///
/// Owns the per-URL [LongPressGestureRecognizer]s and disposes them, so it must
/// be a stateful widget, recognizers created inline in a build leak.
class LinkedText extends StatefulWidget {
  final String text;
  final String query;
  final TextStyle? style;
  final TextStyle? highlight;
  final int? maxLines;
  final TextOverflow overflow;

  /// Overridable open handler (tests inject a spy); defaults to launching the
  /// URL in the browser.
  final void Function(String url)? onOpen;

  const LinkedText({
    super.key,
    required this.text,
    this.query = '',
    this.style,
    this.highlight,
    this.maxLines,
    this.overflow = TextOverflow.clip,
    this.onOpen,
  });

  @override
  State<LinkedText> createState() => _LinkedTextState();
}

class _LinkedTextState extends State<LinkedText> {
  final Map<String, LongPressGestureRecognizer> _recognizers = {};

  @override
  void dispose() {
    for (final r in _recognizers.values) {
      r.dispose();
    }
    super.dispose();
  }

  GestureRecognizer _recognizerFor(UrlMatch match) {
    final open = widget.onOpen ?? launchLinkUrl;
    return _recognizers.putIfAbsent(match.url, LongPressGestureRecognizer.new)
      ..onLongPress = () => open(match.url);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final linkStyle = (widget.style ?? const TextStyle()).copyWith(
      color: scheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: scheme.primary,
    );

    // Drop recognizers for URLs that are no longer present.
    final live = findUrls(widget.text).map((u) => u.url).toSet();
    for (final gone
        in _recognizers.keys.where((k) => !live.contains(k)).toList()) {
      _recognizers.remove(gone)!.dispose();
    }

    final spans = buildLinkedSpans(
      text: widget.text,
      query: widget.query,
      linkStyle: linkStyle,
      highlight: widget.highlight,
      recognizerFor: _recognizerFor,
    );
    return Text.rich(
      TextSpan(children: spans),
      style: widget.style,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
  }
}
