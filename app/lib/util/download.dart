/// Trigger a client-side file download. Text and binary data can be saved
/// directly; [downloadUrl] fetches a remote file first. Web uses a temporary
/// Blob URL, while native routes through the system share sheet.
library;

export 'download_io.dart' if (dart.library.js_interop) 'download_web.dart';
