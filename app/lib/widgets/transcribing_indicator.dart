import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Animated "Transcribing…" placeholder for an audio note whose Whisper
/// transcript is still being produced: a bouncing equalizer next to shimmering
/// placeholder lines. [compact] trims it for note cards.
class TranscribingIndicator extends StatefulWidget {
  final bool compact;
  const TranscribingIndicator({super.key, this.compact = false});

  @override
  State<TranscribingIndicator> createState() => _TranscribingIndicatorState();
}

class _TranscribingIndicatorState extends State<TranscribingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _Equalizer(
              animation: _controller,
              color: scheme.primary,
              height: widget.compact ? 14 : 18,
            ),
            const SizedBox(width: 10),
            Text(
              'Transcribing…',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        SizedBox(height: widget.compact ? 8 : 12),
        _ShimmerLines(
          animation: _controller,
          widthFactors: widget.compact
              ? const [1.0, 0.6]
              : const [1.0, 0.92, 0.5],
        ),
      ],
    );
  }
}

/// A row of bars that bob up and down out of phase — a lightweight "audio is
/// being processed" motif.
class _Equalizer extends StatelessWidget {
  static const _bars = 4;

  final Animation<double> animation;
  final Color color;
  final double height;

  const _Equalizer({
    required this.animation,
    required this.color,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (var i = 0; i < _bars; i++) ...[
              if (i != 0) const SizedBox(width: 3),
              _bar(i),
            ],
          ],
        ),
      ),
    );
  }

  Widget _bar(int i) {
    final phase = i / _bars;
    final t = 0.5 + 0.5 * math.sin((animation.value + phase) * 2 * math.pi);
    return Container(
      width: 3.5,
      height: height * (0.3 + 0.7 * t),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

/// Grey placeholder lines with a highlight band sweeping across — the classic
/// content-loading shimmer.
class _ShimmerLines extends StatelessWidget {
  final Animation<double> animation;
  final List<double> widthFactors;

  const _ShimmerLines({required this.animation, required this.widthFactors});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.onSurface.withValues(alpha: 0.09);
    final highlight = scheme.onSurface.withValues(alpha: 0.20);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        // Sweep a highlight band from left to right, past both edges.
        final slide = animation.value * 1.6 - 0.3;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (rect) => LinearGradient(
            colors: [base, highlight, base],
            stops: [
              (slide - 0.3).clamp(0.0, 1.0),
              slide.clamp(0.0, 1.0),
              (slide + 0.3).clamp(0.0, 1.0),
            ],
          ).createShader(rect),
          child: child,
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < widthFactors.length; i++)
            Padding(
              padding: EdgeInsets.only(
                bottom: i == widthFactors.length - 1 ? 0 : 9,
              ),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: widthFactors[i],
                child: Container(
                  height: 10,
                  decoration: BoxDecoration(
                    color: base,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shown when transcription failed, with an optional Retry action.
class TranscriptFailed extends StatelessWidget {
  final VoidCallback? onRetry;
  final bool compact;

  const TranscriptFailed({super.key, this.onRetry, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Icon(Icons.error_outline, size: compact ? 16 : 18, color: scheme.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            "Couldn't transcribe this recording",
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        if (onRetry != null)
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: const Text('Retry'),
          ),
      ],
    );
  }
}
