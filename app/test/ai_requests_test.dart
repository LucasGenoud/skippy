import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skippy/api/api_client.dart';
import 'package:skippy/models/note.dart';

void main() {
  // A model on a home server can take most of a minute. The ordinary request
  // ceiling reported those as failures while the server went on to apply the
  // edit anyway.
  ApiClient slowServer(String body) => ApiClient(
    baseUrl: 'http://skippy.test',
    httpClient: MockClient((_) async {
      await Future<void>.delayed(const Duration(seconds: 40));
      return http.Response(body, 200);
    }),
  )..token = 't';

  testWidgets('a link summary may take longer than an ordinary request', (
    tester,
  ) async {
    String? summary;
    Object? error;
    unawaited(
      slowServer(jsonEncode({'summary': 'Short.'}))
          .summarizeUrl('https://example.com', noteId: 'n1')
          .then((s) => summary = s, onError: (Object e) => error = e),
    );

    await tester.pump(const Duration(seconds: 41));

    expect(error, isNull);
    expect(summary, 'Short.');
  });

  testWidgets('an AI rewrite may take longer than an ordinary request', (
    tester,
  ) async {
    Object? error;
    var settled = false;
    unawaited(
      slowServer('{}')
          .rewriteNote('n1', kDefaultNoteRewriteTasks.first)
          .then(
            (_) => settled = true,
            onError: (Object e) {
              error = e;
              settled = true;
            },
          ),
    );

    await tester.pump(const Duration(seconds: 41));

    // An empty body is no note, but it arrived: the request was not cut off.
    expect(settled, isTrue);
    expect(error, isNot(isA<TimeoutException>()));
  });
}
