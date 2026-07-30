/// Microphone capture. On the web this drives the browser's MediaRecorder; on
/// native platforms (Android/iOS) it drives the `record` plugin. Both expose an
/// identical API, a live input level plus `start`/`stop`, so callers never
/// branch on platform.
library;

export 'audio_recorder_io.dart'
    if (dart.library.js_interop) 'audio_recorder_web.dart';
