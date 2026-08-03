import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/widgets/audio_waveform.dart';

void main() {
  testWidgets('waveform paints and seeks to the tapped position', (
    tester,
  ) async {
    double? sought;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              child: AudioWaveform(
                position: 2,
                duration: 10,
                activeColor: Colors.blue,
                inactiveColor: Colors.grey,
                cursorColor: Colors.white,
                onSeek: (seconds) => sought = seconds,
              ),
            ),
          ),
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byType(AudioWaveform),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
    final waveform = tester.getCenter(find.byType(AudioWaveform));
    await tester.tapAt(waveform + const Offset(50, 0));
    expect(sought, closeTo(7.5, 0.1));

    await tester.dragFrom(waveform - const Offset(80, 0), const Offset(160, 0));
    expect(sought, closeTo(9, 0.1));
  });
}
