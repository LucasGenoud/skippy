import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Whether microphone capture is available on this platform (web only).
const bool audioRecordingSupported = true;

/// Records microphone audio with the browser's MediaRecorder and reports a
/// live input level (0..1) for the recording UI.
///
/// Every callback handed to JS is *synchronous* (the blob is read from an
/// async `.then`, not an async closure) — passing an async Dart closure
/// through `.toJS` fails to compile under DDC/dart2js.
class AudioRecorder {
  web.MediaStream? _stream;
  web.MediaRecorder? _recorder;
  final List<web.Blob> _chunks = [];
  String _mime = 'audio/webm';

  // Web Audio graph, used only to sample the input level for the animation.
  web.AudioContext? _audioCtx;
  web.AnalyserNode? _analyser;
  JSUint8Array? _freqBuffer;
  Timer? _meterTimer;

  final _amplitude = StreamController<double>.broadcast();
  Completer<({Uint8List bytes, String mime})>? _stopCompleter;

  /// Input level 0..1, emitted ~18×/second while recording.
  Stream<double> get amplitude => _amplitude.stream;

  /// Request the mic and begin recording. Throws if permission is denied.
  Future<void> start() async {
    final stream = await web.window.navigator.mediaDevices
        .getUserMedia(web.MediaStreamConstraints(audio: true.toJS))
        .toDart;
    _stream = stream;
    _mime = _pickMime();
    _chunks.clear();

    final recorder = _mime.isEmpty
        ? web.MediaRecorder(stream)
        : web.MediaRecorder(stream, web.MediaRecorderOptions(mimeType: _mime));
    _recorder = recorder;

    recorder.ondataavailable = ((web.Event event) {
      final blob = (event as web.BlobEvent).data;
      if (blob.size > 0) _chunks.add(blob);
    }).toJS;
    recorder.onstop = ((web.Event _) => _handleStop()).toJS;

    _startMeter(stream);
    recorder.start();
  }

  /// The first container the browser actually supports (Chrome/Firefox emit
  /// webm/opus, Safari mp4); empty string = let the browser choose.
  static String _pickMime() {
    for (final candidate in const [
      'audio/webm;codecs=opus',
      'audio/webm',
      'audio/ogg;codecs=opus',
      'audio/mp4',
    ]) {
      if (web.MediaRecorder.isTypeSupported(candidate)) return candidate;
    }
    return '';
  }

  void _startMeter(web.MediaStream stream) {
    try {
      final ctx = web.AudioContext();
      final analyser = ctx.createAnalyser();
      analyser.fftSize = 256;
      ctx.createMediaStreamSource(stream).connect(analyser);
      _audioCtx = ctx;
      _analyser = analyser;
      _freqBuffer = Uint8List(analyser.frequencyBinCount).toJS;
      _meterTimer = Timer.periodic(const Duration(milliseconds: 55), (_) {
        final analyser = _analyser;
        final buffer = _freqBuffer;
        if (analyser == null || buffer == null) return;
        analyser.getByteFrequencyData(buffer);
        final data = buffer.toDart;
        if (data.isEmpty) return;
        var sum = 0;
        for (final v in data) {
          sum += v;
        }
        // Average magnitude (0..255) -> a lively but bounded 0..1 level.
        final level = (sum / data.length / 160).clamp(0.0, 1.0);
        if (!_amplitude.isClosed) _amplitude.add(level.toDouble());
      });
    } catch (_) {
      // The level meter is best-effort; the sheet animates regardless.
    }
  }

  /// Stop recording and resolve with the encoded clip.
  Future<({Uint8List bytes, String mime})> stop() {
    final completer = Completer<({Uint8List bytes, String mime})>();
    _stopCompleter = completer;
    _meterTimer?.cancel();
    _meterTimer = null;
    final recorder = _recorder;
    if (recorder != null && recorder.state != 'inactive') {
      recorder.stop(); // -> ondataavailable (final chunk) -> onstop
    } else {
      _handleStop();
    }
    return completer.future;
  }

  void _handleStop() {
    final mime = _mime.isEmpty ? 'audio/webm' : _mime;
    final blob = web.Blob(_chunks.toJS, web.BlobPropertyBag(type: mime));
    blob.arrayBuffer().toDart.then((buffer) {
      final bytes = buffer.toDart.asUint8List();
      _teardownStream();
      _stopCompleter?.complete((bytes: bytes, mime: mime));
      _stopCompleter = null;
    });
  }

  void _teardownStream() {
    final tracks = _stream?.getTracks().toDart ?? const [];
    for (final track in tracks) {
      track.stop();
    }
    _stream = null;
    final ctx = _audioCtx;
    _audioCtx = null;
    _analyser = null;
    _freqBuffer = null;
    if (ctx != null) ctx.close();
  }

  void dispose() {
    _meterTimer?.cancel();
    _teardownStream();
    if (!_amplitude.isClosed) _amplitude.close();
  }
}
