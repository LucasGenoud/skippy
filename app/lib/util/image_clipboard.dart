/// Puts a picture on the system clipboard, so it can be pasted into another
/// app. The web asks the browser; the native builds ask the platform through
/// a small channel the runner implements (iOS, Android, macOS).
library;

export 'image_clipboard_io.dart'
    if (dart.library.js_interop) 'image_clipboard_web.dart';
