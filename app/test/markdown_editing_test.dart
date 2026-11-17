import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/state/markdown_editing.dart';

/// [text] with the caret where `|` is.
TextEditingValue at(String text) {
  final caret = text.indexOf('|');
  return TextEditingValue(
    text: text.replaceFirst('|', ''),
    selection: TextSelection.collapsed(offset: caret),
  );
}

/// Presses Enter at the caret in [text] and answers the result, caret as `|`.
String enter(String text) {
  final before = at(text);
  final offset = before.selection.baseOffset;
  final typed = TextEditingValue(
    text: before.text.replaceRange(offset, offset, '\n'),
    selection: TextSelection.collapsed(offset: offset + 1),
  );
  final after = const MarkdownListFormatter().formatEditUpdate(before, typed);
  final caret = after.selection.baseOffset;
  return after.text.replaceRange(caret, caret, '|');
}

void main() {
  group('Enter continues lists', () {
    test('bullets carry on with the same marker and indent', () {
      expect(enter('- milk|'), '- milk\n- |');
      expect(enter('  * eggs|'), '  * eggs\n  * |');
    });

    test('numbers count up', () {
      expect(enter('1. one|'), '1. one\n2. |');
      expect(enter('9) nine|'), '9) nine\n10) |');
    });

    test('a task starts an empty task, even after a ticked one', () {
      expect(enter('- [x] done|'), '- [x] done\n- [ ] |');
    });

    test('quotes carry on', () {
      expect(enter('> said|'), '> said\n> |');
    });

    test('Enter on an empty item ends the list', () {
      expect(enter('- milk\n- |'), '- milk\n|');
      expect(enter('- [ ] |'), '|');
    });

    test('splitting an item carries the rest onto the new one', () {
      expect(enter('- milk| eggs'), '- milk\n- | eggs');
    });

    test('plain lines and code stay plain', () {
      expect(enter('hello|'), 'hello\n|');
      expect(enter('```\n- not a list|'), '```\n- not a list\n|');
    });
  });

  group('typing a marker over a selection', () {
    TextEditingValue type(String text, int start, int end, String char) {
      final before = TextEditingValue(
        text: text,
        selection: TextSelection(baseOffset: start, extentOffset: end),
      );
      final typed = TextEditingValue(
        text: text.replaceRange(start, end, char),
        selection: TextSelection.collapsed(offset: start + 1),
      );
      return const MarkdownWrapFormatter().formatEditUpdate(before, typed);
    }

    test('wraps it and keeps it selected, so twice makes bold', () {
      final once = type('very urgent', 5, 11, '*');
      expect(once.text, 'very *urgent*');
      expect(once.selection.textInside(once.text), 'urgent');

      final twice = const MarkdownWrapFormatter().formatEditUpdate(
        once,
        TextEditingValue(
          text: once.text.replaceRange(6, 12, '*'),
          selection: const TextSelection.collapsed(offset: 7),
        ),
      );
      expect(twice.text, 'very **urgent**');
    });

    test('any other character replaces the selection as usual', () {
      expect(type('very urgent', 5, 11, 'x').text, 'very x');
    });
  });

  group('ticking tasks by position', () {
    const source = '## Trip\n- [ ] flights\n```\n- [ ] code\n```\n* [x] hotel';

    test('counts the tasks a preview draws, not ones in code', () {
      expect(taskCount(source), 2);
    });

    test('toggles the nth task', () {
      expect(
        toggleTask(source, 0),
        '## Trip\n- [x] flights\n```\n- [ ] code\n```\n* [x] hotel',
      );
      expect(
        toggleTask(source, 1),
        '## Trip\n- [ ] flights\n```\n- [ ] code\n```\n* [ ] hotel',
      );
      expect(toggleTask(source, 5), source);
    });
  });
}
