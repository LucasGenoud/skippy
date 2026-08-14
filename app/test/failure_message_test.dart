import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/api/api_client.dart';
import 'package:skippy/util/network_error.dart';

void main() {
  group('ApiException.serverMessage', () {
    test('prefers our own JSON error envelope', () {
      expect(
        ApiException(409, '{"error":"That email is taken"}').serverMessage,
        'That email is taken',
      );
    });

    test('keeps a short plain-text body', () {
      expect(
        ApiException(400, 'reminder_at is not a timestamp').serverMessage,
        'reminder_at is not a timestamp',
      );
    });

    // The reported bug: a red banner with nothing written in it. A wrong
    // server URL lands on some other service's zero-length 404, and the empty
    // body went straight to the screen.
    test('an empty body still explains itself', () {
      final message = ApiException(404, '').serverMessage;
      expect(message, isNotEmpty);
      expect(message, contains('404'));
    });

    test('an empty envelope is treated as no message at all', () {
      expect(ApiException(500, '{"error":"  "}').serverMessage, isNotEmpty);
      expect(ApiException(500, '{"error":""}').serverMessage, contains('500'));
    });

    test('a proxy error page is summarized, not pasted into the UI', () {
      const html =
          '<html><head><title>502 Bad Gateway</title></head>'
          '<body><center><h1>502 Bad Gateway</h1></center></body></html>';
      final message = ApiException(502, html).serverMessage;
      expect(message, isNot(contains('<')));
      expect(message, contains('502'));
    });

    test('every status says something', () {
      for (final status in [400, 401, 403, 404, 405, 409, 413, 429, 500, 503]) {
        expect(
          ApiException(status, '').serverMessage.trim(),
          isNotEmpty,
          reason: 'status $status',
        );
      }
    });
  });

  group('describeConnectionFailure', () {
    const url = 'https://notes.example.com:8443';

    test('names the host and port it could not reach', () {
      final message = describeConnectionFailure(
        Exception('something odd'),
        url,
      );
      expect(message, contains('notes.example.com:8443'));
      expect(message, isNotEmpty);
    });

    test('separates the failures a self-hoster has to act on differently', () {
      String describe(String text) =>
          describeConnectionFailure(Exception(text), url);

      expect(
        describeConnectionFailure(TimeoutException('x'), url),
        contains('did not respond in time'),
      );
      expect(
        describe("Failed host lookup: 'notes.example.com'"),
        contains("Can't find"),
      );
      expect(describe('Connection refused'), contains('Nothing is answering'));
      expect(
        describe('HandshakeException: CERTIFICATE_VERIFY_FAILED'),
        contains('certificate'),
      );
      expect(
        describe('ClientException: XMLHttpRequest error.'),
        contains('browser'),
      );
    });

    test('falls back to the raw address when it does not parse as a URL', () {
      expect(
        describeConnectionFailure(Exception('nope'), 'not a url'),
        contains('not a url'),
      );
    });
  });
}
