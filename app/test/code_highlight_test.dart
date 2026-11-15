import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/util/code_highlight.dart';

String joined(List<CodeToken> tokens) => tokens.map((t) => t.text).join();

List<String> textsOf(List<CodeToken> tokens, CodeTokenKind kind) => [
  for (final token in tokens)
    if (token.kind == kind) token.text,
];

void main() {
  test('tokens always rebuild the exact source', () {
    const sources = [
      'final x = "a \\" b"; // done',
      "def f(x):\n    return x * 2  # twice",
      "it's unterminated\nnext line",
      '/* open comment',
      '',
    ];
    for (final source in sources) {
      expect(joined(highlightCode(source, language: 'dart')), source);
      expect(joined(highlightCode(source, language: 'python')), source);
      expect(joined(highlightCode(source)), source);
    }
  });

  test('colours keywords, strings, numbers, calls, types and comments', () {
    final tokens = highlightCode(
      'final total = sum(items, 0x1F) + 2.5; // Price\nreturn Money("eur");',
      language: 'dart',
    );
    expect(textsOf(tokens, CodeTokenKind.keyword), ['final', 'return']);
    expect(textsOf(tokens, CodeTokenKind.call), ['sum', 'Money']);
    expect(textsOf(tokens, CodeTokenKind.number), ['0x1F', '2.5']);
    expect(textsOf(tokens, CodeTokenKind.string), ['"eur"']);
    expect(textsOf(tokens, CodeTokenKind.comment), ['// Price']);
  });

  test('a hash is a comment only where the language says so', () {
    expect(
      textsOf(
        highlightCode('x = 1 # note', language: 'python'),
        CodeTokenKind.comment,
      ),
      ['# note'],
    );
    expect(
      textsOf(
        highlightCode('color: #fff; // c', language: 'css'),
        CodeTokenKind.comment,
      ),
      ['// c'],
    );
  });

  test('a digit inside a name stays part of the name', () {
    final tokens = highlightCode('let x1 = v2;', language: 'rust');
    expect(textsOf(tokens, CodeTokenKind.number), isEmpty);
  });

  test('a stray apostrophe stops at the end of its line', () {
    final tokens = highlightCode("don't\nlet y = 3;", language: 'js');
    expect(textsOf(tokens, CodeTokenKind.string), ["'t"]);
    expect(textsOf(tokens, CodeTokenKind.keyword), ['let']);
  });
}
