/// Microphone capture. On the web this drives the browser's MediaRecorder and
/// exposes a live input level for the recording animation; on other platforms
/// it's an unsupported stub (the app ships as a web build), matching the
/// file_drop / download split.
library;

export 'audio_recorder_stub.dart'
    if (dart.library.js_interop) 'audio_recorder_web.dart';
