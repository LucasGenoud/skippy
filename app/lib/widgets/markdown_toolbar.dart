import 'package:flutter/material.dart';

/// Formatting accessory bar for markdown notes: each button inserts the
/// matching markdown around the current selection (or at the caret), so
/// headings, bold, lists and links are one tap away instead of remembering
/// the syntax. Operates directly on the editor's [controller], so the change
/// flows through the note's normal autosave/undo path.
class MarkdownToolbar extends StatelessWidget {
  final TextEditingController controller;

  /// Refocused after a button runs so typing continues in the field.
  final FocusNode? focusNode;

  const MarkdownToolbar({super.key, required this.controller, this.focusNode});

  ({int start, int end}) _range() {
    final sel = controller.selection;
    final len = controller.text.length;
    if (!sel.isValid) return (start: len, end: len);
    return (start: sel.start, end: sel.end);
  }

  /// Wrap the selection in [left]/[right]; with no selection, drop the markers
  /// in and park the caret between them.
  void _wrap(String left, String right) {
    final text = controller.text;
    final (:start, :end) = _range();
    final selected = text.substring(start, end);
    final replaced = text.replaceRange(start, end, '$left$selected$right');
    final inner = start + left.length;
    controller.value = TextEditingValue(
      text: replaced,
      selection: selected.isEmpty
          ? TextSelection.collapsed(offset: inner)
          : TextSelection(
              baseOffset: inner,
              extentOffset: inner + selected.length,
            ),
    );
    focusNode?.requestFocus();
  }

  /// Rewrite every line the selection touches through [transform].
  void _lines(String Function(String line) transform) {
    final text = controller.text;
    final (:start, :end) = _range();
    final lineStart = start == 0 ? 0 : text.lastIndexOf('\n', start - 1) + 1;
    var lineEnd = text.indexOf('\n', end);
    if (lineEnd < 0) lineEnd = text.length;
    final rewritten = text
        .substring(lineStart, lineEnd)
        .split('\n')
        .map(transform)
        .join('\n');
    controller.value = TextEditingValue(
      text: text.replaceRange(lineStart, lineEnd, rewritten),
      selection: TextSelection.collapsed(offset: lineStart + rewritten.length),
    );
    focusNode?.requestFocus();
  }

  /// Set the heading level, replacing any heading marker already there so
  /// levels swap cleanly instead of stacking `# # `.
  String _heading(int level, String line) =>
      '${'#' * level} ${line.replaceFirst(RegExp(r'^#{1,6}\s*'), '')}';

  /// Add [marker] to the line, or strip it if it's already there (toggle).
  String _togglePrefix(String marker, String line) =>
      line.startsWith(marker) ? line.substring(marker.length) : '$marker$line';

  void _insertLink() {
    final text = controller.text;
    final (:start, :end) = _range();
    final label = start == end ? 'text' : text.substring(start, end);
    const url = 'url';
    final replaced = text.replaceRange(start, end, '[$label]($url)');
    // Select the "url" placeholder so the address is what you type next.
    final urlStart = start + label.length + 3; // past `[label](`
    controller.value = TextEditingValue(
      text: replaced,
      selection: TextSelection(
        baseOffset: urlStart,
        extentOffset: urlStart + url.length,
      ),
    );
    focusNode?.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget btn(String tooltip, Widget icon, VoidCallback onTap) => IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      color: scheme.onSurfaceVariant,
      icon: icon,
    );

    Widget heading(int level) => btn(
      'Heading $level',
      Text(
        'H$level',
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 15,
          color: scheme.onSurfaceVariant,
        ),
      ),
      () => _lines((line) => _heading(level, line)),
    );

    return Container(
      height: 44,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        children: [
          heading(1),
          heading(2),
          heading(3),
          btn('Bold', const Icon(Icons.format_bold), () => _wrap('**', '**')),
          btn('Italic', const Icon(Icons.format_italic), () => _wrap('_', '_')),
          btn(
            'Strikethrough',
            const Icon(Icons.format_strikethrough),
            () => _wrap('~~', '~~'),
          ),
          btn('Inline code', const Icon(Icons.code), () => _wrap('`', '`')),
          btn(
            'Bulleted list',
            const Icon(Icons.format_list_bulleted),
            () => _lines((line) => _togglePrefix('- ', line)),
          ),
          btn(
            'Numbered list',
            const Icon(Icons.format_list_numbered),
            () => _lines((line) => _togglePrefix('1. ', line)),
          ),
          btn(
            'Quote',
            const Icon(Icons.format_quote),
            () => _lines((line) => _togglePrefix('> ', line)),
          ),
          btn('Link', const Icon(Icons.link), _insertLink),
        ],
      ),
    );
  }
}
