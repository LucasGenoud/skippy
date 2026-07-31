import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../state/settings_store.dart';
import '../util/motion.dart';

/// The decorative particle layer that runs behind the notes.
///
/// It is built to be forgettable rather than impressive, three things keep it
/// off the frame budget:
///
/// * a particle's position is a pure function of elapsed time and its own
///   seed. Nothing is stepped or accumulated, so there is no drift, no state
///   to keep in sync, and a skipped frame costs exactly nothing;
/// * the ticker drives a [ValueNotifier] that the painter repaints from, so a
///   frame repaints one [RepaintBoundary] instead of rebuilding any widget;
/// * repaints are capped at [_frameInterval] (~30fps). Drifting snow reads the
///   same at 30 as at 120, and the cap halves the work on a fast display.
///
/// The ticker follows the ambient [TickerMode], and a backgrounded app is not
/// asked for frames at all, so neither case keeps painting. "Reduce motion"
/// freezes the field at its first frame rather than removing it.
class ParticleField extends StatefulWidget {
  final ParticleEffect effect;
  final ParticleIntensity intensity;

  /// Colors [ParticleEffect.confetti] is cut from. The home screen passes the
  /// user's note palette so the confetti matches the cards it falls behind;
  /// empty falls back to the default palette.
  final List<Color> palette;

  /// Multiplies the particle count that the canvas area asks for. Only the
  /// settings preview uses it: a 150px-tall window is honestly worth about
  /// four flakes, which reads as a bug rather than as snow, so the sample is
  /// packed tighter than the real background it stands for.
  final double densityBoost;

  const ParticleField({
    super.key,
    required this.effect,
    required this.intensity,
    this.palette = const [],
    this.densityBoost = 1,
  });

  @override
  State<ParticleField> createState() => _ParticleFieldState();
}

