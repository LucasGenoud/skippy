import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skippy/api/api_client.dart';
import 'package:skippy/screens/login_screen.dart';
import 'package:skippy/state/auth_store.dart';
import 'package:skippy/theme.dart';
import 'package:skippy/widgets/login_field.dart';

/// A server that only answers the capability probe the login screen makes on
/// mount, with password reset [passwordReset]. Everything else 404s; the tests
/// that submit the form supply their own [server].
http.Client capabilityServer({bool passwordReset = false}) =>
    MockClient((request) async {
      if (request.url.path.endsWith('/capabilities')) {
        return http.Response('{"password_reset": $passwordReset}', 200);
      }
      return http.Response('', 404);
    });

/// [server] answers every request, including the capability probe, so a test
/// that supplies one has to answer that too (or accept reset being hidden).
Widget loginApp({http.Client? server, bool passwordReset = false}) =>
    ChangeNotifierProvider(
      create: (_) => AuthStore(
        api: ApiClient(
          baseUrl: 'http://server.test',
          httpClient: server ?? capabilityServer(passwordReset: passwordReset),
        ),
      ),
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const LoginScreen(),
      ),
    );

/// The login input labelled [label]. Read through [LoginField] rather than
/// [TextField]: the web builds a DOM `<input>` instead, and the autofill
/// identity has to be right on both.
LoginField loginField(WidgetTester tester, String label) => tester.widget(
  find.ancestor(of: find.text(label), matching: find.byType(LoginField)),
);

/// The autofill hint on the password field, whichever mode is active.
String passwordHint(WidgetTester tester) =>
    loginField(tester, 'Password').autofillHint;

String emailHint(WidgetTester tester) =>
    loginField(tester, 'Email').autofillHint;

