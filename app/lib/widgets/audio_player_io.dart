import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

/// Compact inline player for an audio attachment on native platforms, backed by
/// the `just_audio` plugin. Visually identical to the web player: a play/pause
/// button, a seekable progress bar, and elapsed / total time.
class AudioPlayerBar extends StatefulWidget {
  final String url;
  const AudioPlayerBar({super.key, required this.url});

  @override
  State<AudioPlayerBar> createState() => _AudioPlayerBarState();
}

class _AudioPlayerBarState extends State<AudioPlayerBar> {
  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _playing = false;
  double _position = 0;
  double _duration = 0;

  @override
  void initState() {
    super.initState();
    _subs.add(
      _player.positionStream.listen((p) {
        if (mounted) setState(() => _position = p.inMilliseconds / 1000);
      }),
    );
    _subs.add(
      _player.durationStream.listen((d) {
        if (mounted && d != null) {
          setState(() => _duration = d.inMilliseconds / 1000);
        }
      }),
    );
    _subs.add(
      _player.playerStateStream.listen((s) {
        if (!mounted) return;
        final done = s.processingState == ProcessingState.completed;
        setState(() => _playing = s.playing && !done);
        if (done) {
          _player.pause();
          _player.seek(Duration.zero);
        }
      }),
    );
    // Load the (public) file URL; swallow load errors so the bar stays inert
    // rather than throwing into the widget tree.
    _player.setUrl(widget.url).catchError((_) => null);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_player.playing) {
      _player.pause();
    } else {
      if (_player.processingState == ProcessingState.completed) {
        _player.seek(Duration.zero);
      }
      _player.play(); // fire-and-forget; resolves when playback ends
    }
  }

  void _seek(double seconds) {
    _player.seek(Duration(milliseconds: (seconds * 1000).round()));
    setState(() => _position = seconds);
  }

  static String _clock(double seconds) {
    if (!seconds.isFinite || seconds < 0) seconds = 0;
    final total = seconds.round();
    final m = (total ~/ 60).toString();
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final max = _duration > 0 ? _duration : 1.0;
    final value = _position.clamp(0.0, max);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Row(
        children: [
          Material(
            color: scheme.primary,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  _playing ? Icons.pause : Icons.play_arrow,
                  color: scheme.onPrimary,
                  size: 22,
                ),
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                value: value.toDouble(),
                max: max,
                onChanged: _duration > 0 ? _seek : null,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8, left: 4),
            child: Text(
              '${_clock(_position)} / ${_clock(_duration)}',
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
