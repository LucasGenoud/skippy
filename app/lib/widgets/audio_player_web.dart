import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// Compact inline player for an audio attachment: a play/pause button, a
/// seekable progress bar, and elapsed / total time. Backed by a detached
/// `HTMLAudioElement` (all JS callbacks are synchronous).
class AudioPlayerBar extends StatefulWidget {
  final String url;
  const AudioPlayerBar({super.key, required this.url});

  @override
  State<AudioPlayerBar> createState() => _AudioPlayerBarState();
}

class _AudioPlayerBarState extends State<AudioPlayerBar> {
  late final web.HTMLAudioElement _audio;
  bool _playing = false;
  double _position = 0;
  double _duration = 0;

  @override
  void initState() {
    super.initState();
    _audio = web.HTMLAudioElement()
      ..src = widget.url
      ..preload = 'metadata';
    _audio.onloadedmetadata = ((web.Event _) {
      final d = _audio.duration;
      if (mounted) setState(() => _duration = d.isFinite ? d : 0);
    }).toJS;
    _audio.ontimeupdate = ((web.Event _) {
      if (mounted) setState(() => _position = _audio.currentTime);
    }).toJS;
    _audio.onended = ((web.Event _) {
      if (mounted) {
        setState(() {
          _playing = false;
          _position = 0;
        });
      }
    }).toJS;
  }

  @override
  void dispose() {
    _audio.pause();
    _audio.src = '';
    super.dispose();
  }

  void _toggle() {
    if (_playing) {
      _audio.pause();
    } else {
      _audio.play(); // user-initiated; ignore the returned promise
    }
    setState(() => _playing = !_playing);
  }

  void _seek(double seconds) {
    _audio.currentTime = seconds;
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