void main() {
  testWidgets('sign-in mode hides confirm and uses current-password hint', (
    tester,
  ) async {
    await tester.pumpWidget(loginApp());
    await tester.pumpAndSettle();

    // Sign in is the default: email + password, no name or confirmation.
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Full name'), findsNothing);
    expect(find.text('Confirm password'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    // The account identifier is an email, but browsers recognize this as the
    // login half of a saved credential only when it is marked `username`.
    expect(emailHint(tester), AutofillHints.username);
    expect(passwordHint(tester), AutofillHints.password);
  });

  testWidgets('create-account mode reveals confirm and new-password hint', (
    tester,
  ) async {
    await tester.pumpWidget(loginApp());
    await tester.pumpAndSettle();

    // Switch via the segmented control.
    await tester.tap(find.text('Create account').first);
    await tester.pumpAndSettle();

    expect(find.text('Confirm password'), findsOneWidget);
    expect(find.text('Full name'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Create account'), findsOneWidget);
    expect(emailHint(tester), AutofillHints.email);
    // A new-password hint is what makes managers offer to generate/save.
    expect(passwordHint(tester), AutofillHints.newPassword);
  });

  testWidgets('create-account name supports spaces and text selection', (
    tester,
  ) async {
    await tester.pumpWidget(loginApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create account').first);
    await tester.pumpAndSettle();

    final nameFinder = find.ancestor(
      of: find.text('Full name'),
      matching: find.byType(TextField),
    );
    await tester.enterText(nameFinder, 'Alice Example');

    final field = tester.widget<TextField>(nameFinder);
    field.controller!.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 5,
    );

    expect(field.controller!.text, 'Alice Example');
    expect(
      field.controller!.selection.textInside(field.controller!.text),
      'Alice',
    );
  });

  testWidgets('mismatched passwords block submit with an inline error', (
    tester,
  ) async {
    await tester.pumpWidget(loginApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create account').first);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.ancestor(
        of: find.text('Full name'),
        matching: find.byType(TextField),
      ),
      'Alice Example',
    );
    await tester.enterText(
      find.ancestor(of: find.text('Email'), matching: find.byType(TextField)),
      'alice@example.test',
    );
    await tester.enterText(
      find.ancestor(
        of: find.text('Password'),
        matching: find.byType(TextField),
      ),
      'secret1',
    );
    await tester.enterText(
      find.ancestor(
        of: find.text('Confirm password'),
        matching: find.byType(TextField),
      ),
      'secret2',
    );
    final submit = find.widgetWithText(FilledButton, 'Create account');
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(find.text("Passwords don't match"), findsOneWidget);
  });

  testWidgets('empty fields show inline errors instead of doing nothing', (
    tester,
  ) async {
    await tester.pumpWidget(loginApp());
    await tester.pumpAndSettle();

    // Press Sign in without typing anything, the old behaviour returned
    // silently, leaving the user with no feedback.
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Enter your email'), findsOneWidget);
    expect(find.text('Enter your password'), findsOneWidget);
  });

  testWidgets('a failure with no server message still fills the banner', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    // Pointing the app at a plain web server: /api/auth/login is a zero-length
    // 404, which used to paint the red banner with nothing written in it.
    await tester.pumpWidget(
      loginApp(server: MockClient((_) async => http.Response('', 404))),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.ancestor(of: find.text('Email'), matching: find.byType(TextField)),
      'alice@example.test',
    );
    await tester.enterText(
      find.ancestor(
        of: find.text('Password'),
        matching: find.byType(TextField),
      ),
      'secret1',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    // The banner is the icon plus one Text; that Text has to carry something
    // an operator can act on.
    final banner = find.ancestor(
      of: find.byIcon(Icons.error_outline),
      matching: find.byType(Container),
    );
    expect(banner, findsWidgets);
    final message = tester.widget<Text>(
      find.descendant(of: banner.first, matching: find.byType(Text)),
    );
    expect(message.data, isNotNull);
    expect(message.data!.trim(), isNotEmpty);
    expect(message.data, contains('404'));
  });

  testWidgets('typing clears the matching empty-field error', (tester) async {
    await tester.pumpWidget(loginApp());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your email'), findsOneWidget);

    // Typing in the email field clears its error but leaves the other.
    await tester.enterText(
      find.ancestor(of: find.text('Email'), matching: find.byType(TextField)),
      'alice@example.test',
    );
    await tester.pumpAndSettle();

    expect(find.text('Enter your email'), findsNothing);
    expect(find.text('Enter your password'), findsOneWidget);
  });

  testWidgets('forgot password stays hidden when the server cannot mail', (
    tester,
  ) async {
    await tester.pumpWidget(loginApp());
    await tester.pumpAndSettle();

    expect(find.text('Forgot password?'), findsNothing);
  });

  testWidgets('forgot password is offered only while signing in', (
    tester,
  ) async {
    await tester.pumpWidget(loginApp(passwordReset: true));
    await tester.pumpAndSettle();

    expect(find.text('Forgot password?'), findsOneWidget);

    // Creating an account has nothing to reset.
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();
    expect(find.text('Forgot password?'), findsNothing);

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Forgot password?'), findsOneWidget);
  });

  testWidgets('the reset dialog opens prefilled and confirms without saying '
      'whether the account exists', (tester) async {
    final asked = <String>[];
    final server = MockClient((request) async {
      if (request.url.path.endsWith('/capabilities')) {
        return http.Response('{"password_reset": true}', 200);
      }
      if (request.url.path.endsWith('/auth/forgot-password')) {
        asked.add(request.body);
        return http.Response('', 202);
      }
      return http.Response('', 404);
    });
    await tester.pumpWidget(loginApp(server: server));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.ancestor(of: find.text('Email'), matching: find.byType(TextField)),
      'ada@example.test',
    );
    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();

    // The address already typed into the form carries into the dialog.
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextField),
            ),
          )
          .controller
          ?.text,
      'ada@example.test',
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Send link'));
    await tester.pumpAndSettle();

    expect(asked, [
      jsonEncode({'email': 'ada@example.test'}),
    ]);
    expect(find.text('Check your email'), findsOneWidget);
    expect(
      find.textContaining('If ada@example.test has an account here'),
      findsOneWidget,
    );
  });

  testWidgets('a server that refuses the reset says so in the dialog', (
    tester,
  ) async {
    final server = MockClient((request) async {
      if (request.url.path.endsWith('/capabilities')) {
        return http.Response('{"password_reset": true}', 200);
      }
      return http.Response(
        '{"error":"this server cannot send password reset email"}',
        503,
      );
    });
    await tester.pumpWidget(loginApp(server: server));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.ancestor(of: find.text('Email'), matching: find.byType(TextField)),
      'ada@example.test',
    );
    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send link'));
    await tester.pumpAndSettle();

    expect(
      find.text('this server cannot send password reset email'),
      findsOneWidget,
    );
    // Still on the form, so the address can be corrected and retried.
    expect(find.widgetWithText(FilledButton, 'Send link'), findsOneWidget);
  });

  testWidgets('an empty address is refused before any request', (tester) async {
    var requests = 0;
    final server = MockClient((request) async {
      if (request.url.path.endsWith('/capabilities')) {
        return http.Response('{"password_reset": true}', 200);
      }
      requests++;
      return http.Response('', 202);
    });
    await tester.pumpWidget(loginApp(server: server));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send link'));
    await tester.pumpAndSettle();

    expect(find.text('Enter your email'), findsOneWidget);
    expect(requests, 0);
  });

  testWidgets('an emailed address prefills the sign-in form', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AuthStore(
          api: ApiClient(
            baseUrl: 'http://server.test',
            httpClient: capabilityServer(),
          ),
        ),
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const LoginScreen(initialEmail: 'ada@example.test'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ada@example.test'), findsOneWidget);
  });
}
