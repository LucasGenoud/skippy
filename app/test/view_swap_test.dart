import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/widgets/view_swap.dart';

void main() {
  testWidgets('a new view rises in, and the old one leaves as a picture', (
    tester,
  ) async {
    var view = 'board';
    late StateSetter setView;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            setView = setState;
            return ViewSwap(
              viewKey: view,
              child: Align(alignment: Alignment.topLeft, child: Text(view)),
            );
          },
        ),
      ),
    );
    final rest = tester.getTopLeft(find.text('board')).dy;

    setView(() => view = 'grid');
    await tester.pump();

    // The old view no longer runs: it cannot redraw itself as the new one.
    expect(find.text('board'), findsNothing);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getTopLeft(find.text('grid')).dy, greaterThan(rest));

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('grid')).dy, rest);
    expect(find.byType(RawImage), findsNothing);
  });

  testWidgets('the first view is simply there', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ViewSwap(
          viewKey: 'grid',
          child: Align(alignment: Alignment.topLeft, child: Text('grid')),
        ),
      ),
    );
    expect(tester.getTopLeft(find.text('grid')).dy, 0);
  });
}
