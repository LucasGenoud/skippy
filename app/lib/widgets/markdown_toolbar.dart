import 'package:flutter/material.dart';

import '../theme.dart';

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

  /// A button's hover shape, inside the tray.
  static const double _buttonSize = 36;

  /// Space between the tray's edge and the buttons' hover shapes.
  static const double _inset = kSpaceXs;

  static const double _dividerHeight = 16;

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

  /// Makes the line a task, turning a plain bullet into one rather than
  /// stacking markers; on a task it removes the box and bullet.
  String _toggleTask(String line) {
    final task = RegExp(r'^- \[[ xX]\] ');
    if (task.hasMatch(line)) {
      return line.replaceFirst(task, '');
    }
    if (line.startsWith('- ')) {
      return '- [ ] ${line.substring(2)}';
    }
    return '- [ ] $line';
  }

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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget btn(String tooltip, Widget icon, VoidCallback onTap) => IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      iconSize: kCompactIconSize,
      color: scheme.onSurfaceVariant,
      style: IconButton.styleFrom(
        fixedSize: const Size.square(_buttonSize),
        minimumSize: const Size.square(_buttonSize),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const RoundedRectangleBorder(borderRadius: kSmallBorderRadius),
      ),
      icon: icon,
    );

    Widget heading(int level) => btn(
      'Heading $level',
      Text(
        'H$level',
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: scheme.onSurfaceVariant,
        ),
      ),
      () => _lines((line) => _heading(level, line)),
    );

    // A short hairline between groups: headings, inline, blocks, link.
    final divider = Container(
      width: 1,
      height: _dividerHeight,
      margin: const EdgeInsets.symmetric(horizontal: kSpaceXs),
      color: hairlineColor(scheme),
    );

    // The tray hugs its buttons and scrolls sideways when they outgrow it.
    // Buttons keep [_inset] from its edges and its corner is theirs plus that
    // inset, so their hover shapes sit concentric inside it.
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: toolbarTrayColor(scheme),
          borderRadius: kCardBorderRadius,
        ),
        child: ClipRRect(
          borderRadius: kCardBorderRadius,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(_inset),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                heading(1),
                heading(2),
                heading(3),
                divider,
                btn(
                  'Bold',
                  const Icon(Icons.format_bold),
                  () => _wrap('**', '**'),
                ),
                btn(
                  'Italic',
                  const Icon(Icons.format_italic),
                  () => _wrap('_', '_'),
                ),
                btn(
                  'Strikethrough',
                  const Icon(Icons.format_strikethrough),
                  () => _wrap('~~', '~~'),
                ),
                btn(
                  'Inline code',
                  const Icon(Icons.code),
                  () => _wrap('`', '`'),
                ),
                divider,
                btn(
                  'Code block',
                  const Icon(Icons.data_object),
                  () => _wrap('```\n', '\n```'),
                ),
                btn(
                  'Bulleted list',
                  const Icon(Icons.format_list_bulleted),
                  () => _lines((line) => _togglePrefix('- ', line)),
                ),
                btn(
                  'Task',
                  const Icon(Icons.check_box_outlined),
                  () => _lines(_toggleTask),
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
                divider,
                btn('Link', const Icon(Icons.link), _insertLink),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
