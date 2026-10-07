import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/widgets/audio_player_view.dart';

void main() {
  testWidgets('shows elapsed and total time and toggles on tap', (
    tester,
  ) async {
    var toggles = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AudioPlayerView(
            playing: false,
            position: 65,
            duration: 125,
            onToggle: () => toggles++,
            onSeek: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('1:05 / 2:05'), findsOneWidget);
    await tester.tap(find.byType(AnimatedIcon));
    expect(toggles, 1);
  });
}
