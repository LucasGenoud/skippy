import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'image_png.dart';

const _pngMime = 'image/png';

/// Every engine the app supports on the web (Chromium, Safari, Firefox 127+)
/// has `ClipboardItem`; an older browser simply is not offered the control.
bool get canCopyImages => globalContext.has('ClipboardItem');

/// Puts the picture at [url] on the clipboard as a PNG. Answers whether it got
/// there.
///
/// Safari only allows a clipboard write during the tap that asked for it, so
/// the write starts at once and is handed a promise of the bytes rather than
/// waiting for the fetch first.
Future<bool> copyImageUrl(String url) async {
  if (!canCopyImages) {
    return false;
  }

  final blob = _fetchPng(url).then<JSAny>((bytes) {
    if (bytes == null) {
      throw StateError('not an image');
    }
    return web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: _pngMime));
  });
  final items = JSObject()..setProperty(_pngMime.toJS, blob.toJS);

  try {
    await web.window.navigator.clipboard
        .write([web.ClipboardItem(items)].toJS)
        .toDart;
    return true;
  } catch (_) {
    return false;
  }
}

Future<Uint8List?> _fetchPng(String url) async {
  final response = await web.window.fetch(url.toJS).toDart;
  if (!response.ok) {
    return null;
  }
  final buffer = await response.arrayBuffer().toDart;
  return encodePng(buffer.toDart.asUint8List());
}
