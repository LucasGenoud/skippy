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

/// [server] answers every request; the default never gets called, the tests
/// that submit the form supply their own failure.
Widget loginApp({http.Client? server}) => ChangeNotifierProvider(
  create: (_) => AuthStore(
    api: ApiClient(baseUrl: 'http://server.test', httpClient: server),
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
}
