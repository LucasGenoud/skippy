import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/util/highlight.dart';

void main() {
  const hl = TextStyle(decoration: TextDecoration.underline); // marker style
  String plain(List<InlineSpan> spans) =>
      spans.map((s) => (s as TextSpan).text ?? '').join();
  List<TextSpan> matched(List<InlineSpan> spans) => [
    for (final s in spans)
      if ((s as TextSpan).style != null) s,
  ];

  test('no query returns a single unstyled span', () {
    final spans = highlightSpans('Milk and eggs', '', highlight: hl);
    expect(spans.length, 1);
    expect((spans.single as TextSpan).style, isNull);
    expect(plain(spans), 'Milk and eggs');
  });

  test('splits around a match and styles only the match', () {
    final spans = highlightSpans('Milk and eggs', 'and', highlight: hl);
    expect(plain(spans), 'Milk and eggs'); // lossless reconstruction
    final hits = matched(spans);
    expect(hits.length, 1);
    expect(hits.single.text, 'and');
  });

  test('is case-insensitive and preserves the original casing', () {
    final spans = highlightSpans('Milk MILK milk', 'milk', highlight: hl);
    expect(matched(spans).map((s) => s.text), ['Milk', 'MILK', 'milk']);
    expect(plain(spans), 'Milk MILK milk');
  });

  test('no match returns the text intact and unstyled', () {
    final spans = highlightSpans('Milk', 'xyz', highlight: hl);
    expect(matched(spans), isEmpty);
    expect(plain(spans), 'Milk');
  });
}
