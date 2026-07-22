import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Save [content] as [filename] via a throwaway object-URL anchor. Passing the
/// string straight to the Blob lets the browser handle UTF-8 encoding.
void downloadTextFile(String filename, String content, String mime) {
  final blob = web.Blob([content.toJS].toJS, web.BlobPropertyBag(type: mime));
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename;
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}

/// Save in-memory binary data through the same browser download path.
Future<void> downloadBytesFile(
  String filename,
  Uint8List bytes,
  String mime,
) async {
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mime));
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename;
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}

/// Fetch [url] and save the bytes as [filename]. Going through a Blob (rather
/// than pointing an `<a download>` straight at the URL) makes the download work
/// even when the file is served inline or from a different origin.
Future<void> downloadUrl(String url, String filename) async {
  final response = await web.window.fetch(url.toJS).toDart;
  final blob = await response.blob().toDart;
  final objectUrl = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = objectUrl
    ..download = filename;
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(objectUrl);
}
