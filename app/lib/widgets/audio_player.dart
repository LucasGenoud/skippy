/// A compact audio player for an attachment. On the web it wraps an
/// `HTMLAudioElement`; elsewhere it's an inert placeholder (the app ships as a
/// web build), matching the file_drop / download split.
library;

export 'audio_player_stub.dart'
    if (dart.library.js_interop) 'audio_player_web.dart';
