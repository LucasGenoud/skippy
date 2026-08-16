import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../util/motion.dart';

/// A Material [Checkbox] that gives a springy scale "pop" every time it's
/// tapped, on top of Checkbox's own tick-draw and ripple. The pop is fired
/// from the tap handler itself (not from a value diff), so it plays reliably
/// even as the checked row immediately slides down to the completed section.
class PopCheckbox extends StatefulWidget {
  final bool value;
  final ValueChanged<bool?>? onChanged;
  final Color sideColor;

  const PopCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    required this.sideColor,
  });

  /// The density every one of these is pinned to, so a checklist's boxes are
  /// the same size wherever they are built.
  static const VisualDensity _density = VisualDensity.compact;

  /// The square one of these occupies: a [Checkbox]'s tap target at
  /// [_density]. Layout that reserves a slot for a checkbox that isn't there
  /// yet (the checklist composer's "+") asks for this rather than assuming
  /// the mobile size — a desktop tap target shrink-wraps 8px smaller, and a
  /// slot that ignored that sat its checkbox out of line with the rows above.
  static double sizeOf(BuildContext context) {
    final theme = Theme.of(context);
    final tapTarget =
        theme.checkboxTheme.materialTapTargetSize ?? theme.materialTapTargetSize;
    final base = switch (tapTarget) {
      MaterialTapTargetSize.padded => kMinInteractiveDimension,
      MaterialTapTargetSize.shrinkWrap => kMinInteractiveDimension - 8.0,
    };
    return base + _density.baseSizeAdjustment.dx;
  }

  @override
  State<PopCheckbox> createState() => _PopCheckboxState();
}

class _PopCheckboxState extends State<PopCheckbox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Motion.slow,
  );
  // Quickly balloons to 1.6x then bounces back with an elastic settle, so the
  // tap reads clearly even while the ticked row is sliding to "Completed".
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 1.0,
        end: 1.6,
      ).chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 30,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.6,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.elasticOut)),
      weight: 70,
    ),
  ]).animate(_controller);

  final math.Random _rng = math.Random();
  List<_Particle> _particles = const [];

  void _handleChanged(bool? value) {
    // The pop and its dots are pure decoration over a control the user has
    // already hit, so reduce motion drops them entirely; Checkbox still draws
    // its own tick.
    if (!Motion.reduced(context)) {
      // A tiny celebration burst, only when ticking something OFF the list,
      // not when unchecking it back.
      _particles = value == true ? _spawnParticles() : const [];
      _controller.forward(from: 0);
    }
    widget.onChanged?.call(value);
  }

  List<_Particle> _spawnParticles() {
    final scheme = Theme.of(context).colorScheme;
    const count = 10;
    return [
      for (var i = 0; i < count; i++)
        _Particle(
          // Evenly fanned around the box, with a little jitter so no two
          // bursts look identical.
          angle: (i / count) * 2 * math.pi + _rng.nextDouble() * 0.6,
          distance: 14 + _rng.nextDouble() * 10,
          size: 1.5 + _rng.nextDouble() * 1.5,
          color: i.isEven ? scheme.primary : scheme.tertiary,
        ),
    ];
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        // Painted first so the dots eject from *behind* the checkbox.
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _ParticlePainter(
                progress: _controller,
                particles: _particles,
              ),
            ),
          ),
        ),
        ScaleTransition(
          scale: _scale,
          child: Checkbox(
            value: widget.value,
            onChanged: widget.onChanged == null ? null : _handleChanged,
            visualDensity: PopCheckbox._density,
            side: BorderSide(color: widget.sideColor, width: 1.5),
          ),
        ),
      ],
    );
  }
}

/// One confetti dot of the check celebration: a fixed direction/reach/size
/// rolled at spawn; its position and fade are derived from the shared
/// animation progress at paint time.
class _Particle {
  final double angle;
  final double distance;
  final double size;
  final Color color;

  const _Particle({
    required this.angle,
    required this.distance,
    required this.size,
    required this.color,
  });
}

class _ParticlePainter extends CustomPainter {
  final Animation<double> progress;
  final List<_Particle> particles;

  _ParticlePainter({required this.progress, required this.particles})
    : super(repaint: progress);

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    if (particles.isEmpty || t <= 0 || t >= 1) return;
    final center = size.center(Offset.zero);
    // Dots race out fast then coast; they fade through the back half so the
    // whole thing is over in a blink.
    final travel = Curves.easeOutCubic.transform(t);
    final fade = 1 - Curves.easeIn.transform(t);
    for (final p in particles) {
      final pos =
          center +
          Offset(math.cos(p.angle), math.sin(p.angle)) * (p.distance * travel);
      final paint = Paint()..color = p.color.withValues(alpha: fade);
      canvas.drawCircle(pos, p.size * (1 - 0.4 * t), paint);
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) =>
      old.particles != particles || old.progress != progress;
}
