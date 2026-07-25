import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/widgets/background_guard.dart';

void main() {
  testWidgets(
    'backgrounding unfocuses the field and fires the flush once per trip',
    (tester) async {
      var flushes = 0;
      var returns = 0;
      final focus = FocusNode();
      await tester.pumpWidget(
        MaterialApp(
          home: BackgroundGuard(
            onBackground: () => flushes++,
            onForeground: () => returns++,
            child: Scaffold(body: TextField(focusNode: focus)),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      void lifecycle(List<AppLifecycleState> states) {
        for (final s in states) {
          tester.binding.handleAppLifecycleStateChanged(s);
        }
      }

      // iOS backgrounding walks inactive → hidden → paused; one trip, one
      // flush, and the text-input session closes before the app suspends.
      lifecycle(const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);
      await tester.pump();
      expect(focus.hasFocus, isFalse);
      expect(flushes, 1);

      // Coming back re-arms the guard for the next trip, and reports once.
      lifecycle(const [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      expect(flushes, 1);
      expect(returns, 1);

      // An interruption that never suspends the app is not a return trip.
      lifecycle(const [AppLifecycleState.inactive, AppLifecycleState.resumed]);
      expect(returns, 1);
      lifecycle(const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);
      await tester.pump();
      expect(flushes, 2);

      lifecycle(const [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      expect(returns, 2);
      focus.dispose();
    },
  );
}
