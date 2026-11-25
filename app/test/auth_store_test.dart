import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skippy/api/api_client.dart';
import 'package:skippy/state/auth_store.dart';
import 'package:skippy/state/starter_notes.dart';

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

  group('account origin', () {
    final session = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'token': 'tok',
          'user': {'id': 'u-me', 'name': 'Me', 'email': 'me@example.com'},
        }),
        200,
      ),
    );

    test('registering marks the account as just created', () async {
      SharedPreferences.setMockInitialValues({});
      final auth = storeWith(session);

      await auth.registerAccount('Me', 'me@example.com', 'password');

      expect(auth.accountOrigin, AccountOrigin.justCreated);
    });

    test('signing in after registering is an existing account', () async {
      SharedPreferences.setMockInitialValues({});
      final auth = storeWith(session);

      await auth.registerAccount('Me', 'me@example.com', 'password');
      await auth.signIn('me@example.com', 'password');

      expect(auth.accountOrigin, AccountOrigin.existing);
    });
  });

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

  group('sign-in failures always say something', () {
    // The login banner has no other source of text. Every one of these used to
    // be able to leave it blank or fill it with machine output.
    test('a wrong server URL reports the status, not an empty body', () async {
      SharedPreferences.setMockInitialValues({});
      // A zero-length 404 is what a plain web server answers to /api/auth/login.
      final auth = storeWith(MockClient((_) async => http.Response('', 404)));

      expect(await auth.signIn('me@example.com', 'secret'), isFalse);

      expect(auth.error, isNotNull);
      expect(auth.error, isNotEmpty);
      expect(auth.error, contains('404'));
    });

    test('an unreachable server names the host', () async {
      SharedPreferences.setMockInitialValues({});
      final auth = storeWith(
        MockClient((_) => Future.error(Exception('Connection refused'))),
      );

      expect(await auth.signIn('me@example.com', 'secret'), isFalse);

      expect(auth.error, contains('server.test'));
    });

    test('a rejected password keeps its own wording', () async {
      SharedPreferences.setMockInitialValues({});
      final auth = storeWith(
        MockClient((_) async => http.Response('{"error":"unauthorized"}', 401)),
      );

      expect(await auth.signIn('me@example.com', 'secret'), isFalse);

      expect(auth.error, 'Wrong email or password');
      expect(auth.errorStatus, 401);
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

  group('single sign-on', () {
    /// A server whose exchange checks the verifier against the challenge the
    /// store put in the start URL, as the real one does.
    late String challenge;
    late Map<String, dynamic> exchanged;

    AuthStore ssoStore(
      Uri? Function(Uri start) browser, {
      bool created = true,
    }) {
      final server = MockClient((request) async {
        exchanged = jsonDecode(request.body) as Map<String, dynamic>;
        final verifier = exchanged['code_verifier'] as String;
        final hashed = base64UrlEncode(
          sha256.convert(utf8.encode(verifier)).bytes,
        ).replaceAll('=', '');
        if (request.url.path != '/api/auth/sso/exchange' ||
            hashed != challenge) {
          return http.Response('{"error":"unauthorized"}', 401);
        }
        return http.Response(
          jsonEncode({
            'token': 'sso-tok',
            'user': {
              'id': 'u-sso',
              'name': 'Grace',
              'email': 'grace@example.com',
              'has_password': false,
            },
            'created': created,
          }),
          200,
        );
      });
      return AuthStore(
        api: ApiClient(baseUrl: 'http://server.test', httpClient: server),
        openSso: (start) async {
          expect(start.path, '/api/auth/sso/start');
          expect(start.queryParameters['return_to'], 'skippy-auth://callback');
          challenge = start.queryParameters['code_challenge']!;
          return browser(start);
        },
      );
    }

    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a returned code becomes a session bound to this attempt', () async {
      final auth = ssoStore(
        (_) => Uri.parse('skippy-auth://callback?sso_code=abc'),
      );

      expect(await auth.signInWithSso(), isTrue);

      expect(exchanged['code'], 'abc');
      expect(auth.status, AuthStatus.signedIn);
      expect(auth.user!.hasPassword, isFalse);
      expect(auth.api.token, 'sso-tok');
      expect(auth.accountOrigin, AccountOrigin.justCreated);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sticky_notes_token'), 'sso-tok');
    });

    test('an existing account is not welcomed as new', () async {
      final auth = ssoStore(
        (_) => Uri.parse('skippy-auth://callback?sso_code=abc'),
        created: false,
      );
      await auth.signInWithSso();
      expect(auth.accountOrigin, AccountOrigin.existing);
    });

    test('a refusal from the provider is shown as a sentence', () async {
      final auth = ssoStore(
        (_) => Uri.parse(
          'skippy-auth://callback?sso_error=sign-in%20was%20cancelled',
        ),
      );
      expect(await auth.signInWithSso(), isFalse);
      expect(auth.status, isNot(AuthStatus.signedIn));
      expect(auth.error, 'Sign-in was cancelled');
    });

    test('a second tap while the browser is open starts nothing', () async {
      final browser = Completer<Uri?>();
      var opened = 0;
      final auth = AuthStore(
        api: ApiClient(baseUrl: 'http://server.test'),
        openSso: (_) {
          opened++;
          return browser.future;
        },
      );
      final first = auth.signInWithSso();
      expect(await auth.signInWithSso(), isFalse);
      expect(opened, 1);
      browser.complete(null);
      expect(await first, isFalse);
      // Free again once the first attempt is over.
      unawaited(auth.signInWithSso());
      expect(opened, 2);
    });

    test('closing the browser reports nothing', () async {
      final auth = ssoStore((_) => null);
      expect(await auth.signInWithSso(), isFalse);
      expect(auth.error, isNull);
      expect(auth.status, isNot(AuthStatus.signedIn));
    });

    test('an expired code says so rather than blaming a password', () async {
      final auth = AuthStore(
        api: ApiClient(
          baseUrl: 'http://server.test',
          httpClient: MockClient(
            (_) async => http.Response('{"error":"unauthorized"}', 401),
          ),
        ),
        openSso: (_) async => Uri.parse('skippy-auth://callback?sso_code=x'),
      );
      expect(await auth.signInWithSso(), isFalse);
      expect(auth.error, 'This sign-in expired. Try again.');
    });

    test('a web return needs the verifier saved for this server', () async {
      final auth = ssoStore((_) => null);
      expect(
        await auth.completeSsoReturn(
          Uri.parse('http://server.test/sso?sso_code=abc'),
        ),
        isFalse,
      );
      expect(auth.error, 'This sign-in expired. Try again.');

      challenge = base64UrlEncode(
        sha256.convert(utf8.encode('saved-verifier')).bytes,
      ).replaceAll('=', '');
      SharedPreferences.setMockInitialValues({
        'sticky_notes_sso_pending': jsonEncode({
          'verifier': 'saved-verifier',
          'server': 'http://server.test',
        }),
      });
      expect(
        await auth.completeSsoReturn(
          Uri.parse('http://server.test/sso?sso_code=abc'),
        ),
        isTrue,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sticky_notes_sso_pending'), isNull);
    });
  });

  group('profile picture', () {
    test('a new picture is uploaded and its version kept', () async {
      seedSession();
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2]);
      final sent = <http.Request>[];
      final auth = storeWith(
        MockClient((request) async {
          sent.add(request);
          if (request.method == 'PUT') return http.Response('', 204);
          return http.Response(
            jsonEncode({
              'id': 'u-me',
              'name': 'Me',
              'email': 'me@example.com',
              'avatar': 7,
            }),
            200,
          );
        }),
      );
      await auth.restore();
      sent.clear();

      await auth.setAvatar(png);

      final put = sent.firstWhere((r) => r.method == 'PUT');
      expect(put.url.path, '/api/auth/me/avatar');
      expect(put.headers['content-type'], 'image/png');
      expect(put.bodyBytes, png);
      expect(auth.user!.avatar, 7);
      final prefs = await SharedPreferences.getInstance();
      final cached = jsonDecode(prefs.getString('sticky_notes_user')!);
      expect(cached['avatar'], 7);
    });

    test('a picture nobody may see reads as none', () async {
      final api = ApiClient(
        baseUrl: 'http://server.test',
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      expect(await api.fetchAvatar('u-other', 3), isNull);
    });
  });
}

/// Stands in for a transport failure (`SocketException` on mobile) without
/// pulling in `dart:io`, which the test host shares with the web build.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
