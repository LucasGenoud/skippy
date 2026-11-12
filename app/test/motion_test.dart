import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/util/motion.dart';

void main() {
  testWidgets('a view swap rises the new notes in and sinks the old ones', (
    tester,
  ) async {
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

    // The new set is still below its place, on its way up; the old one has
    // left its place, on its way down.
    expect(tester.getTopLeft(find.text('new')).dy, greaterThan(rest));
    expect(tester.getTopLeft(find.text('old')).dy, greaterThan(rest));

    await tester.pumpAndSettle();
    expect(find.text('old'), findsNothing);
    expect(tester.getTopLeft(find.text('new')).dy, rest);
  });
}
