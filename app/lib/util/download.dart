/// Trigger a client-side file download. [downloadTextFile] saves in-memory
/// text; [downloadUrl] fetches a remote file (e.g. an image attachment) and
/// saves it under a given name. On the web these hand a Blob to the browser via
/// a temporary `<a download>`; on native (Android/iOS) they route through the
/// system share sheet (see download_io.dart), matching the file_drop split.
library;

export 'download_io.dart' if (dart.library.js_interop) 'download_web.dart';
