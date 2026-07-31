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

AuthStore storeWith(http.Client client) => AuthStore(
  api: ApiClient(baseUrl: 'http://server.test', httpClient: client),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('session restore', () {
    test('a cached session opens without waiting for the server', () async {
      seedSession();
      // A phone with no route to the server doesn't get a refusal, the socket
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

    test(
      'an offline restore without a cached profile stays signed out',
      () async {
        SharedPreferences.setMockInitialValues({'sticky_notes_token': 'tok'});
        final auth = storeWith(
          MockClient((_) => Future.error(const SocketExceptionStub())),
        );

        await auth.restore();

        expect(auth.status, AuthStatus.signedOut);
        expect(auth.user, isNull);
        expect(auth.api.token, isNull);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('sticky_notes_token'), 'tok');
      },
    );

    test('a stale restore response cannot replace a newer login', () async {
      seedSession();
      final oldMe = Completer<http.Response>();
      final auth = storeWith(
        MockClient((request) async {
          if (request.url.path.endsWith('/auth/me')) return oldMe.future;
          if (request.url.path.endsWith('/auth/login')) {
            return http.Response(
              jsonEncode({
                'token': 'new-token',
                'user': {
                  'id': 'u-new',
                  'name': 'New',
                  'email': 'new@example.com',
                },
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );

      await auth.restore();
      await auth.signIn('new@example.com', 'password');
      oldMe.complete(
        http.Response(
          jsonEncode({
            'id': 'u-old',
            'name': 'Old',
            'email': 'old@example.com',
          }),
          200,
        ),
      );
      await pumpEventQueue();

      expect(auth.status, AuthStatus.signedIn);
      expect(auth.user?.id, 'u-new');
      expect(auth.api.token, 'new-token');
    });

    test('a stale restore rejection cannot clear a newer login', () async {
      seedSession();
      final oldMe = Completer<http.Response>();
      final auth = storeWith(
        MockClient((request) async {
          if (request.url.path.endsWith('/auth/me')) return oldMe.future;
          if (request.url.path.endsWith('/auth/login')) {
            return http.Response(
              jsonEncode({
                'token': 'new-token',
                'user': {
                  'id': 'u-new',
                  'name': 'New',
                  'email': 'new@example.com',
                },
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );

      await auth.restore();
      await auth.signIn('new@example.com', 'password');
      oldMe.complete(http.Response('{"error":"expired"}', 401));
      await pumpEventQueue();

      expect(auth.status, AuthStatus.signedIn);
      expect(auth.user?.id, 'u-new');
      expect(auth.api.token, 'new-token');
    });

    test('a stale API rejection cannot clear a newer login', () async {
      seedSession();
      final oldNotes = Completer<http.Response>();
      late http.Request oldNotesRequest;
      final auth = storeWith(
        MockClient((request) async {
          if (request.url.path.endsWith('/auth/me')) {
            return http.Response(
              jsonEncode({
                'id': 'u-me',
                'name': 'Me',
                'email': 'me@example.com',
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/notes')) {
            oldNotesRequest = request;
            return oldNotes.future;
          }
          if (request.url.path.endsWith('/auth/login')) {
            return http.Response(
              jsonEncode({
                'token': 'new-token',
                'user': {
                  'id': 'u-new',
                  'name': 'New',
                  'email': 'new@example.com',
                },
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );

      await auth.restore();
      await pumpEventQueue();
      final staleRequest = auth.api.fetchNotes();
      await pumpEventQueue();
      await auth.signIn('new@example.com', 'password');
      oldNotes.complete(
        http.Response('{"error":"expired"}', 401, request: oldNotesRequest),
      );

      await expectLater(staleRequest, throwsA(isA<ApiException>()));
      await pumpEventQueue();
      expect(auth.status, AuthStatus.signedIn);
      expect(auth.user?.id, 'u-new');
      expect(auth.api.token, 'new-token');
    });

    test('switching servers invalidates an in-flight login', () async {
      SharedPreferences.setMockInitialValues({});
      final login = Completer<http.Response>();
      final api = ApiClient(
        baseUrl: 'http://server-a.test',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/auth/login')) return login.future;
          return http.Response('{}', 200);
        }),
      );
      final auth = AuthStore(api: api);

      final signingIn = auth.signIn('me@example.com', 'password');
      await pumpEventQueue();
      await auth.setActiveUrl('http://server-b.test');
      login.complete(
        http.Response(
          jsonEncode({
            'token': 'server-a-token',
            'user': {'id': 'u-a', 'name': 'A user', 'email': 'me@example.com'},
          }),
          200,
        ),
      );

      expect(await signingIn, isFalse);
      expect(auth.activeUrl, 'http://server-b.test');
      expect(auth.status, AuthStatus.signedOut);
      expect(auth.user, isNull);
      expect(auth.api.token, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sticky_notes_token'), isNull);
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

  group('backend urls', () {
    test('editing a saved url keeps its place in the list', () async {
      SharedPreferences.setMockInitialValues({
        'sticky_notes_backend_urls': [
          'http://a.test',
          'http://b.test',
          'http://server.test',
        ],
      });
      final auth = storeWith(MockClient((_) async => http.Response('{}', 200)));
      await auth.loadSavedUrls();

      await auth.editUrl('http://b.test', 'http://renamed.test/');

      // Trailing slashes are normalised away, as they are when adding.
      expect(auth.savedUrls, [
        'http://a.test',
        'http://renamed.test',
        'http://server.test',
      ]);
      // A non-active url was edited, so the connection is untouched.
      expect(auth.activeUrl, 'http://server.test');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('sticky_notes_backend_urls'), auth.savedUrls);
    });

    test('editing the active url signs out and switches to it', () async {
      seedSession();
      final auth = storeWith(MockClient((_) async => http.Response('{}', 200)));
      await auth.loadSavedUrls();
      await auth.restore();
      expect(auth.status, AuthStatus.signedIn);

      await auth.editUrl('http://server.test', 'http://moved.test');

      expect(auth.activeUrl, 'http://moved.test');
      expect(auth.savedUrls, ['http://moved.test']);
      // The session belonged to the old address, so it cannot carry over.
      expect(auth.status, AuthStatus.signedOut);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sticky_notes_active_url'), 'http://moved.test');
    });

    test('editing to an address already saved is refused', () async {
      SharedPreferences.setMockInitialValues({
        'sticky_notes_backend_urls': ['http://a.test', 'http://server.test'],
      });
      final auth = storeWith(MockClient((_) async => http.Response('{}', 200)));
      await auth.loadSavedUrls();

      await auth.editUrl('http://a.test', 'http://server.test');

      expect(auth.savedUrls, ['http://a.test', 'http://server.test']);
    });
  });
}

/// Stands in for a transport failure (`SocketException` on mobile) without
/// pulling in `dart:io`, which the test host shares with the web build.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
