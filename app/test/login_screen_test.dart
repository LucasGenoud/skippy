import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sticky_notes/api/api_client.dart';
import 'package:sticky_notes/screens/login_screen.dart';
import 'package:sticky_notes/state/auth_store.dart';
import 'package:sticky_notes/theme.dart';

Widget loginApp() => ChangeNotifierProvider(
  create: (_) => AuthStore(api: ApiClient(baseUrl: 'http://unused')),
  child: MaterialApp(
    theme: buildTheme(Brightness.light),
    home: const LoginScreen(),
  ),
);

/// The autofill hints on the password field, whichever mode is active.
List<String>? passwordHints(WidgetTester tester) {
  final field = tester.widget<TextField>(
    find.ancestor(
      of: find.text('Password'),
      matching: find.byType(TextField),
    ),
  );
  return field.autofillHints?.toList();
}

void main() {
  testWidgets('sign-in mode hides confirm and uses current-password hint',
      (tester) async {
    await tester.pumpWidget(loginApp());
    await tester.pumpAndSettle();

    // Sign in is the default: one password field, no confirm.
    expect(find.text('Confirm password'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    expect(passwordHints(tester), [AutofillHints.password]);
  });

  testWidgets('create-account mode reveals confirm and new-password hint',
      (tester) async {
    await tester.pumpWidget(loginApp());
    await tester.pumpAndSettle();

    // Switch via the segmented control.
    await tester.tap(find.text('Create account').first);
    await tester.pumpAndSettle();

    expect(find.text('Confirm password'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Create account'), findsOneWidget);
    // A new-password hint is what makes managers offer to generate/save.
    expect(passwordHints(tester), [AutofillHints.newPassword]);
  });

  testWidgets('mismatched passwords block submit with an inline error',
      (tester) async {
    await tester.pumpWidget(loginApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create account').first);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.ancestor(
        of: find.text('Username'),
        matching: find.byType(TextField),
      ),
      'alice',
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
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pumpAndSettle();

    expect(find.text("Passwords don't match"), findsOneWidget);
  });
}
