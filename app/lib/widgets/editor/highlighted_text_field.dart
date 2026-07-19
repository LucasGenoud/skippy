import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../util/linkify.dart';

/// The editor's body controller. On top of plain editing it does two things in
/// [buildTextSpan]: styles URLs as blue underlined links with a long-press
/// recognizer that opens them, and tints find-in-note matches when [query] is
/// set. Folding both into the real editing controller keeps the field fully
/// editable (a normal tap still places the caret) — a proxy read-only overlay
/// isn't needed.
class LinkifyingController extends TextEditingController {
  final void Function(String url) onOpenUrl;
  final Map<String, LongPressGestureRecognizer> _recognizers = {};
  String _query = '';

  LinkifyingController({super.text, required this.onOpenUrl});

  /// Find-in-note query; matches get highlighted on the next repaint. Does
  /// NOT notify listeners: it's set from [HighlightedTextField.build], and the
  /// enclosing field always rebuilds (the find bar setState drives it) so
  /// [buildTextSpan] re-runs with the new query. Notifying here instead would
  /// fire the editor's text listener mid-build (query is not a text change).
  set query(String q) => _query = q;

  @override
  void dispose() {
    for (final r in _recognizers.values) {
      r.dispose();
    }
    _recognizers.clear();
    super.dispose();
  }

  GestureRecognizer _recognizerFor(UrlMatch match) {
    return _recognizers.putIfAbsent(match.url, LongPressGestureRecognizer.new)
      ..onLongPress = () => onOpenUrl(match.url);
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final linkStyle = (style ?? const TextStyle()).copyWith(
      color: scheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: scheme.primary,
    );
    final highlight = (style ?? const TextStyle()).copyWith(
      backgroundColor: scheme.tertiaryContainer,
      color: scheme.onTertiaryContainer,
    );

    // Drop recognizers for URLs no longer in the text.
    final live = findUrls(text).map((u) => u.url).toSet();
    for (final gone in _recognizers.keys.where((k) => !live.contains(k)).toList()) {
      _recognizers.remove(gone)!.dispose();
    }

    final spans = buildLinkedSpans(
      text: text,
      query: _query,
      linkStyle: linkStyle,
      highlight: _query.isEmpty ? null : highlight,
      recognizerFor: _recognizerFor,
    );
    return TextSpan(style: style, children: spans);
  }
}

/// Editor body field backed by a [LinkifyingController]: renders links and
/// find-in-note highlights. Editing pauses (read-only) while the find bar is
/// open, matching the old behavior.
class HighlightedTextField extends StatelessWidget {
  final LinkifyingController controller;
  final FocusNode focusNode;
  final bool readOnly;
  final bool autofocus;
  final bool monospace;
  final String query;

  const HighlightedTextField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.readOnly,
    required this.query,
    this.autofocus = false,
    this.monospace = false,
  });

  @override
  Widget build(BuildContext context) {
    controller.query = query;
    final finding = query.isNotEmpty;
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyLarge?.copyWith(
      height: 1.5,
      fontFamily: monospace ? 'monospace' : null,
      fontSize: monospace ? 14 : null,
    );
    return TextField(
      controller: controller,
      focusNode: focusNode,
      // Editing pauses while the find bar is open, and stays off in Trash.
      readOnly: readOnly || finding,
      enabled: !readOnly,
      maxLines: null,
      minLines: 6,
      autofocus: autofocus,
      style: style,
      decoration: const InputDecoration(
        hintText: 'Note',
        border: InputBorder.none,
      ),
    );
  }
}
