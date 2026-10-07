import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/util/motion.dart';
import 'package:skippy/widgets/animated_presence.dart';
import 'package:skippy/widgets/animated_reveal.dart';

void main() {
  Widget column(List<String> items) => MaterialApp(
    home: Scaffold(
      body: AnimatedPresence(
        layout: (children) => Column(children: children),
        children: [
          for (final item in items)
            SizedBox(key: ValueKey(item), height: 20, child: Text(item)),
        ],
      ),
    ),
  );

  List<String> shown(WidgetTester tester) => [
    for (final text in tester.widgetList<Text>(find.byType(Text))) text.data!,
  ];

  double heightOf(WidgetTester tester, String item) => tester
      .getSize(find.byType(SizeTransition).at(shown(tester).indexOf(item)))
      .height;

  testWidgets('children present at first build show at full size', (
    tester,
  ) async {
    await tester.pumpWidget(column(['a', 'b']));
    expect(heightOf(tester, 'a'), 20);
    expect(heightOf(tester, 'b'), 20);
  });

  testWidgets('a leaving child keeps its slot until its exit ends', (
    tester,
  ) async {
    await tester.pumpWidget(column(['a', 'b', 'c']));
    await tester.pumpWidget(column(['a', 'c', 'd']));
    expect(shown(tester), ['a', 'b', 'c', 'd']);

    await tester.pump(Motion.fast ~/ 2);
    expect(heightOf(tester, 'b'), inExclusiveRange(0, 20));
    expect(heightOf(tester, 'd'), inExclusiveRange(0, 20));

    await tester.pumpAndSettle();
    expect(shown(tester), ['a', 'c', 'd']);
    expect(heightOf(tester, 'd'), 20);
  });

  testWidgets('a child returning mid-exit stays', (tester) async {
    await tester.pumpWidget(column(['a', 'b']));
    await tester.pumpWidget(column(['a']));
    await tester.pump(Motion.fast ~/ 2);
    await tester.pumpWidget(column(['a', 'b']));
    await tester.pumpAndSettle();
    expect(shown(tester), ['a', 'b']);
    expect(heightOf(tester, 'b'), 20);
  });

  // A row taller than its items (the desktop top bar) must not stretch a
  // horizontal item to its height, which pinned the icon to the top edge.
  testWidgets('a horizontal item keeps its own height in a taller row', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            height: 60,
            child: Row(
              children: [
                AnimatedPresence(
                  axis: Axis.horizontal,
                  layout: (children) =>
                      Row(mainAxisSize: MainAxisSize.min, children: children),
                  children: const [
                    SizedBox(key: ValueKey('in'), width: 40, height: 40),
                  ],
                ),
                const SizedBox(key: ValueKey('beside'), width: 40, height: 40),
              ],
            ),
          ),
        ),
      ),
    );
    final item = tester.getRect(find.byKey(const ValueKey('in')).last);
    final beside = tester.getRect(find.byKey(const ValueKey('beside')));
    expect(tester.getSize(find.byType(SizeTransition)).height, 40);
    expect(item.center.dy, beside.center.dy);
  });

  testWidgets('a revealed child grows in and collapses out', (tester) async {
    Widget reveal(String? text) => MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            AnimatedReveal(
              child: text == null
                  ? null
                  : SizedBox(height: 40, child: Text(text)),
            ),
          ],
        ),
      ),
    );
    Size size() => tester.getSize(find.byType(AnimatedReveal));

    await tester.pumpWidget(reveal(null));
    expect(size().height, 0);

    await tester.pumpWidget(reveal('Error'));
    await tester.pump(Motion.base ~/ 3);
    expect(size().height, inExclusiveRange(0, 40));
    await tester.pumpAndSettle();
    expect(size().height, 40);

    await tester.pumpWidget(reveal(null));
    await tester.pump(Motion.base ~/ 3);
    expect(find.text('Error'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(size().height, 0);
    expect(find.text('Error'), findsNothing);
  });
}
