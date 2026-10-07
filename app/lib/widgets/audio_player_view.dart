import 'package:flutter/material.dart';

import '../theme.dart';
import '../util/motion.dart';
import 'audio_waveform.dart';

/// The inline player both platform engines draw: a play/pause button, a
/// seekable waveform, and elapsed / total time. Holds no playback state, so
/// the web and native players look the same by construction.
class AudioPlayerView extends StatelessWidget {
  const AudioPlayerView({
    super.key,
    required this.playing,
    required this.position,
    required this.duration,
    required this.onToggle,
    required this.onSeek,
  });

  final bool playing;

  /// Seconds; [duration] is 0 until the clip's length is known.
  final double position;
  final double duration;
  final VoidCallback onToggle;
  final ValueChanged<double> onSeek;

  static String _clock(double seconds) {
    if (!seconds.isFinite || seconds < 0) {
      seconds = 0;
    }
    final total = seconds.round();
    final m = (total ~/ 60).toString();
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final max = duration > 0 ? duration : 1.0;
    final value = position.clamp(0.0, max);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(kRadius),
      ),
      child: Row(
        children: [
          Material(
            color: scheme.primary,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.all(8),
                // The triangle folds into the bars and back, so the button
                // answers the tap itself instead of relying on the waveform
                // to show that anything happened.
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: playing ? 1.0 : 0.0),
                  duration: Motion.fast,
                  curve: Motion.standard,
                  builder: (context, progress, _) => AnimatedIcon(
                    icon: AnimatedIcons.play_pause,
                    progress: AlwaysStoppedAnimation(progress),
                    color: scheme.onPrimary,
                    size: 22,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: AudioWaveform(
              position: value.toDouble(),
              duration: duration,
              playing: playing,
              activeColor: scheme.primary,
              inactiveColor: scheme.onSurface.withValues(alpha: 0.14),
              cursorColor: scheme.surface,
              onSeek: duration > 0 ? onSeek : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8, left: 4),
            child: Text(
              '${_clock(position)} / ${_clock(duration)}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
