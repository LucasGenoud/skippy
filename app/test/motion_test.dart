import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/util/motion.dart';
import 'package:skippy/util/page_slide.dart';

void main() {
  testWidgets(
    'a view swap fades the old notes out in place and rises the new ones in',
    (tester) async {
      var view = 'old';
      late StateSetter setView;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              setView = setState;
              return Align(
                alignment: Alignment.topCenter,
                child: AnimatedSwitcher(
                  duration: Motion.base,
                  transitionBuilder: Motion.viewSwap,
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.topCenter,
                    children: [...previous, ?current],
                  ),
                  child: SizedBox(
                    key: ValueKey(view),
                    width: 100,
                    height: 100,
                    child: Text(view),
                  ),
                ),
              );
            },
          ),
        ),
      );
      final rest = tester.getTopLeft(find.text('old')).dy;

      setView(() => view = 'new');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The new set is still below its place, on its way up; the old one
      // fades where it is.
      expect(tester.getTopLeft(find.text('new')).dy, greaterThan(rest));
      expect(tester.getTopLeft(find.text('old')).dy, rest);

      await tester.pumpAndSettle();
      expect(find.text('old'), findsNothing);
      expect(tester.getTopLeft(find.text('new')).dy, rest);
    },
  );

  testWidgets('a pushed page slides in from the right within the ceiling', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: ThemeData(
          pageTransitionsTheme: PageSlideTransitionsBuilder.theme,
        ),
        home: const Text('home'),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('page')),
    );
    await tester.pump();
    await tester.pump(Motion.base ~/ 4);

    // Partway: right of its place and still fading in.
    expect(tester.getTopLeft(find.text('page')).dx, greaterThan(0));
    await tester.pump(Motion.slow);
    expect(tester.getTopLeft(find.text('page')).dx, 0);

    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(Motion.fast ~/ 2);

    // Leaving the way it came, and gone within the shorter exit.
    expect(tester.getTopLeft(find.text('page')).dx, greaterThan(0));
    await tester.pump(Motion.fast);
    expect(find.text('page'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
