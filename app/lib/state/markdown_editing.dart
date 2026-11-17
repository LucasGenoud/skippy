import 'package:flutter/services.dart';

// Typing rules for markdown notes, kept pure so they are tested without a
// field: lists carry on when you press Enter, a marker typed over a selection
// wraps it, and a task in the preview can be ticked by its position.

/// A list or quote line: its indent and quote markers, its bullet or number,
/// an optional task box, and what follows.
///
///   "  - [ ] milk"  →  indent "  ", bullet "-", task "[ ] ", rest "milk"
///   "> 3. step"     →  indent "> ", number 3 ")" or ".", rest "step"
final _listLine = RegExp(
  r'^((?:\s*>)*\s*)(?:([-*+])|(\d{1,9})([.)]))\s(\[[ xX]\]\s)?(.*)$',
);

/// A quote line that is not a list item: "> text".
final _quoteLine = RegExp(r'^(\s*(?:>\s?)+)(.*)$');

/// A task item's box, wherever the parser would find one.
final _taskLine = RegExp(r'^((?:\s*>)*\s*(?:[-*+]|\d{1,9}[.)])\s\[)([ xX])\]');

final _fence = RegExp(r'^\s*(```|~~~)');

/// The characters that wrap a selection when typed over it.
const _wrapMarkers = {'*', '_', '`', '~'};

/// Continues a list when Enter is pressed at the end of (or inside) an item:
/// the new line gets the same indent and bullet, the next number, and an
/// empty task box after a task. Enter on an empty item ends the list instead,
/// clearing its marker, the way every notes app does.
class MarkdownListFormatter extends TextInputFormatter {
  const MarkdownListFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final caret = oldValue.selection;
    if (!caret.isValid || !caret.isCollapsed) {
      return newValue;
    }

    // Exactly one newline typed at the caret, nothing else changed.
    final at = caret.baseOffset;
    final before = oldValue.text;
    if (newValue.text !=
        '${before.substring(0, at)}\n${before.substring(at)}') {
      return newValue;
    }

    final lineStart = before.lastIndexOf('\n', at - 1) + 1;
    final line = before.substring(lineStart, at);
    if (_insideFence(before, lineStart)) {
      return newValue;
    }

    final item = _listLine.firstMatch(line);
    if (item != null) {
      return _continueItem(before, at, lineStart, item) ?? newValue;
    }

    final quote = _quoteLine.firstMatch(line);
    if (quote != null && line.trimLeft().startsWith('>')) {
      return _continue(before, at, lineStart, quote.group(1)!, quote.group(2)!);
    }
    return newValue;
  }

  TextEditingValue? _continueItem(
    String text,
    int at,
    int lineStart,
    RegExpMatch item,
  ) {
    final indent = item.group(1)!;
    final bullet = item.group(2);
    final number = item.group(3);
    final task = item.group(5);
    final marker = bullet != null
        ? '$bullet '
        : '${int.parse(number!) + 1}${item.group(4)} ';
    final box = task == null ? '' : '[ ] ';
    return _continue(text, at, lineStart, '$indent$marker$box', item.group(6)!);
  }

  /// Puts [prefix] on a new line at [at], or, when the current item is empty,
  /// clears the current line's marker instead.
  TextEditingValue _continue(
    String text,
    int at,
    int lineStart,
    String prefix,
    String rest,
  ) {
    if (rest.trim().isEmpty) {
      final cleared = text.replaceRange(lineStart, at, '');
      return TextEditingValue(
        text: cleared,
        selection: TextSelection.collapsed(offset: lineStart),
      );
    }
    final inserted = '\n$prefix';
    return TextEditingValue(
      text: text.replaceRange(at, at, inserted),
      selection: TextSelection.collapsed(offset: at + inserted.length),
    );
  }
}

/// Typing `*`, `_`, `` ` `` or `~` over a selection wraps it instead of
/// replacing it, and keeps it selected, so a second `*` makes it bold.
class MarkdownWrapFormatter extends TextInputFormatter {
  const MarkdownWrapFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final selection = oldValue.selection;
    if (!selection.isValid || selection.isCollapsed) {
      return newValue;
    }

    final start = selection.start;
    final end = selection.end;
    final before = oldValue.text;
    final typedLength = newValue.text.length - (before.length - (end - start));
    if (typedLength != 1) {
      return newValue;
    }
    final typed = newValue.text.substring(start, start + 1);
    if (!_wrapMarkers.contains(typed) ||
        newValue.text != before.replaceRange(start, end, typed)) {
      return newValue;
    }

    final selected = before.substring(start, end);
    return TextEditingValue(
      text: before.replaceRange(start, end, '$typed$selected$typed'),
      selection: TextSelection(
        baseOffset: start + 1,
        extentOffset: start + 1 + selected.length,
      ),
    );
  }
}

/// How many task items [source] holds, in the order a preview draws them.
int taskCount(String source) => _taskOffsets(source).length;

/// Ticks or unticks the [index]th task in [source]. Out of range leaves it
/// unchanged.
String toggleTask(String source, int index) {
  final offsets = _taskOffsets(source);
  if (index < 0 || index >= offsets.length) {
    return source;
  }
  final at = offsets[index];
  final checked = source[at] != ' ';
  return source.replaceRange(at, at + 1, checked ? ' ' : 'x');
}

/// Offsets of each task's box character (the space or x), skipping fenced
/// code, which the preview shows as code rather than as tasks.
List<int> _taskOffsets(String source) {
  final offsets = <int>[];
  var fenced = false;
  var lineStart = 0;
  for (final line in source.split('\n')) {
    if (_fence.hasMatch(line)) {
      fenced = !fenced;
    } else if (!fenced) {
      final task = _taskLine.firstMatch(line);
      if (task != null) {
        offsets.add(lineStart + task.group(1)!.length);
      }
    }
    lineStart += line.length + 1;
  }
  return offsets;
}

bool _insideFence(String text, int lineStart) {
  var fenced = false;
  for (final line in text.substring(0, lineStart).split('\n')) {
    if (_fence.hasMatch(line)) {
      fenced = !fenced;
    }
  }
  return fenced;
}
