import 'package:flutter_test/flutter_test.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:skippy/state/share_payload.dart';

SharedMediaFile media(String path, SharedMediaType type, {String? mime}) =>
    SharedMediaFile(path: path, type: type, mimeType: mime);

void main() {
  group('classifyShare', () {
    test('an empty payload yields nothing', () {
      expect(classifyShare([]), isNull);
    });

    test('a single link becomes a text note', () {
      final p = classifyShare([
        media('https://example.com', SharedMediaType.url),
      ]);
      expect(p, isA<SharedTextPayload>());
      expect((p as SharedTextPayload).text, 'https://example.com');
    });

    test('multiple text/url items join with newlines', () {
      final p = classifyShare([
        media('look at this', SharedMediaType.text),
        media('https://example.com', SharedMediaType.url),
      ]);
      expect(p, isA<SharedTextPayload>());
      expect((p as SharedTextPayload).text, 'look at this\nhttps://example.com');
    });

    test('blank-only text yields nothing', () {
      final p = classifyShare([media('   ', SharedMediaType.text)]);
      expect(p, isNull);
    });

    test('an image becomes a files payload', () {
      final p = classifyShare([
        media('/tmp/photo.png', SharedMediaType.image, mime: 'image/png'),
      ]);
      expect(p, isA<SharedFilesPayload>());
      expect((p as SharedFilesPayload).files.single.path, '/tmp/photo.png');
    });

    test('anything file-like wins over stray text', () {
      final p = classifyShare([
        media('caption', SharedMediaType.text),
        media('/tmp/a.pdf', SharedMediaType.file, mime: 'application/pdf'),
      ]);
      expect(p, isA<SharedFilesPayload>());
      // Only the file(s) carry through as attachments.
      expect((p as SharedFilesPayload).files.map((f) => f.type), [
        SharedMediaType.file,
      ]);
    });
  });
}
