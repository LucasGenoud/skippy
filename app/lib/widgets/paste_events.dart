/// The OS clipboard's file side, which needs platform-specific plumbing. On
/// the web the browser hands us a paste event carrying the files; everywhere
/// else there is no such event and this is a no-op (Android rich content
/// arrives through the focused field instead, see [PasteFileArea]).
library;

export 'paste_events_stub.dart'
    if (dart.library.js_interop) 'paste_events_web.dart';
