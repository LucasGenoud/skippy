import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'audio_player_view.dart';

/// Counterpart to the native flag: the browser always plays audio back, so the
/// web build never shows the "not supported here" panel.
bool get audioPlaybackSupported => true;

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
    _audio = web.HTMLAudioElement()..preload = 'auto';
    // Install all listeners before assigning src. A cached clip can load its
    // metadata quickly enough to otherwise miss `loadedmetadata` entirely.
    _audio.onloadedmetadata = ((web.Event _) {
      _updateDuration();
    }).toJS;
    // A normal media file can resolve its duration after `loadedmetadata`.
    _audio.ondurationchange = ((web.Event _) {
      _updateDuration();
    }).toJS;
    // Firefox reports `duration` as Infinity for MediaRecorder WebM clips,
    // but exposes the real end time in `seekable` once enough data is loaded.
    // A full preload makes that information available before playback.
    _audio.onprogress = ((web.Event _) => _updateDuration()).toJS;
    _audio.oncanplay = ((web.Event _) => _updateDuration()).toJS;
    _audio.oncanplaythrough = ((web.Event _) => _updateDuration()).toJS;
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
    _audio.src = widget.url;
    _audio.load();
  }

  void _updateDuration() {
    var duration = _audio.duration;
    if (!duration.isFinite || duration <= 0) {
      final ranges = _audio.seekable;
      if (ranges.length > 0) duration = ranges.end(ranges.length - 1);
    }
    if (!mounted || !duration.isFinite || duration <= 0) return;
    setState(() => _duration = duration);
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

  @override
  Widget build(BuildContext context) {
    return AudioPlayerView(
      playing: _playing,
      position: _position,
      duration: _duration,
      onToggle: _toggle,
      onSeek: _seek,
    );
  }
}
