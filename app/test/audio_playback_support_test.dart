import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/widgets/audio_player.dart';

/// `just_audio` has no Windows or Linux engine. The player has to say so
/// instead of building a play button that throws a MissingPluginException the
/// moment the URL loads.
void main() {
  Widget player() => const MaterialApp(
    home: Scaffold(
      body: AudioPlayerBar(url: 'http://localhost:8787/api/files/abc'),
    ),
  );

  test('only the desktops without a playback engine are excluded', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      expect(
        audioPlaybackSupported,
        platform != TargetPlatform.windows && platform != TargetPlatform.linux,
        reason: '$platform',
      );
    }
  });

  testWidgets(
    'an unsupported desktop explains itself instead of failing',
    (tester) async {
      await tester.pumpWidget(player());
      await tester.pump();

      expect(find.textContaining('Playback is not supported'), findsOneWidget);
      expect(find.byIcon(Icons.music_off_outlined), findsOneWidget);
      // The play/pause control is what would need the missing engine.
      expect(find.byType(AnimatedIcon), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
