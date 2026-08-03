import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// A small, touch-friendly playback waveform. It deliberately uses a stable
/// visual rhythm rather than decoding every recording into PCM just to draw a
/// preview; the coloured portion always reflects the real playback position.
class AudioWaveform extends StatefulWidget {
  final double position;
  final double duration;
  final bool playing;
  final Color activeColor;
  final Color inactiveColor;
  final Color cursorColor;
  final ValueChanged<double>? onSeek;

  const AudioWaveform({
    super.key,
    required this.position,
    required this.duration,
    this.playing = false,
    required this.activeColor,
    required this.inactiveColor,
    required this.cursorColor,
    this.onSeek,
  });

  @override
  State<AudioWaveform> createState() => _AudioWaveformState();
}

class _AudioWaveformState extends State<AudioWaveform>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final Stopwatch _clock = Stopwatch();
  double _anchorPosition = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) {
      if (widget.playing && mounted) setState(() {});
    });
    _syncToPlayer();
    _setTickerRunning(widget.playing);
  }

  @override
  void didUpdateWidget(covariant AudioWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position ||
        oldWidget.playing != widget.playing ||
        oldWidget.duration != widget.duration) {
      _syncToPlayer();
    }
    _setTickerRunning(widget.playing);
  }

  void _syncToPlayer() {
    _anchorPosition = widget.position;
    _clock
      ..reset()
      ..stop();
    if (widget.playing) _clock.start();
  }

  void _setTickerRunning(bool playing) {
    if (playing && !_ticker.isActive) {
      _ticker.start();
    } else if (!playing && _ticker.isActive) {
      _ticker.stop();
    }
  }

  double get _displayPosition {
    final elapsed = widget.playing ? _clock.elapsedMicroseconds / 1e6 : 0.0;
    return (_anchorPosition + elapsed).clamp(0.0, widget.duration).toDouble();
  }

  void _seekTo(double seconds) {
    _anchorPosition = seconds.clamp(0.0, widget.duration).toDouble();
    _clock
      ..reset()
      ..stop();
    if (widget.playing) _clock.start();
    setState(() {});
    widget.onSeek!(_anchorPosition);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.duration > 0 && widget.onSeek != null;
    final position = _displayPosition;
    final progress = widget.duration > 0
        ? (position / widget.duration).clamp(0.0, 1.0).toDouble()
        : 0.0;
    return LayoutBuilder(
      builder: (context, constraints) => Semantics(
        label: 'Audio playback position',
        value: widget.duration > 0
            ? '${position.round()} of ${widget.duration.round()} seconds'
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
                  _seekTo(widget.duration * fraction);
                }
              : null,
          onHorizontalDragUpdate: enabled
              ? (details) {
                  if (constraints.maxWidth == 0) return;
                  final fraction =
                      (details.localPosition.dx / constraints.maxWidth)
                          .clamp(0.0, 1.0)
                          .toDouble();
                  _seekTo(widget.duration * fraction);
                }
              : null,
          child: SizedBox(
            height: 34,
            child: CustomPaint(
              painter: _AudioWaveformPainter(
                progress: progress,
                activeColor: widget.activeColor,
                inactiveColor: widget.inactiveColor,
                cursorColor: widget.cursorColor,
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
  final Color cursorColor;

  const _AudioWaveformPainter({
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
    required this.cursorColor,
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
    final playhead = Offset(size.width * progress, size.height / 2);
    canvas.drawCircle(playhead, 6, Paint()..color = activeColor);
    canvas.drawCircle(playhead, 3.5, Paint()..color = cursorColor);
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
      oldDelegate.inactiveColor != inactiveColor ||
      oldDelegate.cursorColor != cursorColor;
}
