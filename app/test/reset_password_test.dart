import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/screens/reset_password_screen.dart';
import 'package:skippy/theme.dart';
import 'package:skippy/util/public_route.dart';
import 'package:skippy/widgets/form_error_banner.dart';

import 'fake_api.dart';

Widget resetApp(FakeApi api, {required ValueChanged<String?> onDone}) =>
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: ResetPasswordScreen(token: 'abc123', api: api, onDone: onDone),
    );

Future<void> typeBoth(
  WidgetTester tester,
  String password,
  String confirm,
) async {
  await tester.enterText(
    find.ancestor(
      of: find.text('New password'),
      matching: find.byType(TextField),
    ),
    password,
  );
  await tester.enterText(
    find.ancestor(
      of: find.text('Confirm password'),
      matching: find.byType(TextField),
    ),
    confirm,
  );
}

void main() {
  group('reset link routing', () {
    test('only a hex token under /reset/ resolves', () {
      expect(passwordResetToken('/reset/deadbeef'), 'deadbeef');
      // A trailing slash or query is still the same link.
      expect(passwordResetToken('/reset/deadbeef/'), 'deadbeef');
      expect(passwordResetToken('/reset/deadbeef?from=mail'), 'deadbeef');
      // A deployment under a sub-path.
      expect(passwordResetToken('/notes/reset/deadbeef'), 'deadbeef');
      expect(passwordResetToken('/reset/'), isNull);
      expect(passwordResetToken('/reset/not-hex'), isNull);
      expect(passwordResetToken('/s/deadbeef'), isNull);
      expect(passwordResetToken('/'), isNull);
    });

    test('the two link routes do not answer for each other', () {
      expect(publicShareToken('/reset/deadbeef'), isNull);
      expect(passwordResetToken('/s/deadbeef'), isNull);
    });
  });

  testWidgets('a new password is set and hands the address back', (
    tester,
  ) async {
    final api = FakeApi()..resetTokens = {'abc123': 'ada@example.test'};
    String? done;
    var calls = 0;
    await tester.pumpWidget(
      resetApp(
        api,
        onDone: (email) {
          calls++;
          done = email;
        },
      ),
    );
    await tester.pumpAndSettle();

    await typeBoth(tester, 'new-hunter22', 'new-hunter22');
    await tester.tap(find.widgetWithText(FilledButton, 'Set new password'));
    await tester.pumpAndSettle();

    expect(api.log, contains('resetPassword'));
    expect(find.text('Password updated'), findsOneWidget);
    // Nothing happens until the person asks to go on to signing in.
    expect(calls, 0);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(done, 'ada@example.test');
  });

  testWidgets('a mismatch and a short password are caught before the server', (
    tester,
  ) async {
    final api = FakeApi()..resetTokens = {'abc123': 'ada@example.test'};
    await tester.pumpWidget(resetApp(api, onDone: (_) {}));
    await tester.pumpAndSettle();

    await typeBoth(tester, 'new-hunter22', 'different');
    await tester.tap(find.widgetWithText(FilledButton, 'Set new password'));
    await tester.pumpAndSettle();
    expect(find.text("Passwords don't match"), findsOneWidget);
    expect(api.log, isNot(contains('resetPassword')));

    // Too short never leaves either, so a rejected attempt cannot look like it
    // spent the link.
    await typeBoth(tester, 'abc', 'abc');
    await tester.tap(find.widgetWithText(FilledButton, 'Set new password'));
    await tester.pumpAndSettle();
    expect(find.text('Use at least 6 characters'), findsOneWidget);
    expect(api.log, isNot(contains('resetPassword')));

    // And the link still works once the password is acceptable.
    await typeBoth(tester, 'new-hunter22', 'new-hunter22');
    await tester.tap(find.widgetWithText(FilledButton, 'Set new password'));
    await tester.pumpAndSettle();
    expect(find.text('Password updated'), findsOneWidget);
  });

  testWidgets('a spent link says so and offers the way back', (tester) async {
    // No tokens registered: the fake refuses exactly as the server does.
    final api = FakeApi();
    String? done;
    var calls = 0;
    await tester.pumpWidget(
      resetApp(
        api,
        onDone: (email) {
          calls++;
          done = email;
        },
      ),
    );
    await tester.pumpAndSettle();

    await typeBoth(tester, 'new-hunter22', 'new-hunter22');
    await tester.tap(find.widgetWithText(FilledButton, 'Set new password'));
    await tester.pumpAndSettle();

    expect(
      find.text('this reset link has expired or was already used'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Back to sign in'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(done, isNull);
  });

  testWidgets('an unreachable server is described, not swallowed', (
    tester,
  ) async {
    final api = FakeApi()
      ..passwordResetError = Exception('Failed host lookup: server.test');
    await tester.pumpWidget(resetApp(api, onDone: (_) {}));
    await tester.pumpAndSettle();

    await typeBoth(tester, 'new-hunter22', 'new-hunter22');
    await tester.tap(find.widgetWithText(FilledButton, 'Set new password'));
    await tester.pumpAndSettle();

    expect(find.byType(FormErrorBanner), findsOneWidget);
    expect(find.text('Password updated'), findsNothing);
  });
}
