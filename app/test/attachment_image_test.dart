import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/util/attachment_image.dart';

void main() {
  test('attachment image cache is stable per server, not global per id', () {
    final current = AttachmentImage(
      attachmentId: 'same-id',
      url: 'https://a.example/api/files/same-id?exp=1&sig=old',
    );
    final refreshed = AttachmentImage(
      attachmentId: 'same-id',
      url: 'https://a.example/api/files/same-id?exp=2&sig=new',
    );
    final otherServer = AttachmentImage(
      attachmentId: 'same-id',
      url: 'https://b.example/api/files/same-id?exp=2&sig=new',
    );

    expect(current, refreshed);
    expect(current.hashCode, refreshed.hashCode);
    expect(current, isNot(otherServer));
  });
}
