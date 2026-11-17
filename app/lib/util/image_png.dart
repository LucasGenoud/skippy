import 'dart:typed_data';
import 'dart:ui' as ui;

/// The PNG signature, so a picture already in that format is passed through.
const List<int> _pngSignature = [0x89, 0x50, 0x4E, 0x47];

/// Re-encodes [bytes] (any format the engine decodes) as PNG, the one image
/// type every clipboard accepts. Null when the bytes are not a picture.
Future<Uint8List?> encodePng(Uint8List bytes) async {
  if (_isPng(bytes)) {
    return bytes;
  }

  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}

bool _isPng(Uint8List bytes) {
  if (bytes.length < _pngSignature.length) {
    return false;
  }
  for (var i = 0; i < _pngSignature.length; i++) {
    if (bytes[i] != _pngSignature[i]) {
      return false;
    }
  }
  return true;
}
