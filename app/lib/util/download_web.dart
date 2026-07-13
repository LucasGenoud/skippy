import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Save [content] as [filename] via a throwaway object-URL anchor. Passing the
/// string straight to the Blob lets the browser handle UTF-8 encoding.
void downloadTextFile(String filename, String content, String mime) {
  final blob = web.Blob(
    [content.toJS].toJS,
    web.BlobPropertyBag(type: mime),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename;
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
