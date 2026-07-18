import 'package:flutter/material.dart';

/// Content field with find-in-note highlighting: matching substrings get a
/// tinted background while the search bar is open.
class HighlightedTextField extends StatefulWidget {
  final TextEditingController controller;
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
  State<HighlightedTextField> createState() => _HighlightedTextFieldState();
}

class _HighlightedTextFieldState extends State<HighlightedTextField> {
  _HighlightingController? _highlighting;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyLarge?.copyWith(
      height: 1.5,
      fontFamily: widget.monospace ? 'monospace' : null,
      fontSize: widget.monospace ? 14 : null,
    );

    if (widget.query.isEmpty) {
      _highlighting = null;
      return TextField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        readOnly: widget.readOnly,
        enabled: !widget.readOnly,
        maxLines: null,
        minLines: 6,
        autofocus: widget.autofocus,
        style: style,
        decoration: const InputDecoration(
          hintText: 'Note',
          border: InputBorder.none,
        ),
      );
    }

    // While searching, render through a proxy controller that shares the
    // real controller's value but paints highlights.
    _highlighting ??= _HighlightingController(widget.controller);
    _highlighting!.query = widget.query;
    return TextField(
      controller: _highlighting,
      readOnly: true, // editing pauses while the find bar is open
      maxLines: null,
      minLines: 6,
      style: style,
      decoration: const InputDecoration(
        hintText: 'Note',
        border: InputBorder.none,
      ),
    );
  }
}

class _HighlightingController extends TextEditingController {
  final TextEditingController source;
  String _query = '';

  _HighlightingController(this.source) : super(text: source.text) {
    source.addListener(_sync);
  }

  void _sync() => value = source.value;

  set query(String q) {
    if (q == _query) return;
    _query = q;
    notifyListeners();
  }

  @override
  void dispose() {
    source.removeListener(_sync);
    super.dispose();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final q = _query.toLowerCase();
    if (q.isEmpty || text.isEmpty) {
      return TextSpan(text: text, style: style);
    }
    final scheme = Theme.of(context).colorScheme;
    final highlight =
        style?.copyWith(
          backgroundColor: scheme.tertiaryContainer,
          color: scheme.onTertiaryContainer,
        ) ??
        TextStyle(backgroundColor: scheme.tertiaryContainer);
    final spans = <TextSpan>[];
    final lower = text.toLowerCase();
    var start = 0;
    while (true) {
      final index = lower.indexOf(q, start);
      if (index < 0) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (index > start) {
        spans.add(TextSpan(text: text.substring(start, index)));
      }
      spans.add(
        TextSpan(
          text: text.substring(index, index + q.length),
          style: highlight,
        ),
      );
      start = index + q.length;
      if (start >= text.length) break;
    }
    return TextSpan(style: style, children: spans);
  }
}
