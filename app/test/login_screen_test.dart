import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/api/api_client.dart';
import 'package:skippy/screens/login_screen.dart';
import 'package:skippy/state/auth_store.dart';
import 'package:skippy/theme.dart';
import 'package:skippy/widgets/login_field.dart';

Widget loginApp() => ChangeNotifierProvider(
  create: (_) => AuthStore(api: ApiClient(baseUrl: 'http://unused')),
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
    // The web maps these onto `name`/`id`, which managers weigh too.
    expect(loginField(tester, 'Email').fieldName, 'email');
    expect(loginField(tester, 'Password').fieldName, 'password');
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

    // Press Sign in without typing anything — the old behaviour returned
    // silently, leaving the user with no feedback.
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Enter your email'), findsOneWidget);
    expect(find.text('Enter your password'), findsOneWidget);
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