class _ParticleFieldState extends State<ParticleField>
    with SingleTickerProviderStateMixin {
  /// ~30fps. Fast enough that nothing steps visibly, half the repaints of a
  /// 60Hz display and a quarter of a 120Hz one.
  static const Duration _frameInterval = Duration(milliseconds: 33);

  /// One pool per effect, sized for the largest sensible canvas at the
  /// liveliest intensity; [_count] takes a prefix of it. Particles are in unit
  /// space, so a resize changes how many are drawn, never which.
  static const int _poolSize = 160;

  late final Ticker _ticker = createTicker(_onTick);
  final ValueNotifier<double> _seconds = ValueNotifier<double>(0);
  Duration _lastFrame = Duration.zero;
  late List<_Particle> _pool = _buildPool(widget.effect);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTicker();
  }

  @override
  void didUpdateWidget(ParticleField old) {
    super.didUpdateWidget(old);
    // A fresh pool per effect: each one seeds its particles differently, and
    // reusing the previous effect's spread would look off.
    if (old.effect != widget.effect) _pool = _buildPool(widget.effect);
    _syncTicker();
  }

  void _syncTicker() {
    final animate =
        widget.effect != ParticleEffect.none && !Motion.reduced(context);
    if (animate && !_ticker.isActive) {
      _lastFrame = Duration.zero;
      _ticker.start();
    } else if (!animate && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    if (elapsed - _lastFrame < _frameInterval) return;
    _lastFrame = elapsed;
    _seconds.value = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
  }

  static List<_Particle> _buildPool(ParticleEffect effect) {
    // Seeded by the effect so a given effect always looks the same, and so a
    // hot restart doesn't reshuffle the background under the user.
    final random = math.Random(effect.index * 7919 + 17);
    double unit() => random.nextDouble();
    double signed() => random.nextDouble() * 2 - 1;
    return [
      for (var i = 0; i < _poolSize; i++)
        _Particle(
          x: unit(),
          y: unit(),
          phase: unit(),
          speed: 0.55 + unit() * 0.9,
          scale: unit(),
          sway: signed(),
          spin: signed() < 0 ? -1 : 1,
          tint: i,
        ),
    ];
  }

  /// Particles scale with the visible area so a phone doesn't get a desktop's
  /// worth of snow, then clamp so an ultrawide doesn't get a blizzard.
  int _count(Size size) {
    final areaFactor = (size.width * size.height) / (1000 * 700);
    final base = _spec(widget.effect).baseCount * widget.intensity.factor;
    return (base * areaFactor * widget.densityBoost).round().clamp(
      4,
      _poolSize,
    );
  }

  @override
  void dispose() {
    _ticker.dispose();
    _seconds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.effect == ParticleEffect.none) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = _colorsFor(widget.effect, theme, widget.palette);
    return IgnorePointer(
      child: RepaintBoundary(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            if (size.isEmpty) return const SizedBox.shrink();
            return CustomPaint(
              size: size,
              painter: _ParticlePainter(
                effect: widget.effect,
                particles: _pool,
                count: _count(size),
                colors: colors,
                time: _seconds,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A particle's immutable seed. Every field is a plain number in a known
/// range, the painter maps them onto whatever the current effect needs.
class _Particle {
  /// Horizontal and vertical anchor, both 0..1 of the canvas.
  final double x;
  final double y;

  /// Where in its own cycle the particle starts, 0..1. Also doubles as the
  /// phase offset for its wobble, so no two move together.
  final double phase;

  /// Per-particle rate multiplier, ~0.55..1.45.
  final double speed;

  /// Size multiplier, 0..1.
  final double scale;

  /// Horizontal drift amount, -1..1.
  final double sway;

  /// Rotation direction, -1 or 1.
  final double spin;

  /// Index into the effect's color list.
  final int tint;

  const _Particle({
    required this.x,
    required this.y,
    required this.phase,
    required this.speed,
    required this.scale,
    required this.sway,
    required this.spin,
    required this.tint,
  });
}

/// Per-effect tuning that the widget needs before it has a painter.
class _Spec {
  /// Particles on a 1000x700 canvas at [ParticleIntensity.medium].
  final int baseCount;
  const _Spec(this.baseCount);
}

_Spec _spec(ParticleEffect effect) => switch (effect) {
  ParticleEffect.none => const _Spec(0),
  ParticleEffect.snow => const _Spec(42),
  ParticleEffect.glitter => const _Spec(34),
  ParticleEffect.confetti => const _Spec(30),
  ParticleEffect.bubbles => const _Spec(20),
  ParticleEffect.fireflies => const _Spec(16),
};

/// The palette each effect draws from, tuned per brightness: on the near-white
/// light canvas particles have to go darker than the background to be seen at
/// all, while in dark mode they are the light thing in the room.
List<Color> _colorsFor(
  ParticleEffect effect,
  ThemeData theme,
  List<Color> palette,
) {
  final dark = theme.brightness == Brightness.dark;
  switch (effect) {
    case ParticleEffect.none:
      return const [Colors.transparent];
    case ParticleEffect.snow:
      return [dark ? Colors.white : const Color(0xFF8FA3BC)];
    case ParticleEffect.glitter:
      // The accent, so glitter follows whatever seed the user picked.
      return [theme.colorScheme.primary];
    case ParticleEffect.confetti:
      final source = palette.isEmpty
          ? [for (final entry in kDefaultPalette) entry.light]
          : palette;
      // The palette's light shades are the vivid ones, so both themes use
      // them. They are pastels, though, and a pastel on the near-white light
      // canvas is barely there, so deepen them rather than reaching for the
      // muddy dark shades.
      return dark
          ? source
          : [for (final c in source) Color.lerp(c, Colors.black, 0.22)!];
    case ParticleEffect.bubbles:
      return [theme.colorScheme.primary];
    case ParticleEffect.fireflies:
      return [dark ? const Color(0xFFFFD166) : const Color(0xFFE0A23C)];
  }
}

class _ParticlePainter extends CustomPainter {
  final ParticleEffect effect;
  final List<_Particle> particles;
  final int count;
  final List<Color> colors;
  final ValueListenable<double> time;

  _ParticlePainter({
    required this.effect,
    required this.particles,
    required this.count,
    required this.colors,
    required this.time,
  }) : super(repaint: time);

  static const double _tau = math.pi * 2;

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    switch (effect) {
      case ParticleEffect.none:
        return;
      case ParticleEffect.snow:
        _paintSnow(canvas, size, t);
      case ParticleEffect.glitter:
        _paintGlitter(canvas, size, t);
      case ParticleEffect.confetti:
        _paintConfetti(canvas, size, t);
      case ParticleEffect.bubbles:
        _paintBubbles(canvas, size, t);
      case ParticleEffect.fireflies:
        _paintFireflies(canvas, size, t);
    }
  }

  /// A particle's progress through one top-to-bottom (or bottom-to-top) pass,
  /// 0..1. [rate] is passes per second.
  double _cycle(_Particle p, double t, double rate) =>
      (p.phase + t * rate * p.speed) % 1.0;

  void _paintSnow(Canvas canvas, Size size, double t) {
    final paint = Paint();
    final tint = colors.first;
    for (var i = 0; i < count; i++) {
      final p = particles[i];
      // Big flakes fall faster than small ones; that alone reads as depth.
      final depth = 0.45 + p.scale * 0.55;
      final y = _cycle(p, t, 0.028 * depth) * (size.height + 24) - 12;
      final x =
          p.x * size.width +
          math.sin(t * 0.5 * p.speed + p.phase * _tau) * 20 * p.sway;
      paint.color = tint.withValues(alpha: 0.22 + 0.45 * p.scale);
      canvas.drawCircle(Offset(x, y), 1.4 + 2.4 * p.scale, paint);
    }
  }

  void _paintGlitter(Canvas canvas, Size size, double t) {
    final tint = colors.first;
    final dot = Paint();
    final spark = Paint()
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < count; i++) {
      final p = particles[i];
      // Cubed sine: mostly dark with a short, sharp flash, which is what
      // separates a glint from a pulsing dot.
      final wave = math.sin(t * 1.5 * p.speed + p.phase * _tau);
      final twinkle = wave <= 0 ? 0.0 : wave * wave * wave;
      if (twinkle < 0.02) continue;
      final x =
          p.x * size.width + math.sin(t * 0.2 + p.phase * _tau) * 6 * p.sway;
      final y = p.y * size.height - math.sin(t * 0.16 * p.speed) * 5;
      final r = 1 + 1.6 * p.scale;
      dot.color = tint.withValues(alpha: 0.85 * twinkle);
      canvas.drawCircle(Offset(x, y), r, dot);
      // The cross that makes a dot read as a sparkle, on the brighter half.
      if (p.scale > 0.45) {
        final arm = r * 3.2 * twinkle;
        spark.color = tint.withValues(alpha: 0.45 * twinkle);
        canvas.drawLine(Offset(x - arm, y), Offset(x + arm, y), spark);
        canvas.drawLine(Offset(x, y - arm), Offset(x, y + arm), spark);
      }
    }
  }

  void _paintConfetti(Canvas canvas, Size size, double t) {
    final paint = Paint();
    for (var i = 0; i < count; i++) {
      final p = particles[i];
      final depth = 0.5 + p.scale * 0.5;
      final y = _cycle(p, t, 0.05 * depth) * (size.height + 40) - 20;
      final x =
          p.x * size.width +
          math.sin(t * 0.8 * p.speed + p.phase * _tau) * 28 * p.sway;
      final angle = p.phase * _tau + t * 1.3 * p.speed * p.spin;
      final w = 6 + 5 * p.scale;
      final h = 3.5 + 2.5 * p.scale;
      paint.color = colors[p.tint % colors.length].withValues(
        alpha: 0.45 + 0.35 * p.scale,
      );
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(angle);
      // Squashing across the short axis fakes the piece tumbling edge-on,
      // which costs one cosine and sells the whole effect.
      canvas.scale(1, math.max(0.2, math.cos(angle * 1.4).abs()));
      canvas.drawRect(
        Rect.fromCenter(center: Offset.zero, width: w, height: h),
        paint,
      );
      canvas.restore();
    }
  }

  void _paintBubbles(Canvas canvas, Size size, double t) {
    final tint = colors.first;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (var i = 0; i < count; i++) {
      final p = particles[i];
      final rise = _cycle(p, t, 0.035 * (0.5 + p.scale * 0.5));
      final y = size.height + 20 - rise * (size.height + 40);
      final x =
          p.x * size.width +
          math.sin(t * 0.7 * p.speed + p.phase * _tau) * 16 * p.sway;
      final r = 3 + 9 * p.scale;
      // Fade in off the bottom edge and out before the top, so bubbles never
      // pop into or out of existence mid-canvas.
      final fade = math.min(1.0, math.min(rise, 1 - rise) * 8);
      paint.color = tint.withValues(alpha: (0.12 + 0.22 * p.scale) * fade);
      canvas.drawCircle(Offset(x, y), r, paint);
    }
  }

  void _paintFireflies(Canvas canvas, Size size, double t) {
    final tint = colors.first;
    final glow = Paint();
    final core = Paint();
    for (var i = 0; i < count; i++) {
      final p = particles[i];
      // Two slow sines at different rates: a wander that never repeats
      // visibly, for the price of a Lissajous curve.
      final x =
          p.x * size.width + math.sin(t * 0.22 * p.speed + p.phase * _tau) * 44;
      final y =
          p.y * size.height +
          math.cos(t * 0.17 * p.speed + p.phase * _tau * 0.75) * 32;
      final pulse =
          0.3 +
          0.7 * (0.5 + 0.5 * math.sin(t * 1.05 * p.speed + p.phase * _tau));
      final r = 1.3 + 1.2 * p.scale;
      // A cheap halo: one wide, faint disc under a small bright one. No blur
      // filter, which is the part that would actually cost something.
      glow.color = tint.withValues(alpha: 0.10 * pulse);
      canvas.drawCircle(Offset(x, y), r * 4.5, glow);
      core.color = tint.withValues(alpha: 0.75 * pulse);
      canvas.drawCircle(Offset(x, y), r, core);
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) =>
      old.effect != effect ||
      old.count != count ||
      old.particles != particles ||
      !listEquals(old.colors, colors);
}
