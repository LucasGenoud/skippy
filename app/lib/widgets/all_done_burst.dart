import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../util/motion.dart';

/// The flourish for finishing a checklist: confetti thrown out over the list,
/// and a short-lived "All done" pill in the middle of it.
///
/// Plays once from the moment it is mounted and then calls [onDone], so the
/// caller can drop it from the tree; give it a fresh key to replay. It paints
/// over the list and never takes a pointer, so it can appear while the last
/// ticked row is still sliding down to the completed section.
///
/// Deliberately louder than the per-checkbox dot burst that fires on every
/// tick: that one marks one item, this one marks the whole list being clear.
class AllDoneBurst extends StatefulWidget {
  /// Called once the burst has finished playing.
  final VoidCallback? onDone;

  const AllDoneBurst({super.key, this.onDone});

  @override
  State<AllDoneBurst> createState() => _AllDoneBurstState();
}

class _AllDoneBurstState extends State<AllDoneBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Motion.celebration,
  );

  final math.Random _rng = math.Random();
  List<_Confetto> _confetti = const [];

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onDone?.call();
    });
    _controller.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Confetti take their colours from the theme, so they are rolled here
    // rather than in initState, and only once: re-rolling them on a theme
    // change mid-flight would teleport every piece.
    if (_confetti.isEmpty) _confetti = _spawn();
  }

  List<_Confetto> _spawn() {
    final scheme = Theme.of(context).colorScheme;
    final palette = [
      scheme.primary,
      scheme.tertiary,
      scheme.secondary,
      scheme.primaryContainer,
    ];
    const count = 24;
    return [
      for (var i = 0; i < count; i++)
        _Confetto(
          // Fanned across the upper half, so pieces arc up and outward before
          // gravity takes them: a throw, not an explosion.
          angle: math.pi + (i / (count - 1)) * math.pi + _jitter(0.25),
          reach: 0.55 + _rng.nextDouble() * 0.75,
          fall: 0.6 + _rng.nextDouble() * 0.8,
          spin: (_rng.nextDouble() - 0.5) * 3,
          length: 5 + _rng.nextDouble() * 4,
          thickness: 2 + _rng.nextDouble() * 2,
          round: _rng.nextBool(),
          color: palette[i % palette.length],
        ),
    ];
  }

  double _jitter(double amount) => (_rng.nextDouble() - 0.5) * amount;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _ConfettiPainter(
                progress: _controller,
                confetti: _confetti,
              ),
            ),
          ),
          _AllDonePill(progress: _controller, scheme: scheme),
        ],
      ),
    );
  }
}

/// The label at the centre of the burst: pops in, holds, fades out.
class _AllDonePill extends StatelessWidget {
  final Animation<double> progress;
  final ColorScheme scheme;

  const _AllDonePill({required this.progress, required this.scheme});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_rounded,
              size: 18,
              color: scheme.onPrimaryContainer,
            ),
            const SizedBox(width: 6),
            Text(
              'All done',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      builder: (context, child) {
        final t = progress.value;
        // In over the first tenth, held while the confetti fly, gone by the
        // end; the whole thing is over in about a second.
        final opacity = t < 0.1
            ? t / 0.1
            : t < 0.72
            ? 1.0
            : 1 - (t - 0.72) / 0.28;
        final scale = t < 0.25
            ? lerpDouble(0.7, 1.0, Curves.easeOutBack.transform(t / 0.25))!
            : lerpDouble(1.0, 0.94, ((t - 0.25) / 0.75).clamp(0.0, 1.0))!;
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.scale(scale: scale, child: child),
        );
      },
    );
  }
}

/// One piece of confetti: direction, reach and spin rolled at spawn, position
/// derived from the shared progress at paint time.
class _Confetto {
  /// Launch direction in radians, measured the usual screen way (y grows
  /// downward), so the upper half is π…2π.
  final double angle;

  /// How far out it travels, as a fraction of the box's shorter side.
  final double reach;

  /// How hard gravity pulls it back down, as a fraction of the box height.
  final double fall;

  /// Turns over the whole flight; negative spins the other way.
  final double spin;

  final double length;
  final double thickness;

  /// Round pieces read as dots, the rest as small ribbons.
  final bool round;

  final Color color;

  const _Confetto({
    required this.angle,
    required this.reach,
    required this.fall,
    required this.spin,
    required this.length,
    required this.thickness,
    required this.round,
    required this.color,
  });
}

class _ConfettiPainter extends CustomPainter {
  final Animation<double> progress;
  final List<_Confetto> confetti;

  _ConfettiPainter({required this.progress, required this.confetti})
    : super(repaint: progress);

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    if (confetti.isEmpty || t <= 0 || t >= 1) return;
    final origin = size.center(Offset.zero);
    // Out fast, then coasting: the outward travel eases off while gravity
    // keeps accumulating, which is what bends each path into an arc.
    final travel = Curves.easeOutCubic.transform(t);
    final gravity = t * t;
    final fade = t < 0.55 ? 1.0 : 1 - (t - 0.55) / 0.45;
    // How far the burst throws, in pixels. Clamped rather than taken straight
    // from the box: a one-item list is only a few dozen pixels tall, and a
    // burst scaled to that reads as a twitch, while a screen-tall list would
    // fling confetti off into the margins.
    final field = size.longestSide.clamp(160.0, 320.0);

    for (final piece in confetti) {
      final position =
          origin +
          Offset(math.cos(piece.angle), math.sin(piece.angle)) *
              (piece.reach * field * 0.5 * travel) +
          Offset(0, piece.fall * field * 0.5 * gravity);
      final paint = Paint()
        ..color = piece.color.withValues(alpha: fade.clamp(0.0, 1.0));

      canvas.save();
      canvas.translate(position.dx, position.dy);
      if (piece.round) {
        canvas.drawCircle(Offset.zero, piece.thickness, paint);
      } else {
        canvas.rotate(piece.spin * t * math.pi * 2);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset.zero,
              width: piece.thickness,
              height: piece.length,
            ),
            Radius.circular(piece.thickness / 2),
          ),
          paint,
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) =>
      old.confetti != confetti || old.progress != progress;
}
