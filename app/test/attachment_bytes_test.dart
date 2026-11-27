import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skippy/api/api_client.dart';
import 'package:skippy/models/note.dart';

void main() {
  const attachment = Attachment(
    id: 'a1',
    mime: 'image/png',
    filename: 'pic.png',
    size: 3,
    url: '/api/files/a1?exp=1&sig=s',
  );

  test('attachment bytes load from the signed url', () async {
    http.Request? sent;
    final api = ApiClient(
      baseUrl: 'http://skippy.test',
      httpClient: MockClient((request) async {
        sent = request;
        return http.Response.bytes([1, 2, 3], 200);
      }),
    )..token = 't';

    final bytes = await api.attachmentBytes(attachment);

    expect(bytes, Uint8List.fromList([1, 2, 3]));
    expect(sent!.url.toString(), 'http://skippy.test/api/files/a1?exp=1&sig=s');
  });

  test('a refused attachment raises an ApiException', () async {
    final api = ApiClient(
      baseUrl: 'http://skippy.test',
      httpClient: MockClient((_) async => http.Response('expired', 403)),
    )..token = 't';

    expect(
      api.attachmentBytes(attachment),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 403)),
    );
  });
}
