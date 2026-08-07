import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/widgets/screen_width.dart';

void main() {
  testWidgets('a breakpoint only rebuilds when the answer changes', (
    tester,
  ) async {
    var builds = 0;
    var compact = false;

    Widget app() => MaterialApp(
      builder: (context, child) =>
          ScreenWidth(child: child ?? const SizedBox()),
      home: Builder(
        builder: (context) {
          builds++;
          compact = !ScreenWidth.isAtLeast(context, 600);
          return const SizedBox();
        },
      ),
    );

    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());
    expect(compact, isFalse);
    final afterFirst = builds;

    // Still wide: the width moved but the answer did not.
    tester.view.physicalSize = const Size(800, 1000);
    await tester.pumpAndSettle();
    expect(builds, afterFirst, reason: 'same side of the breakpoint');

    // The height alone must never rebuild a width-only consumer: this is the
    // keyboard case on Android, where the view shrinks as it slides up.
    tester.view.physicalSize = const Size(800, 500);
    await tester.pumpAndSettle();
    expect(builds, afterFirst, reason: 'height changed, width did not');

    // Crossing it does rebuild, with the new answer.
    tester.view.physicalSize = const Size(500, 500);
    await tester.pumpAndSettle();
    expect(builds, greaterThan(afterFirst));
    expect(compact, isTrue);
  });

  testWidgets('falls back to MediaQuery when nothing published a width', (
    tester,
  ) async {
    late bool wide;
    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            wide = ScreenWidth.isAtLeast(context, 600);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(wide, isTrue);
  });
}
