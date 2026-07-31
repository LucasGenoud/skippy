import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/state/settings_store.dart';
import 'package:skippy/widgets/particle_field.dart';

/// Wraps the field in a sized surface, optionally with "reduce motion" on.
Future<void> pumpField(
  WidgetTester tester, {
  required ParticleEffect effect,
  ParticleIntensity intensity = ParticleIntensity.medium,
  bool reduceMotion = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Center(
          child: SizedBox(
            width: 400,
            height: 300,
            child: ParticleField(effect: effect, intensity: intensity),
          ),
        ),
      ),
    ),
  );
}

/// CustomPaints from the surrounding MaterialApp don't count.
final painter = find.descendant(
  of: find.byType(ParticleField),
  matching: find.byType(CustomPaint),
);

void main() {
  testWidgets('the off state builds no painter at all', (tester) async {
    await pumpField(tester, effect: ParticleEffect.none);

    expect(painter, findsNothing);
    // Nothing is animating, so the frame queue drains.
    await tester.pumpAndSettle();
  });

  for (final effect in ParticleEffect.values.where(
    (e) => e != ParticleEffect.none,
  )) {
    testWidgets('${effect.name} paints and keeps animating', (tester) async {
      await pumpField(tester, effect: effect);

      expect(painter, findsOneWidget);
      // Past the ~30fps repaint interval: the ticker is still scheduling
      // frames, which is what an endless ambient effect should do.
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isTrue);
    });
  }

  testWidgets('reduce motion freezes the field instead of hiding it', (
    tester,
  ) async {
    await pumpField(tester, effect: ParticleEffect.snow, reduceMotion: true);

    expect(painter, findsOneWidget);
    // No ticker, so the frame queue drains rather than running forever.
    await tester.pumpAndSettle();
  });

  testWidgets('switching to the off state stops the ticker', (tester) async {
    await pumpField(tester, effect: ParticleEffect.confetti);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isTrue);

    await pumpField(tester, effect: ParticleEffect.none);

    await tester.pumpAndSettle();
    expect(painter, findsNothing);
  });

  testWidgets('the layer never takes a pointer from the notes under it', (
    tester,
  ) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => tapped = true,
              ),
            ),
            const Positioned.fill(
              child: ParticleField(
                effect: ParticleEffect.glitter,
                intensity: ParticleIntensity.lively,
              ),
            ),
          ],
        ),
      ),
    );

    await tester.tapAt(const Offset(200, 200));
    expect(tapped, isTrue);
  });
}
