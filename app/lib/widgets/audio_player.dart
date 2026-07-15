/// A compact audio player for an attachment. On the web it wraps an
/// `HTMLAudioElement`; on native platforms (Android/iOS) it wraps the
/// `just_audio` plugin. Same widget API on both.
library;

export 'audio_player_io.dart'
    if (dart.library.js_interop) 'audio_player_web.dart';
