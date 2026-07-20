import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/util/linkify.dart';

void main() {
  group('findUrls', () {
    test('detects http(s) URLs and preserves their text', () {
      final urls = findUrls('see https://example.com/path?q=1 for more');
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://example.com/path?q=1');
    });

    test('prefixes bare www. hosts with https://', () {
      final urls = findUrls('go to www.youtube.com now');
      expect(urls.single.url, 'https://www.youtube.com');
    });

    test('finds multiple URLs in order', () {
      final urls = findUrls('http://a.com and https://b.com/x');
      expect(urls.map((u) => u.url).toList(), [
        'http://a.com',
        'https://b.com/x',
      ]);
    });

    test('trims trailing sentence punctuation', () {
      expect(findUrls('visit https://example.com.').single.url,
          'https://example.com');
      expect(findUrls('(https://example.com)').single.url,
          'https://example.com');
      expect(findUrls('link: https://example.com!').single.url,
          'https://example.com');
    });

    test('keeps balanced brackets inside the URL', () {
      final u = findUrls('https://en.wikipedia.org/wiki/Dart_(language)').single;
      expect(u.url, 'https://en.wikipedia.org/wiki/Dart_(language)');
    });

    test('returns nothing for plain text', () {
      expect(findUrls('no links here, just words.'), isEmpty);
      expect(findUrls('email me at foo@bar.com'), isEmpty);
    });

    test('start/end index back into the source text', () {
      const text = 'x https://example.com y';
      final u = findUrls(text).single;
      expect(text.substring(u.start, u.end), 'https://example.com');
    });
  });
}
