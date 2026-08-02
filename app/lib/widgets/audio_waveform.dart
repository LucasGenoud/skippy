import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A small, touch-friendly playback waveform. It deliberately uses a stable
/// visual rhythm rather than decoding every recording into PCM just to draw a
/// preview; the coloured portion always reflects the real playback position.
class AudioWaveform extends StatelessWidget {
  final double position;
  final double duration;
  final Color activeColor;
  final Color inactiveColor;
  final ValueChanged<double>? onSeek;

  const AudioWaveform({
    super.key,
    required this.position,
    required this.duration,
    required this.activeColor,
    required this.inactiveColor,
    this.onSeek,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = duration > 0 && onSeek != null;
    final progress = duration > 0
        ? (position / duration).clamp(0.0, 1.0).toDouble()
        : 0.0;
    return LayoutBuilder(
      builder: (context, constraints) => Semantics(
        label: 'Audio playback position',
        value: duration > 0
            ? '${position.round()} of ${duration.round()} seconds'
            : 'Audio is loading',
        button: enabled,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled
              ? (details) {
                  if (constraints.maxWidth == 0) return;
                  final fraction =
                      (details.localPosition.dx / constraints.maxWidth)
                          .clamp(0.0, 1.0)
                          .toDouble();
                  onSeek!(duration * fraction);
                }
              : null,
          child: TweenAnimationBuilder<double>(
            duration: const Duration(milliseconds: 240),
            curve: Curves.linear,
            tween: Tween(end: progress),
            builder: (context, animatedProgress, _) => SizedBox(
              height: 34,
              child: CustomPaint(
                painter: _AudioWaveformPainter(
                  progress: animatedProgress,
                  activeColor: activeColor,
                  inactiveColor: inactiveColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AudioWaveformPainter extends CustomPainter {
  final double progress;
  final Color activeColor;
  final Color inactiveColor;

  const _AudioWaveformPainter({
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _paintBars(canvas, size, inactiveColor);
    // A moving clip reveals partial bars at the playhead, so it sweeps smoothly
    // rather than flipping one whole bar at a time.
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width * progress, size.height));
    _paintBars(canvas, size, activeColor);
    canvas.restore();
  }

  void _paintBars(Canvas canvas, Size size, Color color) {
    const barWidth = 3.0;
    const gap = 2.5;
    final count = math.max(1, (size.width / (barWidth + gap)).floor());
    final center = size.height / 2;
    final radius = Radius.circular(barWidth / 2);
    for (var i = 0; i < count; i++) {
      // Several low-frequency waves make a calm, recognisable audio silhouette
      // at every width without the cost of decoding the recording.
      final x = i / math.max(1, count - 1);
      final shape =
          0.24 +
          0.76 *
              ((math.sin(x * 19.0) +
                          math.sin(x * 43.0 + 1.7) * 0.45 +
                          math.sin(x * 7.0 + 0.8) * 0.3 +
                          1.75) /
                      3.5)
                  .clamp(0.0, 1.0);
      final height = 6.0 + shape * (size.height - 8.0);
      final rect = Rect.fromCenter(
        center: Offset(i * (barWidth + gap) + barWidth / 2, center),
        width: barWidth,
        height: height,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, radius),
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_AudioWaveformPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.activeColor != activeColor ||
      oldDelegate.inactiveColor != inactiveColor;
}
