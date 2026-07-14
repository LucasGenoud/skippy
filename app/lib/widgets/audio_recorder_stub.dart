import 'dart:typed_data';

/// Whether microphone capture is available on this platform (web only).
const bool audioRecordingSupported = false;

/// Non-web builds don't wire up microphone capture. Kept API-identical to the
/// web version so callers never branch on platform.
class AudioRecorder {
  Stream<double> get amplitude => const Stream<double>.empty();

  Future<void> start() async =>
      throw UnsupportedError('Audio recording is only available on the web.');

  Future<({Uint8List bytes, String mime})> stop() async =>
      throw UnsupportedError('Audio recording is only available on the web.');

  void dispose() {}
}
