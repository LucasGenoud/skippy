import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skippy/api/api_client.dart';
import 'package:skippy/state/auth_store.dart';

/// A saved session, as [AuthStore] writes it at sign-in.
void seedSession() => SharedPreferences.setMockInitialValues({
  'sticky_notes_token': 'tok',
  'sticky_notes_user': jsonEncode({
    'id': 'u-me',
    'name': 'Me',
    'email': 'me@example.com',
  }),
});

AuthStore storeWith(http.Client client) =>
    AuthStore(api: ApiClient(baseUrl: 'http://server.test', httpClient: client));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('session restore', () {
    test('a cached session opens without waiting for the server', () async {
      seedSession();
      // A phone with no route to the server doesn't get a refusal — the socket
      // just hangs. Nothing about opening the app may depend on it.
      final hung = Completer<http.Response>();
      final auth = storeWith(MockClient((_) => hung.future));

      await auth.restore().timeout(const Duration(seconds: 1));

      expect(auth.status, AuthStatus.signedIn);
      // The user id keys the offline notes cache, so it has to be the real one.
      expect(auth.user?.id, 'u-me');
      hung.complete(http.Response('{}', 200));
    });

    test('an unreachable server keeps the session', () async {
      seedSession();
      final auth = storeWith(
        MockClient((_) => Future.error(const SocketExceptionStub())),
      );

      await auth.restore();
      await pumpEventQueue(); // let the background check fail

      expect(auth.status, AuthStatus.signedIn);
      expect(auth.user?.id, 'u-me');
    });

    test('a revoked token signs out once the server says so', () async {
      seedSession();
      final auth = storeWith(
        MockClient((_) async => http.Response('{"error":"nope"}', 401)),
      );

      await auth.restore();
      expect(auth.status, AuthStatus.signedIn); // optimistic first...

      await pumpEventQueue();
      expect(auth.status, AuthStatus.signedOut); // ...then corrected
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sticky_notes_token'), isNull);
    });

    test('a server error does not sign the user out', () async {
      seedSession();
      final auth = storeWith(
        MockClient((_) async => http.Response('{"error":"boom"}', 500)),
      );

      await auth.restore();
      await pumpEventQueue();

      expect(auth.status, AuthStatus.signedIn);
    });
  });

  group('sign out', () {
    test('an unreachable server does not hold the session open', () async {
      seedSession();
      // No route to the server: the socket hangs rather than refusing, so the
      // logout call never answers. Signing out is a local decision and must
      // not wait on it.
      final hung = Completer<http.Response>();
      final auth = storeWith(MockClient((_) => hung.future));
      await auth.restore();

      await auth.signOut().timeout(const Duration(seconds: 1));

      expect(auth.status, AuthStatus.signedOut);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sticky_notes_token'), isNull);
      hung.complete(http.Response('{}', 200));
    });

    test('a failed revoke is not reported to the caller', () async {
      seedSession();
      final auth = storeWith(
        MockClient((_) => Future.error(const SocketExceptionStub())),
      );
      await auth.restore();

      await auth.signOut();
      await pumpEventQueue(); // let the background revoke fail

      expect(auth.status, AuthStatus.signedOut);
      expect(auth.user, isNull);
    });
  });
}

/// Stands in for a transport failure (`SocketException` on mobile) without
/// pulling in `dart:io`, which the test host shares with the web build.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
