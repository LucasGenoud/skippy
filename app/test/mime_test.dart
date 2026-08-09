import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/util/mime.dart';

void main() {
  group('extensionFromMime', () {
    test('round-trips the known table, preferring the short spelling', () {
      expect(extensionFromMime('image/png'), 'png');
      expect(extensionFromMime('image/jpeg'), 'jpg');
      expect(extensionFromMime('application/pdf'), 'pdf');
    });

    test('is case and whitespace tolerant', () {
      expect(extensionFromMime(' IMAGE/PNG '), 'png');
    });

    test('falls back to the subtype for types outside the table', () {
      expect(extensionFromMime('image/heic'), 'heic');
      expect(extensionFromMime('image/svg+xml'), 'svg');
    });

    test('gives up on subtypes that make no sense as an extension', () {
      expect(extensionFromMime('application/octet-stream'), isNull);
      expect(
        extensionFromMime(
          'application/vnd.openxmlformats-officedocument.presentationml'
          '.presentation',
        ),
        isNull,
      );
    });
  });

  group('pastedFileName', () {
    final at = DateTime(2026, 8, 5, 14, 3, 9);

    test('stamps clipboard content that has no name of its own', () {
      expect(pastedFileName('image/png', at: at), 'pasted-20260805-140309.png');
    });

    test('stamps the generic name every browser gives a screenshot', () {
      expect(
        pastedFileName('image/png', suggested: 'image.png', at: at),
        'pasted-20260805-140309.png',
      );
      expect(
        pastedFileName('image/jpeg', suggested: 'Image', at: at),
        'pasted-20260805-140309.jpg',
      );
    });

    test('keeps a real name the clipboard carried', () {
      expect(
        pastedFileName('application/pdf', suggested: 'invoice.pdf', at: at),
        'invoice.pdf',
      );
      // Only the whole stem is generic, not a name that merely contains it.
      expect(
        pastedFileName('image/png', suggested: 'image-2.png', at: at),
        'image-2.png',
      );
    });

    test('leaves off the extension when the mime type yields none', () {
      expect(
        pastedFileName('application/octet-stream', at: at),
        'pasted-20260805-140309',
      );
    });
  });

  group('capturedFileName', () {
    final at = DateTime(2026, 8, 5, 14, 3, 9);

    test('stamps a camera capture, whose own name is a temp file', () {
      expect(
        capturedFileName('image/jpeg', at: at),
        'photo-20260805-140309.jpg',
      );
      expect(
        capturedFileName('image/heic', at: at),
        'photo-20260805-140309.heic',
      );
    });
  });
}
