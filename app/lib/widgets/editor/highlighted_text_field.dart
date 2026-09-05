import 'package:flutter/material.dart';

import '../../util/linkify.dart';
import '../paste_files.dart';

/// The editor's body controller. On top of plain editing it does two things in
/// [buildTextSpan]: styles URLs as blue underlined links and tints find-in-note
/// matches when [query] is set. Folding both into the real editing controller
/// keeps the field fully editable, including its default long-press behavior;
/// a proxy read-only overlay isn't needed.
class LinkifyingController extends TextEditingController {
  LinkifyingController({super.text});

  /// Find-in-note query; matches get highlighted on the next repaint. Does
  /// NOT notify listeners: it's set from [HighlightedTextField.build], and the
  /// enclosing field always rebuilds (the find bar setState drives it) so
  /// [buildTextSpan] re-runs with the new query. Notifying here instead would
  /// fire the editor's text listener mid-build (query is not a text change).
  String query = '';

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

    final spans = buildLinkedSpans(
      text: text,
      query: query,
      linkStyle: linkStyle,
      highlight: query.isEmpty ? null : highlight,
    );
    return TextSpan(style: style, children: spans);
  }
}

/// An editable Markdown source controller that applies lightweight visual
/// structure without hiding or rewriting any Markdown characters. Keeping the
/// source visible means selection offsets, IME composition, undo and the
/// persisted note all continue to speak the same plain-text format.
class MarkdownEditingController extends LinkifyingController {
  bool markdownEnabled;

  MarkdownEditingController({super.text, this.markdownEnabled = true});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (!markdownEnabled) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final ranges = <_MarkdownStyleRange>[];
    final markerStyle = TextStyle(
      color: scheme.primary.withValues(alpha: 0.78),
      fontWeight: FontWeight.w600,
    );

    void addMatch(RegExp pattern, TextStyle matchStyle, {int group = 0}) {
      for (final match in pattern.allMatches(text)) {
        final matchedText = match.group(group);
        if (matchedText == null) continue;
        final relativeStart = group == 0
            ? 0
            : match.group(0)!.indexOf(matchedText);
        final start = match.start + relativeStart;
        final end = start + matchedText.length;
        if (start >= 0 && end > start) {
          ranges.add(_MarkdownStyleRange(start, end, matchStyle));
        }
      }
    }

