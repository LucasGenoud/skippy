import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart' as rec;

/// Whether microphone capture is available on this platform. The native
/// (Android/iOS/desktop) recorder is backed by the `record` plugin.
const bool audioRecordingSupported = true;

/// Records microphone audio on native platforms with the `record` plugin,
/// mirroring the web recorder's API exactly so [RecordingSheet] never branches
/// on platform. Encodes AAC in an m4a container (`audio/mp4`), a format the
/// ffmpeg-based Whisper service transcribes and that the app already maps to a
/// `.m4a` upload in `NotesStore.createAudioNote`.
class AudioRecorder {
  final rec.AudioRecorder _recorder = rec.AudioRecorder();
  final _amplitude = StreamController<double>.broadcast();
  StreamSubscription<rec.Amplitude>? _ampSub;
  String? _path;

  /// Input level 0..1, mapped from the recorder's dBFS readings, for the
  /// recording UI (mic pulse + waveform).
  Stream<double> get amplitude => _amplitude.stream;

  /// Request the mic and begin recording to a temp file. Throws if permission
  /// is denied (the sheet turns that into its error state).
  Future<void> start() async {
    if (!await _recorder.hasPermission()) {
      throw StateError('Microphone permission denied.');
    }
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/note_recording_${DateTime.now().millisecondsSinceEpoch}.m4a';
    _path = path;
    await _recorder.start(
      const rec.RecordConfig(encoder: rec.AudioEncoder.aacLc),
      path: path,
    );
    // `record` reports dBFS (~ -160 silent .. 0 loudest); map to a lively but
    // bounded 0..1, matching the feel of the web recorder's level meter.
    _ampSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 60))
        .listen((amp) {
          final level = ((amp.current + 50) / 50).clamp(0.0, 1.0);
          if (!_amplitude.isClosed) _amplitude.add(level.toDouble());
        });
  }

  /// Stop recording and read back the encoded clip, then delete the temp file.
  Future<({Uint8List bytes, String mime})> stop() async {
    await _ampSub?.cancel();
    _ampSub = null;
    final path = await _recorder.stop() ?? _path;
    if (path == null) return (bytes: Uint8List(0), mime: 'audio/mp4');
    final file = File(path);
    final bytes = file.existsSync() ? await file.readAsBytes() : Uint8List(0);
    try {
      if (file.existsSync()) await file.delete();
    } catch (_) {
      // Best-effort cleanup; the OS clears the temp dir anyway.
    }
    return (bytes: bytes, mime: 'audio/mp4');
  }

  void dispose() {
    _ampSub?.cancel();
    _ampSub = null;
    _recorder.dispose();
    if (!_amplitude.isClosed) _amplitude.close();
  }
}
