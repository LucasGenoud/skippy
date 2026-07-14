import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'audio_recorder.dart';

/// Full-focus recording modal: a mic that pulses and throws off ripples with
/// your voice, a live waveform, and a running timer. Resolves with the encoded
/// clip on Stop, or null on Cancel / dismiss / mic failure.
class RecordingSheet extends StatefulWidget {
  const RecordingSheet({super.key});

  static Future<({Uint8List bytes, String mime})?> show(BuildContext context) {
    return showModalBottomSheet<({Uint8List bytes, String mime})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const RecordingSheet(),
    );
  }

  @override
  State<RecordingSheet> createState() => _RecordingSheetState();
}

class _RecordingSheetState extends State<RecordingSheet>
    with SingleTickerProviderStateMixin {
  static const _barCount = 40;

  final AudioRecorder _recorder = AudioRecorder();
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  StreamSubscription<double>? _ampSub;
  Timer? _ticker;
  DateTime _start = DateTime.now();
  Duration _elapsed = Duration.zero;

  // Smoothed level for the mic pulse; rolling buffer for the waveform.
  double _level = 0;
  final List<double> _levels = List.generate(_barCount, (_) => 0);

  bool _ready = false;
  bool _stopping = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  Future<void> _begin() async {
    if (!audioRecordingSupported) {
      setState(() => _error = 'Audio recording is only available on the web.');
      return;
    }
    try {
      await _recorder.start();
      _start = DateTime.now();
      _ampSub = _recorder.amplitude.listen(_onAmplitude);
      _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (mounted) {
          setState(() => _elapsed = DateTime.now().difference(_start));
        }
      });
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              "Couldn't access the microphone. Check your browser's "
              'permissions and try again.',
        );
      }
    }
  }

  void _onAmplitude(double amp) {
    if (!mounted) return;
    setState(() {
      _level = _level * 0.55 + amp * 0.45;
      _levels.removeAt(0);
      _levels.add(amp);
    });
  }

  Future<void> _stop() async {
    if (_stopping) return;
    setState(() => _stopping = true);
    _ticker?.cancel();
    await _ampSub?.cancel();
    _ampSub = null;
    try {
      final clip = await _recorder.stop();
      if (!mounted) return;
      Navigator.of(context).pop(clip.bytes.isEmpty ? null : clip);
    } catch (_) {
      if (mounted) Navigator.of(context).pop(null);
    }
  }

  void _cancel() {
    _ticker?.cancel();
    _ampSub?.cancel();
    _ampSub = null;
    _recorder.dispose();
    Navigator.of(context).pop(null);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _ampSub?.cancel();
    _pulse.dispose();
    // Release the mic on any exit path we didn't handle explicitly
    // (e.g. swipe-to-dismiss). Safe to call twice.
    _recorder.dispose();
    super.dispose();
  }

  static String _clock(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(24),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: _error != null
                ? _errorContent(scheme)
                : _recordingContent(scheme),
          ),
        ),
      ),
    );
  }

  List<Widget> _errorContent(ColorScheme scheme) {
    return [
      const SizedBox(height: 8),
      Icon(Icons.mic_off_outlined, size: 40, color: scheme.error),
      const SizedBox(height: 16),
      Text(_error!, textAlign: TextAlign.center),
      const SizedBox(height: 20),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(null),
        child: const Text('Close'),
      ),
    ];
  }

  List<Widget> _recordingContent(ColorScheme scheme) {
    final theme = Theme.of(context);
    return [
      Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(height: 16),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) => Opacity(
              opacity: _ready ? (0.3 + 0.7 * _pulse.value) : 0.3,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: scheme.error,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _ready ? 'Recording' : 'Waiting for microphone…',
            style: theme.textTheme.titleMedium,
          ),
        ],
      ),
      _MicPulse(pulse: _pulse, level: _level, ready: _ready),
      _Waveform(levels: _levels, color: scheme.primary),
      const SizedBox(height: 12),
      Text(
        _clock(_elapsed),
        style: theme.textTheme.headlineSmall?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
          color: scheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 20),
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _stopping ? null : _cancel,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text('Cancel'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              onPressed: (_ready && !_stopping) ? _stop : null,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: _stopping
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.stop),
              label: Text(_stopping ? 'Saving…' : 'Stop'),
            ),
          ),
        ],
      ),
    ];
  }
}

/// The central mic, pulsing with concentric ripples that grow with the live
/// input level.
class _MicPulse extends StatelessWidget {
  final Animation<double> pulse;
  final double level;
  final bool ready;

  const _MicPulse({required this.pulse, required this.level, required this.ready});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 170,
      child: Center(
        child: AnimatedBuilder(
          animation: pulse,
          builder: (context, _) {
            final live = ready ? level : 0.0;
            return Stack(
              alignment: Alignment.center,
              children: [
                for (var i = 0; i < 3; i++) _ripple(scheme, i, live),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 90),
                  width: 88 + live * 18,
                  height: 88 + live * 18,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: scheme.primary.withValues(alpha: 0.35),
                        blurRadius: 22 + live * 22,
                        spreadRadius: live * 4,
                      ),
                    ],
                  ),
                  child: Icon(Icons.mic, color: scheme.onPrimary, size: 42),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _ripple(ColorScheme scheme, int i, double level) {
    final t = (pulse.value + i / 3) % 1.0;
    final size = 96 + t * (110 + level * 90);
    final opacity = ((1 - t) * 0.30).clamp(0.0, 1.0);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.primary.withValues(alpha: opacity),
      ),
    );
  }
}

/// Scrolling live waveform: newest sample on the right.
class _Waveform extends StatelessWidget {
  final List<double> levels;
  final Color color;

  const _Waveform({required this.levels, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final level in levels)
            Container(
              width: 3,
              height: (4 + level * 42).clamp(4.0, 46.0),
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ),
    );
  }
}