    for (final match in RegExp(
      r'^(#{1,6})([ \t]+)(.*)$',
      multiLine: true,
    ).allMatches(text)) {
      final level = match.group(1)!.length;
      final headingTextStart = match.start + level + match.group(2)!.length;
      ranges.add(
        _MarkdownStyleRange(match.start, headingTextStart, markerStyle),
      );
      if (headingTextStart < match.end) {
        ranges.add(
          _MarkdownStyleRange(
            headingTextStart,
            match.end,
            TextStyle(
              fontSize: switch (level) {
                1 => 23,
                2 => 20,
                3 => 18,
                _ => 16,
              },
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
        );
      }
    }

    addMatch(
      RegExp(r'^\s*(?:[-+*]|\d+\.|>|-\s*\[[ xX]\])\s+', multiLine: true),
      markerStyle,
    );
    addMatch(RegExp(r'\*\*([^\n*]+)\*\*'), markerStyle, group: 0);
    addMatch(
      RegExp(r'\*\*([^\n*]+)\*\*'),
      const TextStyle(fontWeight: FontWeight.w700),
      group: 1,
    );
    addMatch(RegExp(r'__([^\n_]+)__'), markerStyle, group: 0);
    addMatch(
      RegExp(r'__([^\n_]+)__'),
      const TextStyle(fontWeight: FontWeight.w700),
      group: 1,
    );
    addMatch(
      RegExp(r'~~([^\n~]+)~~'),
      const TextStyle(decoration: TextDecoration.lineThrough),
      group: 1,
    );
    addMatch(
      RegExp(r'`([^`\n]+)`'),
      TextStyle(
        fontFamily: 'monospace',
        backgroundColor: scheme.surfaceContainerHighest,
        color: scheme.onSurface,
      ),
      group: 1,
    );
    addMatch(
      RegExp(r'(?<!\*)\*([^*\n]+)\*(?!\*)'),
      const TextStyle(fontStyle: FontStyle.italic),
      group: 1,
    );
    addMatch(
      RegExp(r'(?<!_)_([^_\n]+)_(?!_)'),
      const TextStyle(fontStyle: FontStyle.italic),
      group: 1,
    );

    for (final match in RegExp(
      r'\[([^\]\n]+)\]\(([^)\n]+)\)',
    ).allMatches(text)) {
      final labelStart = match.start + 1;
      final urlStart = labelStart + match.group(1)!.length + 2;
      ranges.add(
        _MarkdownStyleRange(
          labelStart,
          labelStart + match.group(1)!.length,
          TextStyle(
            color: scheme.primary,
            decoration: TextDecoration.underline,
            decorationColor: scheme.primary,
          ),
        ),
      );
      ranges.add(
        _MarkdownStyleRange(
          urlStart,
          urlStart + match.group(2)!.length,
          TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    for (final url in findUrls(text)) {
      ranges.add(
        _MarkdownStyleRange(
          url.start,
          url.end,
          TextStyle(
            color: scheme.primary,
            decoration: TextDecoration.underline,
            decorationColor: scheme.primary,
          ),
        ),
      );
    }

    final query = this.query.trim();
    if (query.isNotEmpty) {
      final source = text.toLowerCase();
      final needle = query.toLowerCase();
      var start = 0;
      while ((start = source.indexOf(needle, start)) >= 0) {
        ranges.add(
          _MarkdownStyleRange(
            start,
            start + needle.length,
            TextStyle(
              backgroundColor: scheme.tertiaryContainer,
              color: scheme.onTertiaryContainer,
            ),
          ),
        );
        start += needle.length;
      }
    }
    if (withComposing &&
        value.composing.isValid &&
        !value.composing.isCollapsed) {
      ranges.add(
        _MarkdownStyleRange(
          value.composing.start,
          value.composing.end,
          const TextStyle(decoration: TextDecoration.underline),
        ),
      );
    }

    if (ranges.isEmpty || text.isEmpty) {
      return TextSpan(style: style, text: text);
    }
    final boundaries = <int>{0, text.length};
    for (final range in ranges) {
      boundaries
        ..add(range.start.clamp(0, text.length))
        ..add(range.end.clamp(0, text.length));
    }
    final points = boundaries.toList()..sort();
    final spans = <InlineSpan>[];
    for (var i = 0; i < points.length - 1; i++) {
      final start = points[i];
      final end = points[i + 1];
      if (start == end) continue;
      TextStyle? segmentStyle;
      for (final range in ranges) {
        if (range.start <= start && range.end >= end) {
          segmentStyle = segmentStyle?.merge(range.style) ?? range.style;
        }
      }
      spans.add(
        TextSpan(text: text.substring(start, end), style: segmentStyle),
      );
    }
    return TextSpan(style: style, children: spans);
  }
}

class _MarkdownStyleRange {
  final int start;
  final int end;
  final TextStyle style;

  const _MarkdownStyleRange(this.start, this.end, this.style);
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
    if (controller case final MarkdownEditingController markdownController) {
      markdownController.markdownEnabled = monospace;
    }
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
      // The body of a note is prose. Flutter's default (`none`) actively
      // turns the keyboard's own capitalization off.
      textCapitalization: TextCapitalization.sentences,
      // An image committed by the keyboard (Gboard's clipboard panel) attaches
      // to the note instead of being refused; null outside a PasteFileArea.
      contentInsertionConfiguration: PasteFileArea.insertionOf(context),
      style: style,
      decoration: const InputDecoration(
        hintText: 'Note',
        border: InputBorder.none,
      ),
    );
  }
}
