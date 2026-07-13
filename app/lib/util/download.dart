/// Trigger a client-side file download of in-memory text. On the web this
/// hands a Blob to the browser via a temporary `<a download>`; elsewhere it's
/// a no-op (the app ships as a web build), matching the file_drop split.
library;

export 'download_stub.dart'
    if (dart.library.js_interop) 'download_web.dart';
