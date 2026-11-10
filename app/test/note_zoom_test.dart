import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/util/motion.dart';
import 'package:skippy/widgets/note_zoom.dart';

void main() {
  testWidgets('the flying card face is built once, not every frame', (
    tester,
  ) async {
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 160,
              height: 120,
              child: NoteZoom(
                closedColor: Colors.white,
                openColor: Colors.white,
                closedShape: const RoundedRectangleBorder(),
                openBuilder: (_) => const Scaffold(body: Text('Open')),
                closedBuilder: (_, open) {
                  builds++;
                  return GestureDetector(
                    onTap: open,
                    child: const Text('Card'),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Card'));
    builds = 0;
    for (var i = 0; i < Motion.slow.inMilliseconds ~/ 16; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // The source hiding rebuilds it once and the route builds its copy once;
    // the frames in between only move pixels.
    expect(builds, lessThanOrEqualTo(2));
    await tester.pumpAndSettle();
  });
}
